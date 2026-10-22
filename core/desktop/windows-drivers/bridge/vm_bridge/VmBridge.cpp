// VmBridge.cpp — VB-Callback 持久桥实现。
//
// 线程模型（三线程，职责分离，沿用泵的无锁审计）：
// - VB RT 线程：OnVbCallback（零锁零分配；读 testKind/engines，只写自有计数）。
// - monitor 线程：CHANGE 重建（stop→rebuild→start）+ 退出事件等待。
// - Dart 线程：start/stop/set_param/test/viz/status（直接调，无一进 RT）。
// Login/Logout 与泵同式严格单次配对；OUT 槽被占（rc=1）直接返回 1 让 UI 提示。
#include "VmBridge.h"

#include "PluginBridge.h"
#include "../../02_voicemeeter_client/VmPumpCore.h"
#include "../../02_voicemeeter_client/VmRemoteLoader.h"

#include <cstdio>
#include <cstring>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

void PathForJson(const std::string& in, char* out, size_t cap) {
    // JSON 字符串里反斜杠是转义符：路径统一转正斜杠（仅上报用）。
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
using vmcore::FnReg;
using vmcore::FnStart;
using vmcore::FnStop;
using vmcore::FnUnreg;
using vmcore::kModeOut;
using vmcore::PumpCtx;

struct BridgeCtl {
    HMODULE remote = nullptr;
    FnStart start = nullptr;
    FnStop stop = nullptr;
    FnUnreg unreg = nullptr;
    long(__stdcall* logout)() = nullptr;
    bool remoteFreed = false;
    HMODULE eng = nullptr;
    FnEngCreate create = nullptr;
    FnEngGetParam getParam = nullptr;
    FnEngVizRead vizRead = nullptr;
    PumpCtx ctx;
    HANDLE monitor = nullptr;
    volatile LONG running = 0;
    volatile LONG stopEvent = 0;  // 置位即 monitor 退出
    int startRc = -99;
    int edition = 0;
    int groupCount = PumpCtx::kMaxGroups;  // 版型应建引擎数（重建沿用，不看会漂的 ctx.groups）
    int busMask = 0xFF;  // 总线处理掩码（bit=组使能；memset 会清 ctx，session 级保管在此）
    char note[128] = {};
    char enginePath[MAX_PATH * 2] = {};
    int paramsApplied = 0;
    int paramsFailed = 0;
};

BridgeCtl g_b;

// 插件槽转发（BUGFIX 2026-10-22：由「仅 A1 = eng[0]」改为**全部组引擎**）。
// 根因：VM 多总线版面（Banana/Potato）每组 8 声道独立 handle，用户监听的
// 输出总线往往不是 A1——插件只挂 eng[0] 时，A1 仍会收到 Voicemeeter 复制的
// 音乐流（插件 GUI 有输入、遥测 Δmax>0），但用户监听总线走的是组 1+ 引擎
// （只有厂商 DSP、无插件）→ 效果永远听不到。厂商 DSP 本就逐组各跑一份，
// 插件逐组同步与其语义一致。读操作/编辑器仍走 eng[0]（单实例，GUI 参数
// 改动不跨总线同步——引擎内实例本就独立，见下方各函数注释）。
auraplugin::Fns g_pluginFns;
auraplugin::Mirror g_pluginMirror;

void* PluginEngine() {
    return g_b.ctx.nEng > 0 ? g_b.ctx.eng[0] : nullptr;
}

static int PluginEngineCount() {
    return g_b.ctx.nEng;
}

static void* PluginEngineAt(int g) {
    return (g >= 0 && g < g_b.ctx.nEng) ? g_b.ctx.eng[g] : nullptr;
}

// 按路插件处理掩码（bit g = 组 g 吃插件链）。session 级保管于桥静态区
// （ctx 会被 memset，CHANGE 重建不丢，重建后经 ApplyPluginGroupMask 重放）。
static volatile LONG g_pluginGroupMask = 0xFF;

// 把掩码下发到全部组引擎（引擎链级开关，原子布尔，RT 安全）。
// 引擎 DLL 无链开关符号（旧版本）时静默跳过——掩码仍被记录，
// 升级引擎后自然生效。不在 RT 线程调用（控制线程语义）。
static void ApplyPluginGroupMask() {
    if (!g_pluginFns.HasChainEnable()) return;
    const int mask = InterlockedCompareExchange(&g_pluginGroupMask, 0, 0);
    for (int g = 0; g < g_b.ctx.nEng; ++g) {
        if (g_b.ctx.eng[g]) {
            g_pluginFns.chainSetEnabled(g_b.ctx.eng[g], (mask >> g) & 1);
        }
    }
}

// ---- 后台组补齐（2026-10-23：挂载提速）-----------------------------------
// 历史：vb_plugin_slot_load 把插件**逐组同步实例化**。实测（Ozone 12，模块
// 已映射后）每实例 ~2.4s：4 组 = 9.7s、8 组近 20s——而 FL Studio 单实例
// 2-3s（用户实测 10s vs FL 2-3s 的根因即此）。
// 现在：eng[0] 同步加载（读操作/编辑器/用户主监听总线立即可用，~2-3.7s），
// 其余组由本工作线程按「代际」后台补齐；补齐后回放镜像状态（bypass/Ch/
// 阶段）与已请求的预设——否则后台组会以出厂态开声（旁路丢失 + 预设丢失）。
// 语义折衷：监听非 eng[0] 总线的用户在挂载后数秒内听到的是直通；这把
// 「10s 无法操作」换成「主总线立即可用、其余总线渐次生效」。
// 掩码位为 0 的组**不加载**（该组链已关闭，实例纯属浪费内存/CPU）。
static std::atomic<uint32_t> g_bgGen{0};   // load/unload/销毁递增 → 旧任务作废
static std::mutex g_bgMutex;
static std::condition_variable g_bgCv;
static std::thread g_bgThread;
static bool g_bgStop = false;

struct PendingGroupLoad {
    uint32_t gen = 0;
    int slot = -1;
    std::string path;
    std::string id;
};
static std::deque<PendingGroupLoad> g_bgJobs;

// 引擎级互斥：后台补齐与 unload/同步 load 不得并发碰同一组引擎。
static std::mutex g_engineMut;

// 每组已加载槽位位图（bit slot）：判定该组是否就绪（决定预设即时应用还是
// 挂起）；由同步加载、后台补齐、卸载共同维护。
static std::atomic<uint32_t> g_grpLoaded[PumpCtx::kMaxGroups];

// 挂起预设：[group][slot] = 最近一次请求的路径；该组补齐后应用一次。
static std::mutex g_pendMutex;
static std::string g_pendPreset[PumpCtx::kMaxGroups][auraplugin::kSlots];
static bool g_pendHasPreset[PumpCtx::kMaxGroups][auraplugin::kSlots] = {};

// 该组是否值得挂插件：插件掩码内 **且** 总线掩码内。
// 掩码外的组要么链已关闭、要么整组不处理音频——实例纯属浪费
// （加载时间 + 内存 + 每回调 CPU）。这是 F-4 卡顿的核心杠杆：VM 会把
// 输入复制到全部总线，若不为用不到的总线裁掉实例，重插件会在单个
// 回调里被 N 份并发处理，超出缓冲区预算即爆音/断续。
static bool GroupNeedsPlugin(int g) {
    if (g < 0 || g >= PumpCtx::kMaxGroups) return false;
    const int pm = InterlockedCompareExchange(&g_pluginGroupMask, 0, 0);
    const int bm = InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0);
    return ((pm >> g) & 1) != 0 && ((bm >> g) & 1) != 0;
}

// 后台补一个组：加载 → 镜像状态回放 → 挂起预设应用。
// 返回 true = 该组已就绪。
static bool LoadGroupForSlot(int g, int slot, const char* path, const char* id) {
    void* e = PluginEngineAt(g);
    if (!e || !path || !*path) return false;
    std::lock_guard<std::mutex> eng(g_engineMut);
    if (auraplugin::SlotLoad(e, g_pluginFns, g_pluginMirror, slot, path, id) != 1)
        return false;
    int stage = 3, bypass = 1, channels = 0xFF;
    if (g_pluginMirror.GetSlot(slot, &stage, &bypass, &channels)) {
        g_pluginFns.setChannels(e, slot, channels);
        g_pluginFns.setStage(e, slot, stage);
        g_pluginFns.setBypass(e, slot, bypass);
    }
    std::string preset;
    {
        std::lock_guard<std::mutex> lk(g_pendMutex);
        if (g_pendHasPreset[g][slot]) {
            preset = g_pendPreset[g][slot];
            g_pendHasPreset[g][slot] = false;
        }
    }
    if (!preset.empty()) g_pluginFns.loadPreset(e, slot, preset.c_str());
    g_grpLoaded[g].fetch_or(1u << slot);
    return true;
}

static void GroupLoadWorker() {
    for (;;) {
        PendingGroupLoad job;
        {
            std::unique_lock<std::mutex> lk(g_bgMutex);
            g_bgCv.wait(lk, [] { return g_bgStop || !g_bgJobs.empty(); });
            if (g_bgStop) return;
            job = std::move(g_bgJobs.front());
            g_bgJobs.pop_front();
        }
        const int n = PluginEngineCount();
        HANDLE thr = GetCurrentThread();
        const int oldPrio = GetThreadPriority(thr);
        // 同同步路径：加载是重 IO/内存操作，压低本线程让 RT 回调优先。
        SetThreadPriority(thr, THREAD_PRIORITY_BELOW_NORMAL);
        for (int g = 1; g < n; ++g) {
            if (g_bgGen.load(std::memory_order_acquire) != job.gen) break;
            if (!GroupNeedsPlugin(g)) continue;   // 掩码外组不加载
            LoadGroupForSlot(g, job.slot, job.path.c_str(), job.id.c_str());
        }
        SetThreadPriority(thr, oldPrio);
    }
}

static void EnsureBgThread() {
    std::lock_guard<std::mutex> lk(g_bgMutex);
    if (!g_bgThread.joinable()) {
        g_bgStop = false;
        g_bgThread = std::thread(GroupLoadWorker);
    }
}

// 停止并 join（销毁/重建引擎前必须调用：工作线程会碰引擎句柄）。
// join 上界 = 一个实例的加载时长（~2.4s），仅发生在 stop/CHANGE 重建。
static void StopBgThread() {
    {
        std::lock_guard<std::mutex> lk(g_bgMutex);
        g_bgStop = true;
        g_bgJobs.clear();
    }
    g_bgCv.notify_all();
    if (g_bgThread.joinable()) g_bgThread.join();
}

// 掩码新使能的组：若镜像里已有插件、但该组实例尚缺（加载时被掩码跳过），
// 后台补挂——否则该总线只有厂商 DSP、插件永远不生效。
// added = 新使能位图；调用方保证与旧掩码已切换。
static void BackfillGroupsForMask(int added) {
    if (!added) return;
    std::vector<PendingGroupLoad> jobs;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (!((added >> g) & 1) || !PluginEngineAt(g) || !GroupNeedsPlugin(g))
            continue;
        for (int s = 0; s < auraplugin::kSlots; ++s) {
            if (g_grpLoaded[g].load() & (1u << s)) continue;
            char p[512] = {0};
            char id[128] = {0};
            int stage = 3, bypass = 1, ch = 0xFF;
            if (!g_pluginMirror.GetSlot(s, &stage, &bypass, &ch, p, sizeof(p), id,
                                        sizeof(id)) ||
                p[0] == '\0') {
                continue;
            }
            jobs.push_back(PendingGroupLoad{g_bgGen.load(), s, p, id});
        }
    }
    if (jobs.empty()) return;
    EnsureBgThread();
    {
        std::lock_guard<std::mutex> lk(g_bgMutex);
        for (auto& j : jobs) g_bgJobs.push_back(std::move(j));
    }
    g_bgCv.notify_one();
}

// 参数镜像：CHANGE 重建会换掉全部引擎句柄，新句柄是出厂态。桥必须自己留一份
// 最近一次生效的参数并在重建后逐条回放——否则用户在 App 侧只在 vb_start 时
// 下发一次，VM 一重启引擎（改主输出设备）参数就全丢，听感变成"没处理"，
// 必须切一次模式才恢复。字符串参数（如 liveprog.code）不经此路径，见 README。
constexpr int kMirrorMax = 512;
struct MirrorEnt {
    char id[64];
    bool isFloat;
    float f;
    int32_t i;
};
MirrorEnt g_mirror[kMirrorMax];
int g_mirrorN = 0;

// 记录/覆盖一条参数（控制线程；id 超长直接丢，不做截断歧义）。
void MirrorSet(const char* id, bool isFloat, const void* v4) {
    if (!id || !v4) return;
    for (int i = 0; i < g_mirrorN; ++i) {
        if (strcmp(g_mirror[i].id, id) == 0) {
            if (isFloat)
                g_mirror[i].f = *(const float*)v4;
            else
                g_mirror[i].i = *(const int32_t*)v4;
            return;
        }
    }
    if (g_mirrorN >= kMirrorMax) return;
    MirrorEnt* e = &g_mirror[g_mirrorN];
    strncpy_s(e->id, id, sizeof(e->id) - 1);
    e->isFloat = isFloat;
    if (isFloat)
        e->f = *(const float*)v4;
    else
        e->i = *(const int32_t*)v4;
    ++g_mirrorN;
}

// 重建后回放全部镜像参数（主线程；引擎进程内串行，无 RT 约束）。
// 双耳模式：把 channels.count 同步到全部 live handle。
// vb_set_param("spatial.binaural") 与 CHANGE 重建回放后都会调用。
void ApplyBinauralChannels(FnEngSetParam setParam) {
    if (!setParam) return;
    const int32_t ch =
        InterlockedCompareExchange(&g_b.ctx.binaural, 0, 0) ? 8 : 2;
    for (int g = 0; g < g_b.ctx.nEng; ++g) {
        if (g_b.ctx.eng[g])
            setParam(g_b.ctx.eng[g], "channels.count", &ch, sizeof(ch));
    }
}

void MirrorReplay(FnEngSetParam setParam) {
    if (!setParam || g_mirrorN <= 0) return;
    int ok = 0, bad = 0;
    for (int i = 0; i < g_mirrorN; ++i) {
        const MirrorEnt& e = g_mirror[i];
        const void* v = e.isFloat ? (const void*)&e.f : (const void*)&e.i;
        bool all = g_b.ctx.nEng > 0;
        for (int g = 0; g < g_b.ctx.nEng; ++g) {
            if (setParam(g_b.ctx.eng[g], e.id, v, 4) != 0) {
                all = false;
                break;
            }
        }
        if (all)
            ++ok;
        else
            ++bad;
    }
    g_b.paramsApplied = ok;
    g_b.paramsFailed = bad;
    snprintf(g_b.note, sizeof(g_b.note), "rebuilt@%.0fHz p%d/%d",
             (double)(g_b.ctx.sr > 0 ? g_b.ctx.sr : 0), ok, g_mirrorN);
}

// 字符串参数镜像（liveprog.code / arbmag.string）：与数值镜像同命运，重建回放。
// 文本 malloc 常驻（控制线程分配，无 RT 约束）；reset 在 vb_start。
// 只记"全部句柄编译成功"的版本：失败的文本若记入，重建后新句柄将无程序可用
// （引擎拒收坏代码时旧句柄是保留原程序的，镜像必须跟这个语义对齐）。
constexpr int kStrMirrorMax = 64;
struct StrMirrorEnt {
    char id[64];
    char* text = nullptr;  // NUL 结尾拷贝
    int bytes = 0;         // 不含 NUL 的字节数
};
StrMirrorEnt g_strMirror[kStrMirrorMax];
int g_strMirrorN = 0;

void StrMirrorFree(StrMirrorEnt* e) {
    if (e->text) {
        free(e->text);
        e->text = nullptr;
    }
    e->bytes = 0;
}

void StrMirrorReset() {
    for (int i = 0; i < g_strMirrorN; ++i) StrMirrorFree(&g_strMirror[i]);
    g_strMirrorN = 0;
}

void StrMirrorSet(const char* id, const char* utf8, int bytes) {
    if (!id || !utf8 || bytes <= 0) return;
    for (int i = 0; i < g_strMirrorN; ++i) {
        if (strcmp(g_strMirror[i].id, id) == 0) {
            StrMirrorFree(&g_strMirror[i]);
            g_strMirror[i].text = (char*)malloc((size_t)bytes + 1);
            if (!g_strMirror[i].text) return;
            memcpy(g_strMirror[i].text, utf8, (size_t)bytes);
            g_strMirror[i].text[bytes] = 0;
            g_strMirror[i].bytes = bytes;
            return;
        }
    }
    if (g_strMirrorN >= kStrMirrorMax) return;
    StrMirrorEnt* e = &g_strMirror[g_strMirrorN];
    strncpy_s(e->id, id, sizeof(e->id) - 1);
    e->text = (char*)malloc((size_t)bytes + 1);
    if (!e->text) return;
    memcpy(e->text, utf8, (size_t)bytes);
    e->text[bytes] = 0;
    e->bytes = bytes;
    ++g_strMirrorN;
}

// 重建后回放字符串镜像（主线程；与 MirrorReplay 同一次重建窗口内调用）。
// 返回成功条数；单条失败不影响其他（新句柄该条留空，note 如实记录）。
int StrMirrorReplay(FnEngSetParam setParam) {
    if (!setParam || g_strMirrorN <= 0 || g_b.ctx.nEng <= 0) return 0;
    int ok = 0;
    for (int i = 0; i < g_strMirrorN; ++i) {
        const StrMirrorEnt& e = g_strMirror[i];
        bool all = true;
        for (int g = 0; g < g_b.ctx.nEng; ++g) {
            if (setParam(g_b.ctx.eng[g], e.id, e.text, (unsigned)e.bytes) !=
                0) {
                all = false;
                break;
            }
        }
        if (all) ++ok;
    }
    return ok;
}

void LeaveCtl(bool andUnreg) {
    if (andUnreg && g_b.unreg) g_b.unreg();
    if (g_b.logout) g_b.logout();
    if (!g_b.remoteFreed && g_b.remote) {
        g_b.remoteFreed = true;
        FreeLibrary(g_b.remote);
    }
    g_b.remote = nullptr;
}

void DestroyEngines() {
    // 后台补齐线程会碰引擎句柄：先停并 join（代际递增使在途任务作废）。
    g_bgGen.fetch_add(1);
    StopBgThread();
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g] && g_b.ctx.destroy) g_b.ctx.destroy(g_b.ctx.eng[g]);
        g_b.ctx.eng[g] = nullptr;
        g_grpLoaded[g].store(0);
    }
    g_b.ctx.nEng = 0;
}

void RebuildEngines(int groups, float sr) {
    // 先用旧指针销毁（此刻回调已停），再从模块重解析——重建后不能依赖构建期
    // 缓存的函数指针：任何一处被置空都会让泵退化成"无引擎直通"，表现正是
    // "声音在但没处理"。
    DestroyEngines();
    if (g_b.eng) {
        g_b.create =
            (FnEngCreate)GetProcAddress(g_b.eng, "auradsp_create");
        g_b.getParam =
            (FnEngGetParam)GetProcAddress(g_b.eng, "auradsp_get_param");
        g_b.ctx.process =
            (FnEngProcess)GetProcAddress(g_b.eng, "auradsp_process");
        g_b.ctx.destroy =
            (FnEngDestroy)GetProcAddress(g_b.eng, "auradsp_destroy");
        g_pluginFns.Resolve(g_b.eng);
    }
    if (g_b.create && g_b.ctx.process && g_b.ctx.destroy && g_b.ctx.scratchIn &&
        g_b.ctx.scratchOut) {
        for (int g = 0; g < groups && g < PumpCtx::kMaxGroups; ++g) {
            g_b.ctx.eng[g] = g_b.create(sr, 2048);
            if (g_b.ctx.eng[g]) ++g_b.ctx.nEng;
        }
    }
    if (g_b.ctx.nEng == 0 || !g_b.ctx.scratchIn || !g_b.ctx.scratchOut) {
        DestroyEngines();
        g_b.ctx.process = nullptr;
    }
    // 新句柄是空状态：idle 计数清零（否则可能直接判闲跳过 process），
    // 组内峰值清零（viz 别跟着旧句柄的账本走）。
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        g_b.ctx.idleSamples[g] = 0;
        g_b.ctx.idle[g] = false;
        g_b.ctx.peakGrp[g] = 0.0;
        g_b.ctx.grpLive[g] = false;
        g_b.ctx.sigMark[g] = 0;
        g_b.ctx.sigSame[g] = 0;
    }
    g_b.ctx.gotFirst = 0;
    // 新句柄是出厂态：把桥内插件镜像回放到**全部组引擎**（BUGFIX 2026-10-22：
    // 原来只回放 eng[0]，CHANGE 重建后非 A1 总线丢失插件，监听总线无效果）。
    // 插件 load 是控制线程同步操作，此刻回调已停，不会碰 RT 线程。
    if (g_pluginFns.Ready()) {
        int ok = 0, failed = 0;
        for (int g = 0; g < g_b.ctx.nEng; ++g) {
            int o = 0, f2 = 0;
            g_pluginMirror.Replay(g_b.ctx.eng[g], g_pluginFns, &o, &f2);
            ok += o;
            failed += f2;
        }
        // 新引擎出厂 = 链全开；按路掩码重放（未勾选组重新关闭）。
        ApplyPluginGroupMask();
    }
}

// "id=f1.5;gain=i3" 解析并下发全部 handle（主线程/Dart 线程，无 RT 约束）。
void ApplyParamsString(const char* s) {
    if (!s || !*s || !g_b.ctx.destroy) return;
    // NOTE：set_param 函数指针取自 ctx 构建期；此处经 eng 重查以兼容重建后句柄。
    HMODULE eng = g_b.eng;
    if (!eng) return;
    auto setParam = (FnEngSetParam)GetProcAddress(eng, "auradsp_set_param");
    if (!setParam) {
        ++g_b.paramsFailed;
        return;
    }
    char buf[4096] = {0};
    strncpy_s(buf, s, sizeof(buf) - 1);
    // strtok 单线程调用（Dart 线程串行进本函数，无重入问题）。
    for (char* tok = strtok(buf, ";"); tok != nullptr; tok = strtok(nullptr, ";")) {
        char* eq = strchr(tok, '=');
        if (!eq || eq == tok) {
            ++g_b.paramsFailed;
            continue;
        }
        *eq = '\0';
        const char* id = tok;
        const char* vs = eq + 1;
        bool okAll = g_b.ctx.nEng > 0;
        if (strchr(vs, '.') || strchr(vs, 'e') || strchr(vs, 'E')) {
            const float f = (float)atof(vs);
            for (int g = 0; g < g_b.ctx.nEng; ++g) {
                if (setParam(g_b.ctx.eng[g], id, &f, 4) != 0) {
                    okAll = false;
                    break;
                }
            }
        } else {
            const int32_t iv = (int32_t)atoi(vs);
            for (int g = 0; g < g_b.ctx.nEng; ++g) {
                if (setParam(g_b.ctx.eng[g], id, &iv, 4) != 0) {
                    okAll = false;
                    break;
                }
            }
        }
        if (okAll)
            ++g_b.paramsApplied;
        else
            ++g_b.paramsFailed;
    }
}

DWORD WINAPI MonitorProc(LPVOID) {
    // CHANGE 到达 → stop → 重建引擎 → start（泵同式；短暂断流可接受 v1）。
    // 附带帧冻结看门狗：VB 彻底退出/引擎停转后回调不再来，表头会冻在最后一帧
    // （设置页 LED 常亮的根因）。frames 是回调计数（静音也涨），冻住 3s 即判
    // VB 走人：峰值清零 + 存活清零 + note 明示；回调恢复即清除。
    uint64_t lastFrames = 0;
    int stillRounds = 0;
    int grace = 25;  // 启动宽限 ~5s（VB 首包可能来得慢，别一上来就判死刑）
    bool gone = false;
    while (!InterlockedCompareExchange(&g_b.stopEvent, 0, 0)) {
        if (InterlockedExchange(&g_b.ctx.pendingChange, 0) != 0) {
            // 重建窗口内帧计数本就不动，看门狗此时闭嘴（别把"重启中"判成"走了"）。
            lastFrames = g_b.ctx.frames;
            stillRounds = 0;
            ++g_b.ctx.changes;
            // RT-safe 重建序列：stop(+50ms 余量) → 销毁旧句柄（无回调在跑）→
            // start 等新 STARTING 取新采样率 → 重建 → 回放参数镜像。
            // 引擎只在本线程建/销；start 到重建完成之间 process==nullptr，泵退化为
            // 直通（不吞声、不吊野指针），绝不在音频线程 create/destroy。
            const long oldSr = g_b.ctx.sr;  // STARTING 迟到时的兜底，别退回 48k
            if (g_b.stop) g_b.stop();
            Sleep(50);
            DestroyEngines();
            g_b.ctx.process = nullptr;
            const LONG wantInfo =
                InterlockedCompareExchange(&g_b.ctx.startInfo, 0, 0);
            bool started = false;
            for (int t = 0; t < 20; ++t) {
                if (InterlockedCompareExchange(&g_b.stopEvent, 0, 0)) break;
                if (g_b.start && g_b.start() == 0) {
                    started = true;
                    break;
                }
                Sleep(50);
            }
            if (started) {
                // 等 STARTING 把新 audioInfo（采样率/缓冲）送进来。改主输出设备会
                // 连带重建设备枚举，可能要几秒，故给 5s；且只认 samplerate>0 的那次
                // ——引擎未打开时 VM 可能先发一版全零 info，采信它会让引擎建在错
                // 速率上（听得出的音高/时序错位）。超时则用旧采样率续命。
                for (int t = 0; t < 200; ++t) {
                    if (InterlockedCompareExchange(&g_b.stopEvent, 0, 0)) break;
                    if (InterlockedCompareExchange(&g_b.ctx.startInfo, 0, 0) !=
                            wantInfo &&
                        g_b.ctx.sr > 0)
                        break;
                    Sleep(25);
                }
            }
            // 退出请求优先：这时绝不能再建引擎（stop 之后复活句柄 = 野指针）。
            if (InterlockedCompareExchange(&g_b.stopEvent, 0, 0)) break;
            const long newSr = g_b.ctx.sr;
            const float sr =
                (float)(newSr > 0 ? newSr : (oldSr > 0 ? oldSr : 48000));
            RebuildEngines(g_b.groupCount, sr);
            if (g_b.ctx.process) {
                auto setP = (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param");
                MirrorReplay(setP);
                ApplyBinauralChannels(setP);
                const int sok = StrMirrorReplay(
                    (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param"));
                if (g_strMirrorN > 0) {
                    char tail[48] = {0};
                    snprintf(tail, sizeof(tail), " s%d/%d", sok, g_strMirrorN);
                    strncat(g_b.note, tail,
                            sizeof(g_b.note) - strlen(g_b.note) - 1);
                }
            } else {
                snprintf(g_b.note, sizeof(g_b.note), "rebuild-failed");
            }
        }
        // 帧冻结看门狗（重建分支内已重置时钟，这里只数"无重建的静默轮"）。
        if (grace > 0) {
            --grace;
            lastFrames = g_b.ctx.frames;
        } else {
            const uint64_t f = g_b.ctx.frames;
            if (f != lastFrames) {
                lastFrames = f;
                stillRounds = 0;
                if (gone) {
                    gone = false;
                    if (strcmp(g_b.note, "voicemeeter-gone") == 0)
                        g_b.note[0] = '\0';
                }
            } else if (++stillRounds >= 15) {
                if (!gone) {
                    gone = true;
                    snprintf(g_b.note, sizeof(g_b.note), "voicemeeter-gone");
                }
                g_b.ctx.peakIn = 0.0;
                for (int g = 0; g < 8; ++g) {
                    g_b.ctx.peakGrp[g] = 0.0;
                    g_b.ctx.grpLive[g] = false;
                }
            }
        }
        Sleep(200);
    }
    return 0;
}

void FreeTestFile() {
    // 先清 kind 让 RT 停用，再等在途回调退出（~10ms 量级），最后释放。
    InterlockedExchange(&g_b.ctx.testKind, 0);
    Sleep(50);
    if (g_b.ctx.testFile) {
        free((void*)g_b.ctx.testFile);
        g_b.ctx.testFile = nullptr;
    }
    g_b.ctx.testFrames = 0;
    g_b.ctx.testPos = 0;
}

}  // namespace

int vb_detect(char* out, int cap) {
    if (!out || cap <= 0) return -1;
    const AuraVmDetect d = AuraVmDetectRun();
    char dir[512] = {0}, eng[512] = {0};
    PathForJson(d.installDir, dir, sizeof(dir));
    int n = snprintf(out, (size_t)cap,
                     "{\"found\":%s,\"edition\":%d,\"editionName\":\"%s\","
                     "\"installDir\":\"%s\",\"appVersion\":\"%s\","
                     "\"remoteVersion\":\"%s\",\"tierReached\":%d}",
                     d.found ? "true" : "false", d.edition,
                     d.editionName.c_str(), dir, d.appVersion.c_str(),
                     d.remoteVersion.c_str(), d.tierReached);
    return (n >= 0 && n < cap) ? n : -1;
}

int vb_start(const char* engine_dll, const char* params_json) {
    if (InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;  // 已在跑：幂等成功
    memset(&g_b.ctx, 0, sizeof(g_b.ctx));
    // memset 清掉了 busMask：从 session 级保管恢复（App 进桥后还会再推一次）。
    InterlockedExchange(&g_b.ctx.busMask, (LONG)(g_b.busMask & 0xFF));
    g_b.paramsApplied = 0;
    g_b.paramsFailed = 0;
    g_mirrorN = 0;  // 新会话：镜像由 App 侧 vb_start 后的重放重新填满
    StrMirrorReset();
    // 插件镜像同理：新会话从空开始，避免上一次桥会话的旧插件在
    // "用户已切走又切回"时抢跑。App 侧 start 成功后会按当前会话重放。
    g_pluginMirror.Reset();
    g_b.note[0] = '\0';
    g_b.edition = 0;
    g_b.startRc = -99;
    g_b.stopEvent = 0;
    g_b.remoteFreed = false;  // 复位：上一轮 stop 已释放，本轮重新计数
    // Remote DLL 定位（版本兼容关键）：优先用三级自省检出的安装目录——标准版/
    // 香蕉/土豆的默认与自定义安装路径都可能不同，写死 Program Files 会在自定义
    // 路径、新版本改目录时直接判死。内置两条默认路径只做兜底。
    const AuraVmDetect det0 = AuraVmDetectRun();
    g_b.edition = det0.edition;
    wchar_t first[MAX_PATH * 2] = {0};
    if (!det0.installDir.empty()) {
        std::wstring wdir = vmcore::ToWide(det0.installDir);
        if (!wdir.empty() && wdir.back() != L'\\' && wdir.back() != L'/')
            wdir += L'\\';
        wdir += L"VoicemeeterRemote64.dll";
        wcsncpy_s(first, wdir.c_str(), _TRUNCATE);
    }
    const wchar_t* dirs[3] = {
        first[0] ? first : L"",
        L"C:\\Program Files (x86)\\VB\\Voicemeeter\\VoicemeeterRemote64.dll",
        L"C:\\Program Files\\VB\\Voicemeeter\\VoicemeeterRemote64.dll",
    };
    for (const wchar_t* d : dirs) {
        if (!d || !*d) continue;
        g_b.remote = LoadLibraryW(d);
        if (g_b.remote) break;
    }
    if (!g_b.remote) {
        snprintf(g_b.note, sizeof(g_b.note), "no-voicemeeter-remote-dll");
        return -1;
    }
    auto reg = (FnReg)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackRegister");
    g_b.start = (FnStart)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackStart");
    g_b.stop = (FnStop)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackStop");
    g_b.unreg = (FnUnreg)GetProcAddress(g_b.remote, "VBVMR_AudioCallbackUnregister");
    auto login = (long(__stdcall*)())GetProcAddress(g_b.remote, "VBVMR_Login");
    g_b.logout = (long(__stdcall*)())GetProcAddress(g_b.remote, "VBVMR_Logout");
    if (!reg || !g_b.start || !g_b.stop || !g_b.unreg || !login || !g_b.logout) {
        // 旧版 Remote DLL 可能缺回调族导出：把版本写进 note，排障一眼可知。
        snprintf(g_b.note, sizeof(g_b.note), "remote-api-missing r%s",
                 det0.remoteVersion.empty() ? "?" : det0.remoteVersion.c_str());
        LeaveCtl(false);
        return -2;
    }
    login();
    char name[64] = {0};
    memcpy(name, "AuraDSP", 7);
    long rc = -99;
    // 首次注册前先尝试清理可能存在的残留/挂起注册槽位（常见于上一进程异常退出或强杀）
    if (g_b.unreg) g_b.unreg();
    for (int tries = 0; tries < 10; ++tries) {
        rc = reg(kModeOut, vmcore::OnVbCallback, &g_b.ctx, name);
        if (rc == 0 || rc == 1) break;
        // 注册失败（如 -2/-3 槽位被残留占用），尝试 unregister 自愈后再重试
        if (g_b.unreg) g_b.unreg();
        Sleep(100);
    }
    g_b.startRc = (int)rc;
    if (rc == 1) {
        snprintf(g_b.note, sizeof(g_b.note), "out-slot-busy");
        LeaveCtl(true);
        return 1;
    }
    if (rc != 0) {
        snprintf(g_b.note, sizeof(g_b.note), "register-failed rc=%ld", rc);
        LeaveCtl(true);
        return -3;
    }
    // 版型已在入口处由 AuraVmDetectRun 确定（g_b.edition），重建沿用 groupCount。
    std::wstring used;
    std::string hint = (engine_dll && *engine_dll) ? engine_dll : "";
    g_b.eng = vmcore::TryLoadEngine(hint, used);
    if (!used.empty()) {
        WideCharToMultiByte(CP_UTF8, 0, used.c_str(), -1, g_b.enginePath,
                            (int)sizeof(g_b.enginePath), nullptr, nullptr);
    }
    FnEngCreate create = nullptr;
    if (g_b.eng) {
        create =
            (FnEngCreate)GetProcAddress(g_b.eng, "auradsp_create");
        g_b.create = create;  // CHANGE 重建用；此前漏赋导致重建后零 handle 静默透传
        g_b.ctx.process =
            (FnEngProcess)GetProcAddress(g_b.eng, "auradsp_process");
        g_b.ctx.destroy =
            (FnEngDestroy)GetProcAddress(g_b.eng, "auradsp_destroy");
        g_b.vizRead =
            (FnEngVizRead)GetProcAddress(g_b.eng, "auradsp_viz_read");
        g_b.getParam =
            (FnEngGetParam)GetProcAddress(g_b.eng, "auradsp_get_param");
        g_pluginFns.Resolve(g_b.eng);
        if (create && g_b.ctx.process && g_b.ctx.destroy) {
            g_b.ctx.scratchIn =
                (float*)malloc(sizeof(float) * 8 * vmcore::kMaxNbs);
            g_b.ctx.scratchOut =
                (float*)malloc(sizeof(float) * 8 * vmcore::kMaxNbs);
            // 版型→预建组数（EAPO 同式 min(nbi,nbo)/8 由泵在运行时再钳；未知版型按 8 建，
            // 多建无害（泵按实际 ng 取用，空 handle 守卫透传），少建才会吞声。
            int want = PumpCtx::kMaxGroups;
            if (g_b.edition == 1)
                want = 2;
            else if (g_b.edition == 2)
                want = 5;
            g_b.groupCount = want;  // CHANGE 重建沿用版型应建数，不看会漂的 ctx.groups
            const float sr0 = 48000.0f;
            for (int g = 0; g < want; ++g) {
                g_b.ctx.eng[g] = create(sr0, 2048);
                if (g_b.ctx.eng[g]) ++g_b.ctx.nEng;
            }
            if (!g_b.ctx.scratchIn || !g_b.ctx.scratchOut ||
                g_b.ctx.nEng == 0) {
                DestroyEngines();
                g_b.ctx.process = nullptr;
            }
        }
        if (!g_b.ctx.process) {
            FreeLibrary(g_b.eng);
            g_b.eng = nullptr;
        }
    }
    ApplyParamsString(params_json);
    if (g_b.start() != 0) {
        snprintf(g_b.note, sizeof(g_b.note), "start-failed");
        DestroyEngines();
        LeaveCtl(true);
        return -4;
    }
    g_b.monitor = CreateThread(nullptr, 0, MonitorProc, nullptr, 0, nullptr);
    InterlockedExchange(&g_b.running, 1);
    // 启动后应用按路插件掩码（新引擎出厂 = 链全开，会话掩码覆盖之）
    ApplyPluginGroupMask();
    return 0;
}

int vb_stop() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;  // 幂等
    InterlockedExchange(&g_b.stopEvent, 1);
    if (g_b.monitor) {
        WaitForSingleObject(g_b.monitor, 3000);
        CloseHandle(g_b.monitor);
        g_b.monitor = nullptr;
    }
    if (g_b.stop) g_b.stop();
    FreeTestFile();
    DestroyEngines();
    if (g_b.ctx.scratchIn) free(g_b.ctx.scratchIn);
    if (g_b.ctx.scratchOut) free(g_b.ctx.scratchOut);
    g_b.ctx.scratchIn = g_b.ctx.scratchOut = nullptr;
    if (g_b.eng) {
        FreeLibrary(g_b.eng);
        g_b.eng = nullptr;
    }
    LeaveCtl(true);  // 单次配对：logout + unreg
    InterlockedExchange(&g_b.running, 0);
    return 0;
}

// viz 跟随当前最热组：信号可能不在 group0 总线上（用户路由决定），
// 只读 eng[0] 会在 group0 静默时永久空 viz，而别的组照常出声。
// 要件：跳过 idle 组（停产 viz 帧，峰值可能是衰减中的僵尸热）；全 idle 时
// 回落 0（诚实空 viz——对端确实无声）。调用方（status/viz）节流读取。
static int HottestVizGroup() {
    const long mask = InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0);
    // 守擂：现任仍合格时，挑战者需超现任 2 倍（+6dB）才换——两组电平相当时来回
    // 横跳，频谱内容跟着闪（主页/可视化页闪动的根因之一）。现任静默（0）时任何
    // 有声组立即接管，不加延迟。
    const int cur = g_b.ctx.vizStick;
    const bool curOk = cur >= 0 && cur < vmcore::PumpCtx::kMaxGroups &&
                       g_b.ctx.eng[cur] && !g_b.ctx.idle[cur] &&
                       (mask & (1L << cur)) != 0;
    int best = curOk ? cur : 0;
    double bp = curOk ? g_b.ctx.peakGrp[cur] * 2.0 : -1.0;
    for (int g = 0; g < vmcore::PumpCtx::kMaxGroups; ++g) {
        if (!g_b.ctx.eng[g]) continue;
        if (g_b.ctx.idle[g]) continue;  // 僵尸热组排除：在产帧的组里选
        if ((mask & (1L << g)) == 0) continue;  // 被 mask 关掉的总线：看的是干声，不跟
        const double p = g_b.ctx.peakGrp[g];
        if (p > bp) {
            bp = p;
            best = g;
        }
    }
    g_b.ctx.vizStick = best;
    return best;
}

int vb_status(char* out, int cap) {
    if (!out || cap <= 0) return -1;
    LARGE_INTEGER qpf;
    double cbUs = 0;
    if (QueryPerformanceFrequency(&qpf) && qpf.QuadPart > 0)
        cbUs = (double)g_b.ctx.maxCbTicks * 1000000.0 / (double)qpf.QuadPart;
    char eng[512] = {0};
    PathForJson(g_b.enginePath, eng, sizeof(eng));
    const int vizGrp = HottestVizGroup();
    int liveMask = 0;
    for (int g = 0; g < vmcore::PumpCtx::kMaxGroups; ++g)
        if (g_b.ctx.grpLive[g]) liveMask |= (1 << g);
    char peaks[256] = {0};
    snprintf(peaks, sizeof(peaks), "[%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f]",
             g_b.ctx.peakGrp[0], g_b.ctx.peakGrp[1], g_b.ctx.peakGrp[2],
             g_b.ctx.peakGrp[3], g_b.ctx.peakGrp[4], g_b.ctx.peakGrp[5],
             g_b.ctx.peakGrp[6], g_b.ctx.peakGrp[7]);
    // L0：每组 process 耗时峰值（μs）——爆音定位（8 组串行主成本）。
    // ticks→μs：ticks / qpf * 1e6；qpf 无效（极罕见）时记 0。
    char maxG[128] = {0};
    {
        double us[8] = {0};
        const double q = (double)(qpf.QuadPart > 0 ? qpf.QuadPart : 1);
        for (int i = 0; i < 8; ++i) {
            us[i] = (double)g_b.ctx.maxGroupTicks[i] * 1000000.0 / q;
        }
        snprintf(maxG, sizeof(maxG),
                 "[%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f]", us[0], us[1],
                 us[2], us[3], us[4], us[5], us[6], us[7]);
    }
    int n = snprintf(out, (size_t)cap,
                     "{\"running\":%s,\"frames\":%llu,\"sr\":%ld,\"nbs\":%ld,"
                     "\"groups\":%d,\"handles\":%d,\"peakIn\":%.6f,"
                     "\"maxCbUs\":%.1f,\"startRc\":%d,\"note\":\"%s\","
                     "\"testKind\":%ld,\"bypass\":%ld,\"vizGrp\":%d,"
                     "\"changes\":%lld,\"mirrorN\":%d,\"busMask\":%d,\"grpLive\":%d,"
                     "\"peakGrp\":%s,\"maxGroupUs\":%s,\"edition\":%d,\"engine\":\"%s\"}",
                      InterlockedCompareExchange(&g_b.running, 0, 0) ? "true"
                                                                     : "false",
                      (unsigned long long)g_b.ctx.frames, g_b.ctx.sr,
                      g_b.ctx.nbs, g_b.ctx.groups, g_b.ctx.nEng, g_b.ctx.peakIn,
                      cbUs, g_b.startRc, g_b.note, (long)g_b.ctx.testKind,
                      (long)g_b.ctx.userBypass, vizGrp,
                      (long long)g_b.ctx.changes, g_mirrorN + g_strMirrorN,
                      (int)(InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0) &
                            0xFF),
                      liveMask, peaks, maxG, g_b.edition, eng);
    // peakGrp 已在回调级衰减，此处不再动（避免与回调线程叠加衰减失真）。
    return (n >= 0 && n < cap) ? n : -1;
}

int vb_set_param(const char* id, int isFloat, const void* v4) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !v4 || !g_b.eng) return -2;
    auto setParam = (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param");
    if (!setParam) return -3;
    MirrorSet(id, isFloat != 0, v4);  // 重建后要靠它回放
    int ok = 0;
    for (int g = 0; g < g_b.ctx.nEng; ++g) {
        if (g_b.ctx.eng[g] && setParam(g_b.ctx.eng[g], id, v4, 4) == 0) ++ok;
    }
    if (!isFloat && strcmp(id, "spatial.binaural") == 0) {
        InterlockedExchange(&g_b.ctx.binaural, *(const int32_t*)v4 ? 1 : 0);
        ApplyBinauralChannels(setParam);
    }
    return ok;
}

int vb_set_param_str(const char* id, const char* utf8, int bytes) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !utf8 || bytes <= 0 || bytes > 256 * 1024) return -2;
    if (!g_b.eng) return -3;
    auto setParam = (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param");
    if (!setParam) return -4;
    int ok = 0;
    for (int g = 0; g < g_b.ctx.nEng; ++g) {
        if (g_b.ctx.eng[g] && setParam(g_b.ctx.eng[g], id, utf8, (unsigned)bytes) == 0)
            ++ok;
    }
    // 全成功才记镜像（编译失败时引擎保留旧程序，镜像必须跟这个语义对齐，
    // 否则重建后新句柄会被坏代码清空）。
    if (ok == g_b.ctx.nEng && g_b.ctx.nEng > 0)
        StrMirrorSet(id, utf8, bytes);
    return ok;
}

int vb_get_param(const char* id, int isFloat, void* out4) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !out4 || !g_b.getParam || !g_b.ctx.eng[0]) return -2;
    return g_b.getParam(g_b.ctx.eng[0], id, out4, 4) == 0 ? 0 : -3;
}

int vb_get_param_str(const char* id, char* out, int cap) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !out || cap <= 1 || !g_b.getParam || !g_b.ctx.eng[0]) return -2;
    out[0] = 0;
    if (g_b.getParam(g_b.ctx.eng[0], id, out, (unsigned)cap) != 0) return -3;
    out[cap - 1] = 0;  // 引擎保证 NUL 结尾，这里再兜一层
    return (int)strlen(out);
}

int vb_test_change() {
    // 诊断/回归用：模拟一次 VM CHANGE（真实路径由 VB 推 kCbChange 置位同标志）。
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    InterlockedExchange(&g_b.ctx.pendingChange, 1);
    return 0;
}

int vb_viz_read(void* out408, int count) {
    if (!out408 || count <= 0) return -1;
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.vizRead) return 0;
    const int g = HottestVizGroup();
    if (!g_b.ctx.eng[g]) return 0;
    return g_b.vizRead(g_b.ctx.eng[g], out408, count);
}

int vb_test_start(int kind, const float* pcm, int frames, int ch, int rate) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (kind < 1 || kind > 3) return -2;
    FreeTestFile();
    if (kind == 3) {
        // 文件 PCM 拷贝（交织立体声 float32；单声道铺双声道）。
        if (!pcm || frames <= 0 || rate <= 0) return -3;
        const int srcCh = (ch == 1) ? 1 : 2;
        float* buf = (float*)malloc(sizeof(float) * (size_t)frames * 2);
        if (!buf) return -4;
        for (int i = 0; i < frames; ++i) {
            if (srcCh == 1) {
                buf[i * 2] = buf[i * 2 + 1] = pcm[i];
            } else {
                buf[i * 2] = pcm[i * 2];
                buf[i * 2 + 1] = pcm[i * 2 + 1];
            }
        }
        g_b.ctx.testFile = buf;
        g_b.ctx.testFrames = (uint64_t)frames;
        g_b.ctx.testRate = rate;
        g_b.ctx.testPos = 0;
    }
    g_b.ctx.testPhase = 0;
    g_b.ctx.testRng = 0x12345678u;
    for (int i = 0; i < 7; ++i) g_b.ctx.testPink[i] = 0;
    InterlockedExchange(&g_b.ctx.testKind, (LONG)kind);
    return 0;
}

int vb_test_stop() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    FreeTestFile();
    return 0;
}

int vb_bypass(int on) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    InterlockedExchange(&g_b.ctx.userBypass, on ? 1 : 0);
    return 0;
}

int vb_set_bus_mask(int mask) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    mask &= 0xFF;
    const int oldBus = g_b.busMask & 0xFF;
    g_b.busMask = mask;  // session 级保管（ctx 会被 memset，CHANGE 重建不丢）
    InterlockedExchange(&g_b.ctx.busMask, (LONG)mask);
    // 加速/CPU（2026-10-23）：新使能的总线若已有插件、但该组实例尚缺
    // （加载时不在掩码内被跳过），后台补挂。
    BackfillGroupsForMask(mask & ~oldBus);
    return mask;
}

// ---- 插件槽（BUGFIX 2026-10-22：写操作同步到全部组引擎）----
// 桥模式下 Dart 把 pluginSlot* 路由到这里；引擎仍是桥自己加载的那一份，
// 因此插件与音频在同一条 DSP 链上。桥未运行/引擎缺失时一律返回 0。
// 语义约定：
//   写操作（load/unload/bypass/stage/channels/preset）→ 全部组引擎逐个下发，
//   各总线插件集保持一致；load 任一组失败即回滚已加载组（状态不留半套）。
//   读操作与编辑器（status/latency/editor/savePreset）→ eng[0] 单实例
//   （编辑器 GUI 的参数改动只作用于 A1 实例，不跨总线同步——各引擎内
//   插件实例本就独立，这是 Voicemeeter 每总线独立 handle 架构的固有限制）。
int vb_plugin_slot_load(int slot, const char* path, const char* plugin_id) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_pluginFns.Ready()) return 0;
    const int n = PluginEngineCount();
    if (n <= 0) return 0;
    // 本次加载起，此前排队/在途的后台补齐一律作废（代际递增）。
    const uint32_t gen = g_bgGen.fetch_add(1) + 1;
    // P2 防抖：加载是重 IO/内存操作，压低当前线程优先级，让 RT 回调
    // （Pro Audio）优先拿 CPU——消加载期抢核导致的断续。
    HANDLE thr = GetCurrentThread();
    int oldPrio = GetThreadPriority(thr);
    SetThreadPriority(thr, THREAD_PRIORITY_BELOW_NORMAL);
    // 加速（2026-10-23）：只同步加载 eng[0]（~2-3.7s，实测 Ozone 12），
    // 其余组后台补齐（原逐组同步：4 组 9.7s / 8 组近 20s）。
    int rc0;
    {
        std::lock_guard<std::mutex> eng(g_engineMut);
        rc0 = auraplugin::SlotLoad(PluginEngineAt(0), g_pluginFns,
                                   g_pluginMirror, slot, path, plugin_id);
    }
    SetThreadPriority(thr, oldPrio);
    if (rc0 != 1) return 0;   // eng[0] 失败 = 整体失败（镜像未被改写）
    g_grpLoaded[0].fetch_or(1u << slot);
    // 新加载：该槽的挂起预设作废（旧请求属于上一次挂载）。
    {
        std::lock_guard<std::mutex> lk(g_pendMutex);
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) g_pendHasPreset[g][slot] = false;
    }
    if (n > 1) {
        EnsureBgThread();
        {
            std::lock_guard<std::mutex> lk(g_bgMutex);
            g_bgJobs.push_back(PendingGroupLoad{gen, slot, path ? path : "",
                                                plugin_id ? plugin_id : ""});
        }
        g_bgCv.notify_one();
    }
    return 1;
}

int vb_plugin_slot_unload(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    // 取消在途/排队中的后台补齐（代际递增），并与其互斥（不得并发碰引擎）。
    g_bgGen.fetch_add(1);
    const int n = PluginEngineCount();
    // 同 load：卸载 teardown 也是重操作，降优先级护 RT。
    HANDLE thr = GetCurrentThread();
    int oldPrio = GetThreadPriority(thr);
    SetThreadPriority(thr, THREAD_PRIORITY_BELOW_NORMAL);
    {
        std::lock_guard<std::mutex> eng(g_engineMut);
        for (int g = 0; g < n; ++g) {
            auraplugin::SlotUnload(PluginEngineAt(g), g_pluginFns, g_pluginMirror,
                                   slot);
        }
    }
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        g_grpLoaded[g].fetch_and(~(1u << slot));
    }
    {
        std::lock_guard<std::mutex> lk(g_pendMutex);
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) g_pendHasPreset[g][slot] = false;
    }
    SetThreadPriority(thr, oldPrio);
    return n > 0 ? 1 : 0;
}

int vb_plugin_slot_set_bypass(int slot, int bypass) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    const int n = PluginEngineCount();
    for (int g = 0; g < n; ++g) {
        auraplugin::SlotSetBypass(PluginEngineAt(g), g_pluginFns,
                                  g_pluginMirror, slot, bypass);
    }
    return n > 0 ? 1 : 0;
}

int vb_plugin_slot_get_bypass(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.getBypass(e, slot);
}

unsigned vb_plugin_slot_get_latency(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.getLatency(e, slot);
}

int vb_plugin_slot_get_status(int slot, char* out, int cap) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) {
        if (out && cap > 0) out[0] = 0;
        return 0;
    }
    return auraplugin::SlotGetStatus(PluginEngine(), g_pluginFns, slot, out,
                                     cap);
}

int vb_plugin_slot_show_editor(int slot, const char* title) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.showEditor(e, slot, title);
}

/* 按路编辑器（作用于组 g 的引擎实例；group 越界/该组无引擎返回 0）。 */
int vb_plugin_slot_show_editor_g(int slot, int group, const char* title) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngineAt(group);
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.showEditor(e, slot, title);
}

int vb_plugin_slot_close_editor(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.closeEditor(e, slot);
}

int vb_plugin_slot_close_editor_g(int slot, int group) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngineAt(group);
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.closeEditor(e, slot);
}

int vb_plugin_slot_is_editor_open(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.isEditorOpen(e, slot);
}

int vb_plugin_slot_is_editor_open_g(int slot, int group) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngineAt(group);
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.isEditorOpen(e, slot);
}

int vb_plugin_slot_save_preset(int slot, const char* path) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.savePreset(e, slot, path);
}

int vb_plugin_slot_load_preset(int slot, const char* path) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_pluginFns.Ready()) return 0;
    // 预设改变插件状态，必须同步到全部组引擎（与 load 同语义）
    const int n = PluginEngineCount();
    for (int g = 0; g < n; ++g) {
        if (!g_pluginFns.loadPreset(PluginEngineAt(g), slot, path)) return 0;
    }
    return n > 0 ? 1 : 0;
}

/* P2-1（v3.3 A/B 预设）：per-group state 读写。VB 各路 A/B 预设按
 * (slot, route) 独立存储，save/load 只作用该组实例；group 越界/无引擎 0。 */
int vb_plugin_slot_save_preset_g(int slot, int group, const char* path) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngineAt(group);
    if (!e || !g_pluginFns.Ready()) return 0;
    return g_pluginFns.savePreset(e, slot, path) ? 1 : 0;
}

int vb_plugin_slot_load_preset_g(int slot, int group, const char* path) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngineAt(group);
    if (!e || !g_pluginFns.Ready()) return 0;
    // 加速（2026-10-23）：该组尚未补齐（后台在加载）时先挂起——补齐后由
    // 工作线程应用一次。返回 1 = 已受理（Dart 侧不必重试）。
    if (group >= 0 && group < PumpCtx::kMaxGroups && slot >= 0 &&
        slot < auraplugin::kSlots &&
        (g_grpLoaded[group].load() & (1u << slot)) == 0) {
        std::lock_guard<std::mutex> lk(g_pendMutex);
        g_pendPreset[group][slot] = path ? path : "";
        g_pendHasPreset[group][slot] = true;
        return 1;
    }
    return g_pluginFns.loadPreset(e, slot, path) ? 1 : 0;
}

int vb_plugin_slot_set_insert_stage(int slot, int stage) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    const int n = PluginEngineCount();
    for (int g = 0; g < n; ++g) {
        auraplugin::SlotSetStage(PluginEngineAt(g), g_pluginFns,
                                 g_pluginMirror, slot, stage);
    }
    return n > 0 ? 1 : 0;
}

int vb_plugin_slot_get_insert_stage(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 3;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 3;
    return g_pluginFns.getStage(e, slot);
}

int vb_plugin_slot_set_channels(int slot, int channels) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    const int n = PluginEngineCount();
    for (int g = 0; g < n; ++g) {
        auraplugin::SlotSetChannels(PluginEngineAt(g), g_pluginFns,
                                    g_pluginMirror, slot, channels);
    }
    return n > 0 ? 1 : 0;
}

int vb_plugin_slot_get_channels(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0xFF;
    void* e = PluginEngine();
    if (!e || !g_pluginFns.Ready()) return 0xFF;
    return g_pluginFns.getChannels(e, slot);
}

/* P1-3 per-group Ch 下发（VB 具体路独立记忆；group 越界/无引擎返回 0）。 */
int vb_plugin_slot_set_channels_g(int slot, int group, int channels) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    void* e = PluginEngineAt(group);
    if (!e || !g_pluginFns.Ready()) return 0;
    auraplugin::SlotSetChannels(e, g_pluginFns, g_pluginMirror, slot, channels);
    return 1;
}

// ---- 按路插件处理掩码 ----
// bit g = 组 g 的总线是否吃插件链。接受任意 8 bit 掩码（掩码位超出当前
// 组数无害——引擎按位取用，多余位被忽略；重建组数变化后重放自动适配）。
int vb_plugin_group_enable(int mask) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    mask &= 0xFF;
    const LONG oldMask = InterlockedExchange(&g_pluginGroupMask, (LONG)mask);
    ApplyPluginGroupMask();
    // 加速（2026-10-23）：新使能的组若已挂插件但该组实例尚缺（加载时被
    // 掩码跳过），后台补齐——否则该总线只有厂商 DSP、插件永远不生效。
    BackfillGroupsForMask(mask & ~(int)oldMask);
    return mask;
}

int vb_plugin_group_mask() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0xFF;
    return InterlockedCompareExchange(&g_pluginGroupMask, 0, 0);
}

int vb_plugin_slot_group_ready(int slot, int group) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (slot < 0 || slot >= auraplugin::kSlots) return 0;
    if (group < 0 || group >= PumpCtx::kMaxGroups) return 0;
    return (g_grpLoaded[group].load(std::memory_order_acquire) & (1u << slot))
               ? 1
               : 0;
}
