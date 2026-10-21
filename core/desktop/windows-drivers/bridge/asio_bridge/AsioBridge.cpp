// AsioBridge.cpp — ASIO 常驻桥实现（04_asio_client Phase 2）。
//
// 结构镜像 bridge/vm_bridge/VmBridge.cpp（同款九件套 + 同款 RT/控制线程分离），
// 差异：传输面由 VB 回调换成 ASIO bufferSwitch（AsioHost 封装 SDK），
// 引擎加载/测试注入复用 02 的 VmPumpCore.h（TryLoadEngine / FillTestSignal），
// 保证"与 05 同源"不出现第二套搜索逻辑或第二套测试信号数学。
//
// 线程模型：
// - ASIO RT 线程：驱动 bufferSwitch → AsioHost::process_io → BridgeSink
//   （零锁零分配零 syscall；仅原子量 + scratch + engine process）。
// - Dart 线程：start/stop/set_param/test/viz/status/detect（直接调，无一进 RT）。
// - 停止时序（防 RT 踩已释放引擎，同 05 FreeTestFile 模式）：
//   ASIOStop → 清 testKind + Sleep(50) 等在途回调 → dispose/exit → 毁引擎。
#include "AsioBridge.h"

#include "PluginBridge.h"
#include "../../04_asio_client/AsioHost.h"
#include "../../02_voicemeeter_client/VmPumpCore.h"  // TryLoadEngine / FillTestSignal / FnEng*

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

void PathForJson(const std::wstring& in, char* out, size_t cap) {
    // JSON 字符串里反斜杠是转义符：路径统一转正斜杠（仅上报用）。
    size_t j = 0;
    for (size_t i = 0; i < in.size() && j + 1 < cap; ++i) {
        const wchar_t c = in[i];
        out[j++] = (c == L'\\') ? '/' : (char)c;  // 路径均为 ASCII；非 ASCII 字符丢失可接受（仅上报）
    }
    out[j] = '\0';
}

void PathForJsonA(const std::string& in, char* out, size_t cap) {
    size_t j = 0;
    for (size_t i = 0; i < in.size() && j + 1 < cap; ++i) {
        const char c = in[i];
        out[j++] = (c == '\\') ? '/' : c;
    }
    out[j] = '\0';
}

using vmcore::FnEngCreate;
using vmcore::FnEngDestroy;
using vmcore::FnEngGetParam;
using vmcore::FnEngProcess;
using vmcore::FnEngSetParam;
using vmcore::FnEngVizRead;
using vmcore::PumpCtx;

struct BridgeCtl {
    auraasio::AsioHost host;
    // 引擎（动态加载；单 handle——ASIO v1 只取一个立体声对进链）
    HMODULE engMod = nullptr;
    FnEngCreate create = nullptr;
    FnEngProcess process = nullptr;
    FnEngDestroy destroy = nullptr;
    FnEngSetParam setParam = nullptr;
    FnEngGetParam getParam = nullptr;
    FnEngVizRead vizRead = nullptr;
    void* engine = nullptr;
    std::wstring enginePath;      // 加载到的引擎 DLL（宽字节原样）
    // 驱动信息（status 用）
    std::string driverUtf8;       // 用户传入的 UTF-8 显示名
    std::string driverRaw;        // 注册表原始名（SDK load 键；status 调试用）
    long outPair = 0;
    int ioCh = 2;                 // io 声道数（2/4/6/8；start 定稿，RT 只读）
    long inCh = 0, outCh = 0, inLat = 0, outLat = 0;
    double sr = 0.0;
    long nbs = 0;
    // 运行态
    volatile LONG running = 0;
    volatile LONG userBypass = 0;
    int startRc = -99;
    char note[128] = {};
    int paramsApplied = 0;
    int paramsFailed = 0;
    // Phase 4 掉线统计（仅控制线程读写——status/ResetSession 串行，无需原子）
    uint64_t lastStatusQpc = 0;        // 上次 status 的 QPC
    uint64_t lastStatusSwitches = 0;   // 上次 status 的 switch_count
    unsigned long dropouts = 0;        // 欠载次数（本次会话累计）
    // 测试注入状态（FillTestSignal 载体；复用 05 的 PumpCtx 字段子集）
    PumpCtx tc;
};

BridgeCtl g_b;

// 插件槽转发：单引擎（g_b.engine），Dart 在 start 成功后按会话镜像重放。
auraplugin::Fns g_pluginFns;
auraplugin::Mirror g_pluginMirror;

// ---- RT sink（驱动 bufferSwitch 线程调用；零锁零分配零 syscall）----
void BridgeSink(void* ctx, float* in, float* out, int frames) {
    auto* c = static_cast<BridgeCtl*>(ctx);
    if (frames <= 0) return;
    const int ch = (c->ioCh >= 2) ? c->ioCh : 2;
    const size_t bytes = sizeof(float) * (size_t)ch * (size_t)frames;
    if (c->tc.testKind != 0) {
        // 测试注入：测试信号替换真实输入，进同一条 DSP 链（与 05 同语义；
        // B2c：桥按 io 声道数交织填充，文件多声道直通/立体声铺前对）。
        vmcore::FillTestSignalN(&c->tc, in, frames, ch);
    }
    if (c->userBypass) {
        // 用户旁路：跳过 process，输入直通（测试信号同样直通）。
        memcpy(out, in, bytes);
        return;
    }
    if (c->process && c->engine) {
        c->process(c->engine, in, out, frames);
    } else {
        memcpy(out, in, bytes);  // 无引擎：透传，绝不吞声
    }
}

// "id=f1.5;gain=i3" 解析并下发引擎 handle（Dart 线程，无 RT 约束）。
void ApplyParamsString(const char* s) {
    if (!s || !*s || !g_b.setParam || !g_b.engine) {
        if (s && *s && (!g_b.setParam || !g_b.engine)) ++g_b.paramsFailed;
        return;
    }
    char buf[4096] = {0};
    strncpy_s(buf, s, sizeof(buf) - 1);
    // strtok 单线程调用（Dart 线程串行，无重入问题；同 05）。
    for (char* tok = strtok(buf, ";"); tok != nullptr; tok = strtok(nullptr, ";")) {
        char* eq = strchr(tok, '=');
        if (!eq || eq == tok) {
            ++g_b.paramsFailed;
            continue;
        }
        *eq = '\0';
        const char* id = tok;
        const char* vs = eq + 1;
        if (strchr(vs, '.') || strchr(vs, 'e') || strchr(vs, 'E')) {
            const float f = (float)atof(vs);
            if (g_b.setParam(g_b.engine, id, &f, 4) != 0) ++g_b.paramsFailed;
            else ++g_b.paramsApplied;
        } else {
            const int32_t iv = (int32_t)atoi(vs);
            if (g_b.setParam(g_b.engine, id, &iv, 4) != 0) ++g_b.paramsFailed;
            else ++g_b.paramsApplied;
        }
    }
}

void DestroyEngine() {
    if (g_b.engine && g_b.destroy) g_b.destroy(g_b.engine);
    g_b.engine = nullptr;
    if (g_b.engMod) FreeLibrary(g_b.engMod);
    g_b.engMod = nullptr;
    g_b.create = nullptr;
    g_b.process = nullptr;
    g_b.setParam = nullptr;
    g_b.getParam = nullptr;
    g_b.vizRead = nullptr;
    g_b.destroy = nullptr;
    g_b.enginePath.clear();
}

void FreeTestFile() {
    // 先清 kind 让 RT 停用，再等在途回调退出（~10ms 量级），最后释放（同 05）。
    InterlockedExchange(&g_b.tc.testKind, 0);
    Sleep(50);
    if (g_b.tc.testFile) {
        free((void*)g_b.tc.testFile);
        g_b.tc.testFile = nullptr;
    }
    g_b.tc.testFrames = 0;
    g_b.tc.testPos = 0;
}

void ResetSession() {
    // start 入口/停止出口的会话态复位（不动 host——由 open/close 自理）。
    memset(&g_b.tc, 0, sizeof(g_b.tc));
    g_b.userBypass = 0;
    g_b.startRc = -99;
    g_b.note[0] = '\0';
    g_b.paramsApplied = 0;
    g_b.paramsFailed = 0;
    g_b.lastStatusQpc = 0;
    g_b.lastStatusSwitches = 0;
    g_b.dropouts = 0;
    g_b.driverUtf8.clear();
    g_b.driverRaw.clear();
    g_b.outPair = 0;
    g_b.ioCh = 2;
    g_b.inCh = g_b.outCh = g_b.inLat = g_b.outLat = 0;
    g_b.sr = 0.0;
    g_b.nbs = 0;
    g_pluginMirror.Reset();  // 新会话：等 App 侧 start 后按当前会话重放
}

}  // namespace

int asio_detect(char* out, int cap) {
    if (!out || cap <= 0) return -1;
    const auto drivers = auraasio::enumerate_drivers();
    int n = 0;
    // {"count":N,"drivers":[{...},...]}
    n = _snprintf_s(out, (size_t)cap, _TRUNCATE, "{\"count\":%d,\"drivers\":[",
                    (int)drivers.size());
    if (n < 0) return -1;
    for (size_t i = 0; i < drivers.size(); ++i) {
        const auto& d = drivers[i];
        char dll[512] = {0};
        PathForJsonA(d.dllPath, dll, sizeof(dll));
        char clsid[64] = {0};
        strncpy_s(clsid, d.clsid.c_str(), sizeof(clsid) - 1);
        const char* name = d.nameUtf8.empty() ? d.name.c_str() : d.nameUtf8.c_str();
        // nameUtf8 为空时回退原始名（极端情况：ansi_to_utf8 失败）。
        const int w = _snprintf_s(
            out + n, (size_t)(cap - n), _TRUNCATE,
            "%s{\"name\":\"%s\",\"dll\":\"%s\",\"clsid\":\"%s\"}",
            (i ? "," : ""), name, dll, clsid);
        if (w < 0 || w >= cap - n) return -1;
        n += w;
    }
    const int w = _snprintf_s(out + n, (size_t)(cap - n), _TRUNCATE, "]}");
    if (w < 0 || w >= cap - n) return -1;
    n += w;
    return n;
}

int asio_start_ex(const char* driver_name, const char* engine_dll,
                  const char* params_json, long buf_size, long out_pair,
                  long channels) {
    if (InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;  // 幂等成功
    ResetSession();

    // 1) 驱动名映射：用户传 UTF-8 显示名（detect 的 name），内部按 SDK 语义
    //    用注册表原始名 load（Description 匹配；中文名必须走这张表）。
    const auto drivers = auraasio::enumerate_drivers();
    const auraasio::DriverEntry* chosen = nullptr;
    for (const auto& d : drivers) {
        if (driver_name && *driver_name &&
            (d.nameUtf8 == driver_name || d.name == driver_name)) {
            chosen = &d;
            break;
        }
    }
    if (!chosen && !drivers.empty() && (!driver_name || !*driver_name)) {
        chosen = &drivers.front();  // 未指定：取枚举第一个（调用方应先 detect）
    }
    if (!chosen) {
        snprintf(g_b.note, sizeof(g_b.note), "driver-not-found");
        return -1;
    }
    g_b.driverUtf8 = chosen->nameUtf8.empty() ? chosen->name : chosen->nameUtf8;
    g_b.driverRaw = chosen->name;

    // 2) 引擎 DLL 加载 + 符号解析（必须在 host.open 之前！
    //    2026-10-15 实测定罪：VM/FLStudio 驱动在 ASIOInit~ASIOCreateBuffers
    //    窗口内先后启动自有线程；此窗口内的任何 LoadLibrary 都会与其争抢
    //    loader lock——实测复现：轻则 bufferSwitch 永久静默（回调 stall），
    //    重则驱动看门狗以 ExitProcess(0) 干净杀掉宿主（WER 无转储、无段错误，
    //    曾长期被误判为"玄学崩"）。加载与 PE 重定位只发生在驱动线程存在之前
    //    即无争用（预栽赃实验：引擎先于桥加载则全程正常）。
    //    句柄创建（auradsp_create）无 LoadLibrary，可安全放在 open 之后。）
    std::wstring used;
    const std::string hint = (engine_dll && *engine_dll) ? engine_dll : "";
    g_b.engMod = vmcore::TryLoadEngine(hint, used);
    if (!used.empty()) g_b.enginePath = used;
    if (g_b.engMod) {
        g_b.create = (FnEngCreate)GetProcAddress(g_b.engMod, "auradsp_create");
        g_b.process = (FnEngProcess)GetProcAddress(g_b.engMod, "auradsp_process");
        g_b.destroy = (FnEngDestroy)GetProcAddress(g_b.engMod, "auradsp_destroy");
        g_b.setParam = (FnEngSetParam)GetProcAddress(g_b.engMod, "auradsp_set_param");
        g_b.getParam = (FnEngGetParam)GetProcAddress(g_b.engMod, "auradsp_get_param");
        g_b.vizRead = (FnEngVizRead)GetProcAddress(g_b.engMod, "auradsp_viz_read");
        g_pluginFns.Resolve(g_b.engMod);
    }
    if (!g_b.engMod || !g_b.create || !g_b.process || !g_b.destroy) {
        snprintf(g_b.note, sizeof(g_b.note), "engine-load-failed");
        DestroyEngine();
        g_b.startRc = -5;
        return -5;
    }

    // 3) 打开驱动（loadAsioDriver + ASIOInit）
    //    sysRef 传 GetConsoleWindow()：与 asio_tone 一致。FL Studio ASIO
    //    （ilwasapi2asio，WASAPI 包装驱动）实测对 sysRef=nullptr 敏感——
    //    会给宿主进程派发终止（2026-10-15 矩阵实验定罪；VM 驱动两种都正常）。
    //    GUI 宿主（APP isolate）无控制台窗口时退化为 nullptr，由 P3 传入
    //    主窗口句柄（AsioHost::open 已支持任意 sysRef）。
    std::string why;
    if (!g_b.host.open(chosen->name.c_str(), (void*)GetConsoleWindow(), why)) {
        snprintf(g_b.note, sizeof(g_b.note), "open-failed: %.80s", why.c_str());
        DestroyEngine();
        g_b.startRc = -2;
        return -2;
    }

    // 4) 能力查询（status 面 + 引擎创建参数）
    auraasio::DriverCaps caps;
    if (!g_b.host.query_caps(caps)) {
        snprintf(g_b.note, sizeof(g_b.note), "caps-failed");
        DestroyEngine();
        g_b.host.close();
        g_b.startRc = -3;
        return -3;
    }
    g_b.inCh = caps.inChannels;
    g_b.outCh = caps.outChannels;
    g_b.inLat = caps.inLatency;
    g_b.outLat = caps.outLatency;
    g_b.sr = caps.sampleRate;
    // io 声道数（B2c）：请求值非 {2,4,6,8} 归 2；再按驱动能力向下取档
    //（inCh/outCh/out_pair 余量）。取不到请求档即自动降级（保音频不断）。
    long nCh = (channels == 4 || channels == 6 || channels == 8) ? channels : 2;
    {
        const long ob = out_pair < 0 ? 0 : out_pair;
        long avail = 2;
        const long cand[4] = { 8, 6, 4, 2 };
        for (int i = 0; i < 4; ++i) {
            if (cand[i] <= nCh && cand[i] <= caps.inChannels &&
                ob + cand[i] <= caps.outChannels) {
                avail = cand[i];
                break;
            }
        }
        if (avail != nCh) {
            snprintf(g_b.note, sizeof(g_b.note), "ioCh %ld->%ld (driver caps)", nCh, avail);
        }
        nCh = avail;
    }
    g_b.ioCh = (int)nCh;
    // 预计缓冲大小（与 create_stereo_io 同规则；创建后若驱动回值不同则重建引擎）
    g_b.nbs = (buf_size > 0) ? buf_size : caps.prefBuf;

    // 5) 创建引擎句柄（纯分配，无 LoadLibrary，可安全位于 open 之后）
    g_b.engine = g_b.create((float)g_b.sr, (int)g_b.nbs);
    if (!g_b.engine) {
        snprintf(g_b.note, sizeof(g_b.note), "engine-create-failed");
        DestroyEngine();
        g_b.host.close();
        g_b.startRc = -6;
        return -6;
    }

    // 6) 创建 nCh 声道输入（ch0..nCh-1）+ 输出（out_pair..out_pair+nCh-1）缓冲
    if (!g_b.host.create_io(nCh, buf_size, out_pair, why)) {
        snprintf(g_b.note, sizeof(g_b.note), "buffers-failed: %.80s", why.c_str());
        DestroyEngine();
        g_b.host.close();
        g_b.startRc = -4;
        return -4;
    }
    g_b.outPair = out_pair < 0 ? 0 : out_pair;
    // 驱动回值缓冲大小与预估不符（granularity 取整等）：按实际值重建引擎句柄
    if (g_b.engine && g_b.host.buffer_size() != g_b.nbs) {
        if (g_b.destroy) g_b.destroy(g_b.engine);
        g_b.nbs = g_b.host.buffer_size();
        g_b.engine = g_b.create((float)g_b.sr, (int)g_b.nbs);
        if (!g_b.engine) {
            snprintf(g_b.note, sizeof(g_b.note), "engine-recreate-failed");
            DestroyEngine();
            g_b.host.close();
            g_b.startRc = -6;
            return -6;
        }
    }

    // 7) 挂 sink（必须在 start 前；RT 启动后不再更改指针）
    g_b.host.set_process_sink(&BridgeSink, &g_b);

    // 8) 预下发参数 + 启动
    ApplyParamsString(params_json);
    // 传输声道数与引擎处理声道数必须等宽（process 读写按 channels.count 定 stride，
    // 不等宽会错位）。桥以 io 声道数为权威，最后覆盖 mirror 可能带来的旧值。
    if (g_b.setParam && g_b.engine) {
        const int32_t cc = (int32_t)nCh;
        if (g_b.setParam(g_b.engine, "channels.count", &cc, 4) != 0) {
            snprintf(g_b.note, sizeof(g_b.note), "channels.count set failed (%ld)", nCh);
        }
    }
    if (!g_b.host.start()) {
        snprintf(g_b.note, sizeof(g_b.note), "asio-start-failed");
        DestroyEngine();
        g_b.host.close();
        g_b.startRc = -7;
        return -7;
    }
    g_b.startRc = 0;
    InterlockedExchange(&g_b.running, 1);
    return 0;
}

int asio_start(const char* driver_name, const char* engine_dll,
               const char* params_json, long buf_size, long out_pair) {
    // 兼容入口：默认立体声（既有调用方零改动；多声道走 asio_start_ex）。
    return asio_start_ex(driver_name, engine_dll, params_json, buf_size, out_pair, 2);
}

int asio_stop() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;  // 幂等
    InterlockedExchange(&g_b.running, 0);
    // 停止时序（防 RT 踩已释放引擎，同 05）：stop → 等在途回调 → dispose/exit
    g_b.host.stop();
    FreeTestFile();
    g_b.host.close();
    // 显式释放驱动 COM 对象（SDK 单例 asioDrivers 仍在，下次 start 的
    // loadDriver 会自行 removeCurrentDriver；此处主动释放避免跨会话占着驱动）。
    auraasio::release_active_driver();
    DestroyEngine();
    return 0;
}

int asio_status(char* out, int cap) {
    if (!out || cap <= 0) return -1;
    LARGE_INTEGER qpf, qnow;
    double cbUs = 0;
    if (QueryPerformanceFrequency(&qpf) && qpf.QuadPart > 0)
        cbUs = (double)g_b.host.max_cb_ticks() * 1000000.0 / (double)qpf.QuadPart;
    QueryPerformanceCounter(&qnow);
    const uint64_t nowQ = (uint64_t)qnow.QuadPart;
    const uint64_t sw = g_b.host.switch_count();
    // Phase 4 掉线检测（控制面）：两次 status 间的 switches 增量低于期望的
    // 80%（且期望增量足够大，排除短窗口抖动）记一次欠载。RT 侧只写 QPC，
    // 判定全部在这里——误差容忍最后一次 status 之后的半帧。
    if (InterlockedCompareExchange(&g_b.running, 0, 0) &&
        g_b.lastStatusQpc != 0 && qpf.QuadPart > 0 &&
        g_b.sr > 0.0 && g_b.nbs > 0 && sw >= g_b.lastStatusSwitches) {
        const double elapsedSec =
            (double)(nowQ - g_b.lastStatusQpc) / (double)qpf.QuadPart;
        const double expect = elapsedSec * g_b.sr / (double)g_b.nbs;
        const double actual = (double)(sw - g_b.lastStatusSwitches);
        if (expect > 4.0 && actual < expect * 0.8) ++g_b.dropouts;
    }
    g_b.lastStatusQpc = nowQ;
    g_b.lastStatusSwitches = sw;
    char eng[512] = {0};
    PathForJson(g_b.enginePath, eng, sizeof(eng));
    const int n = snprintf(
        out, (size_t)cap,
        "{\"running\":%s,\"switches\":%llu,\"sr\":%.1f,\"nbs\":%ld,"
        "\"driver\":\"%s\",\"outPair\":%ld,\"ioCh\":%d,"
        "\"inCh\":%ld,\"outCh\":%ld,\"inLatency\":%ld,\"outLatency\":%ld,"
        "\"peakIn\":%.6f,\"peakOut\":%.6f,\"maxCbUs\":%.1f,"
        "\"startRc\":%d,\"note\":\"%s\",\"bypass\":%ld,\"testKind\":%ld,"
        "\"paramsApplied\":%d,\"paramsFailed\":%d,"
        "\"resetPending\":%d,\"latenciesChanged\":%d,\"dropouts\":%lu,"
        "\"engine\":\"%s\",\"engineOk\":%s}",
        InterlockedCompareExchange(&g_b.running, 0, 0) ? "true" : "false",
        (unsigned long long)sw, g_b.sr, g_b.nbs,
        g_b.driverUtf8.c_str(), g_b.outPair, g_b.ioCh,
        g_b.inCh, g_b.outCh, g_b.inLat, g_b.outLat,
        (double)g_b.host.peak_in(), (double)g_b.host.peak_out(), cbUs,
        g_b.startRc, g_b.note,
        (long)InterlockedCompareExchange(&g_b.userBypass, 0, 0),
        (long)InterlockedCompareExchange(&g_b.tc.testKind, 0, 0),
        g_b.paramsApplied, g_b.paramsFailed,
        g_b.host.reset_pending() ? 1 : 0,
        g_b.host.latencies_changed() ? 1 : 0,
        g_b.dropouts, eng,
        (g_b.engine && g_b.process) ? "true" : "false");
    return (n >= 0 && n < cap) ? n : -1;
}

int asio_set_param(const char* id, int isFloat, const void* v4) {
    (void)isFloat;  // 引擎按 id 自身语义取 4 字节；isFloat 仅调用方提示用
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !v4 || !g_b.setParam || !g_b.engine) return -2;
    return (g_b.setParam(g_b.engine, id, v4, 4) == 0) ? 0 : -3;
}

int asio_set_param_str(const char* id, const char* utf8, int bytes) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !utf8 || bytes <= 0 || bytes > 256 * 1024) return -2;
    if (!g_b.setParam || !g_b.engine) return -3;
    // 引擎内部拷贝编译，返回后调用方缓冲可释放；失败时引擎保留旧程序。
    return (g_b.setParam(g_b.engine, id, utf8, (unsigned)bytes) == 0) ? 0
                                                                     : -4;
}

int asio_get_param(const char* id, int isFloat, void* out4) {
    (void)isFloat;
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !out4 || !g_b.getParam || !g_b.engine) return -2;
    return (g_b.getParam(g_b.engine, id, out4, 4) == 0) ? 0 : -3;
}

int asio_get_param_str(const char* id, char* out, int cap) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !out || cap <= 1 || !g_b.getParam || !g_b.engine) return -2;
    out[0] = 0;
    if (g_b.getParam(g_b.engine, id, out, (unsigned)cap) != 0) return -3;
    out[cap - 1] = 0;  // 引擎保证 NUL 结尾，这里再兜一层
    return (int)strlen(out);
}

int asio_viz_read(void* out408, int count) {
    if (!out408 || count <= 0) return -1;
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.vizRead || !g_b.engine) return 0;
    return (int)g_b.vizRead(g_b.engine, out408, (uint32_t)count);
}

int asio_bypass(int on) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    InterlockedExchange(&g_b.userBypass, on ? 1 : 0);
    return 0;
}

int asio_test_start(int kind, const float* pcm, int frames, int ch, int rate) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (kind < 1 || kind > 3) return -2;
    FreeTestFile();
    if (kind == 3) {
        // 文件 PCM 拷贝（交织 float32）。B2c：支持 1..8 声道源；单声道铺双声道，
        // 多声道按 ch 原样存储（FillTestSignalN 按 io 声道数取用/补零；同 05 语义）。
        if (!pcm || frames <= 0 || rate <= 0) return -3;
        if (ch < 1 || ch > 8) return -3;
        const int storeCh = (ch <= 1) ? 2 : ch;
        float* buf = (float*)malloc(sizeof(float) * (size_t)frames * (size_t)storeCh);
        if (!buf) return -4;
        if (ch <= 1) {
            for (int i = 0; i < frames; ++i) buf[i * 2] = buf[i * 2 + 1] = pcm[i];
        } else {
            memcpy(buf, pcm, sizeof(float) * (size_t)frames * (size_t)storeCh);
        }
        g_b.tc.testFile = buf;
        g_b.tc.testFrames = (uint64_t)frames;
        g_b.tc.testRate = rate;
        g_b.tc.testFileCh = storeCh;
        g_b.tc.testPos = 0;
    }
    g_b.tc.testPhase = 0;
    g_b.tc.testRng = 0x12345678u;
    for (int i = 0; i < 7; ++i) g_b.tc.testPink[i] = 0;
    g_b.tc.sr = (long)g_b.sr;  // FillTestSignal 的音高/重采样基准取驱动采样率
    InterlockedExchange(&g_b.tc.testKind, (LONG)kind);
    return 0;
}

int asio_test_stop() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    FreeTestFile();
    return 0;
}

// ---- 插件槽（单引擎）----
int asio_plugin_slot_load(int slot, const char* path, const char* plugin_id) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    return auraplugin::SlotLoad(g_b.engine, g_pluginFns, g_pluginMirror,
                                slot, path, plugin_id);
}

int asio_plugin_slot_unload(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    return auraplugin::SlotUnload(g_b.engine, g_pluginFns, g_pluginMirror,
                                  slot);
}

int asio_plugin_slot_set_bypass(int slot, int bypass) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    return auraplugin::SlotSetBypass(g_b.engine, g_pluginFns,
                                     g_pluginMirror, slot, bypass);
}

int asio_plugin_slot_get_bypass(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.engine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.getBypass(g_b.engine, slot);
}

unsigned asio_plugin_slot_get_latency(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.engine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.getLatency(g_b.engine, slot);
}

int asio_plugin_slot_get_status(int slot, char* out, int cap) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) {
        if (out && cap > 0) out[0] = 0;
        return 0;
    }
    return auraplugin::SlotGetStatus(g_b.engine, g_pluginFns, slot, out, cap);
}

int asio_plugin_slot_show_editor(int slot, const char* title) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.engine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.showEditor(g_b.engine, slot, title);
}

int asio_plugin_slot_close_editor(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.engine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.closeEditor(g_b.engine, slot);
}

int asio_plugin_slot_is_editor_open(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.engine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.isEditorOpen(g_b.engine, slot);
}

int asio_plugin_slot_save_preset(int slot, const char* path) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.engine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.savePreset(g_b.engine, slot, path);
}

int asio_plugin_slot_load_preset(int slot, const char* path) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.engine || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.loadPreset(g_b.engine, slot, path);
}

int asio_plugin_slot_set_insert_stage(int slot, int stage) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    return auraplugin::SlotSetStage(g_b.engine, g_pluginFns,
                                    g_pluginMirror, slot, stage);
}

int asio_plugin_slot_get_insert_stage(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 3;
    if (!g_b.engine || !g_pluginFns.Ready()) return 3;
    return g_pluginFns.getStage(g_b.engine, slot);
}

int asio_plugin_slot_set_channels(int slot, int channels) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    return auraplugin::SlotSetChannels(g_b.engine, g_pluginFns,
                                       g_pluginMirror, slot, channels);
}

int asio_plugin_slot_get_channels(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0xFF;
    return auraplugin::SlotGetChannels(g_b.engine, g_pluginFns, slot);
}
