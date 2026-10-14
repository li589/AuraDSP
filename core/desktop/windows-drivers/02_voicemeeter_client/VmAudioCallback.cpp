// VmAudioCallback.cpp — 见头文件 v1 范围与 RT 铁律。
//
// 死锁审计（结论：结构上不可能死锁）：
// ① RT 回调内零锁（无 mutex/CriticalSection/原子自旋；与 engine 的唯一共享是
//    主线程建好后只读的函数指针 + RT 独占的 ctx 字段；VB 保证回调不重入）；
// ② 主线程只 Sleep 轮询 + 顺序 join（无等待回调的原语；stop/unreg/logout 全是
//    发后不管的同步调用，不依赖回调回执）；③ 不存在锁序（全程无锁）。
// 崩溃面：进程崩溃会滞留 OUT 槽（VM 侧无超时回收，只能重启 VM 或等槽主退出）；
// R 会话靠 Logout 配对释放（漏一次攒一个 R，上限 8）。
#include "VmRemoteLoader.h"
//
// 借鉴注（source/equalizerAPO64/VoicemeeterClient/VoicemeeterClient.cpp:handle）：
// ① 按 8 通道 bus 组迭代（`min(nbi,nbo)/8`，每组独立 FilterEngine）——v1 只做第 0 组
//    的立体声主对，其余透传；多总线逐对即把循环展开到各组。
// ② 静音空转三条件：精确零输入 + 本次输出精确零 + 持续 10s（弱音/混响尾不误杀），
//    idle 后纯 memcpy；输入重现 1 块内回神。初版的“1e-5 峰值 + 2s”已按此推翻。
// ③ CHANGE 用 PostThreadMessage 式重启——v1 只计数不断链（changes 上报），后续 slice 接。
#include "VmAudioCallback.h"

#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// ---- VBVMR 回调 ABI（官方 VoicemeeterRemote.h 誓约，动态加载不链 SDK） ----
namespace {

constexpr long kCbStarting = 1;
constexpr long kCbEnding = 2;
constexpr long kCbChange = 3;
constexpr long kCbBufferIn = 10;
constexpr long kCbBufferOut = 11;
constexpr long kCbBufferMain = 20;

constexpr long kModeOut = 0x00000002;  // OUTPUT INSERT（master 前）

struct VbAudioInfo {
    long samplerate;
    long nbSamplePerFrame;
};

struct VbAudioBuffer {
    long sr;
    long nbs;
    long nbi;
    long nbo;
    float* r[128];
    float* w[128];
};

using FnCb = long(__stdcall*)(void*, long, void*, long);
using FnReg = long(__stdcall*)(long, FnCb, void*, char*);
using FnStart = long(__stdcall*)();
using FnStop = long(__stdcall*)();
using FnUnreg = long(__stdcall*)();

// ---- 引擎桥（auradsp_engine.dll 动态加载；与 app/ffi 候选路径同源） ----
using FnEngCreate = void*(__cdecl*)(float, int);
using FnEngProcess = void(__cdecl*)(void*, const float*, float*, int);
using FnEngDestroy = void(__cdecl*)(void*);
using FnEngSetParam = int(__cdecl*)(void*, const char*, const void*, unsigned int);

constexpr int kMaxNbs = 4096;  // 超出则该对透传（防爆栈/堆，实测 VM 给 512/1024）

struct PumpCtx {
    FnEngProcess process = nullptr;
    FnEngDestroy destroy = nullptr;
    static constexpr int kMaxGroups = 8;
    void* eng[kMaxGroups] = {};  // 主线程按版型预建（RT 内禁分配）
    int nEng = 0;
    float* scratchIn = nullptr;   // 主线程预分配 2*kMaxNbs（各组串行复用，非重入安全）
    float* scratchOut = nullptr;
    uint64_t frames = 0;
    uint64_t maxCbTicks = 0;  // 单次 BUFFER_OUT 最大耗时（QPC ticks；爆音预算证据）
    volatile LONG gotFirst = 0;  // 首个 BUFFER 到达（主线程轮询，RT 只存一次）
    uint64_t idleSamples[kMaxGroups] = {};  // 组独立（EAPO 同式）
    bool idle[kMaxGroups] = {};
    long sr = 0;
    long nbs = 0;
    long changes = 0;             // CHANGE 到达计数（已落地重建，见主循环）
    volatile LONG pendingChange = 0;  // RT 置位，主线程轮询消费（无锁单写单读）
    int groups = 0;               // 本轮实际组数
    double maxDiff = 0.0;
    double peakIn = 0.0;  // 主对输入峰值（判定“有没有声”，smoke 条件断言用）
    bool bypassEntered = false;
};

inline bool PairIsSilent(const float* a, const float* b, long n) {
    // EAPO 同式：精确零才算静默（-100dBFS 的弱音也算有声，不误杀；见借鉴注）。
    for (long i = 0; i < n; ++i) {
        if (a[i] != 0.0f || b[i] != 0.0f) return false;
    }
    return true;
}

long __stdcall OnVbCallback(void* lpUser, long cmd, void* lpData, long /*nnn*/) {
    auto* c = (PumpCtx*)lpUser;
    if (cmd == kCbStarting) {
        auto* info = (VbAudioInfo*)lpData;
        c->sr = info->samplerate;
        c->nbs = info->nbSamplePerFrame;
        c->frames = 0;
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            c->idleSamples[g] = 0;
            c->idle[g] = false;
        }
        c->maxDiff = 0.0;
        c->bypassEntered = false;
        return 0;
    }
    if (cmd == kCbEnding) return 0;
    if (cmd == kCbChange) {
        // 采样率/缓冲变化：置位让主线程停泵重建引擎（勿在 RT 内 create/destroy）。
        InterlockedExchange(&c->pendingChange, 1);
        return 0;
    }
    if (cmd != kCbBufferOut) return 0;
    c->gotFirst = 1;
    // 爆音预算：整块处理耗时打点（QPC 无等待，~50ns，可忽略；8 组串行是主要成本）。
    LARGE_INTEGER t0, t1;
    QueryPerformanceCounter(&t0);
    auto* ab = (VbAudioBuffer*)lpData;
    if (ab->nbo < 2 || ab->nbs <= 0 || ab->nbs > kMaxNbs) return 0;
    const long n = ab->nbs;
    // 组数 = min(nbi,nbo)/8（EAPO 同式），钳到预建 handle 数。
    int ng = (int)(ab->nbi < ab->nbo ? ab->nbi : ab->nbo) / 8;
    if (ng < 1) ng = 1;
    // 只按硬上限钳；缺 handle 的组内各自透传（haveEng/eng[g] 守卫），不整体归零。
    if (ng > PumpCtx::kMaxGroups) ng = PumpCtx::kMaxGroups;
    c->groups = ng;
    const bool haveEng = c->process != nullptr;
    for (int g = 0; g < ng; ++g) {
        const long base = (long)g * 8;
        // v2：每组主对（base+0/1）进该组引擎；组内其余 6 通道 + 组外全部透传。
        const float* inL = ab->r[base];
        const float* inR = ab->r[base + 1];
        float* outL = ab->w[base];
        float* outR = ab->w[base + 1];
        if (!inL || !inR || !outL || !outR) continue;
        // 输入峰值（全组主对的最大值；smoke 据此判定“有没有声”）。
        for (long i = 0; i < n; ++i) {
            const double a = inL[i] < 0 ? -(double)inL[i] : (double)inL[i];
            const double b = inR[i] < 0 ? -(double)inR[i] : (double)inR[i];
            const double m = a > b ? a : b;
            if (m > c->peakIn) c->peakIn = m;
        }
        for (long ch = base + 2; ch < base + 8; ++ch) {
            if (ab->w[ch] && ab->r[ch] && ab->w[ch] != ab->r[ch])
                memcpy(ab->w[ch], ab->r[ch], (size_t)n * sizeof(float));
        }
        // 无引擎桥（DLL 缺失/符号不全/组超预建）：主对也透传，绝不吞声。
        if (!haveEng || c->eng[g] == nullptr) {
            if (outL != inL) memcpy(outL, inL, (size_t)n * sizeof(float));
            if (outR != inR) memcpy(outR, inR, (size_t)n * sizeof(float));
            continue;
        }
        // 静音空转（组独立，EAPO 同式）。
        if (!c->idle[g]) {
            for (long i = 0; i < n; ++i) {
                c->scratchIn[i * 2] = inL[i];
                c->scratchIn[i * 2 + 1] = inR[i];
            }
            c->process(c->eng[g], c->scratchIn, c->scratchOut, (int)n);
            bool outSilent = true;
            for (long i = 0; i < n; ++i) {
                const float oL = c->scratchOut[i * 2], oR = c->scratchOut[i * 2 + 1];
                outL[i] = oL;
                outR[i] = oR;
                if (oL != 0.0f || oR != 0.0f) outSilent = false;
                const double dL = (double)oL - (double)inL[i];
                const double dR = (double)oR - (double)inR[i];
                const double d = dL < 0 ? -dL : (dR < 0 ? -dR : (dL > dR ? dL : dR));
                if (d > c->maxDiff) c->maxDiff = d;
            }
            const bool inSilent = PairIsSilent(inL, inR, n);
            if (inSilent && outSilent)
                c->idleSamples[g] += (uint64_t)n;
            else
                c->idleSamples[g] = 0;
            c->idle[g] = c->sr > 0 && c->idleSamples[g] > (uint64_t)c->sr * 10;
        } else {
            c->bypassEntered = true;
            memcpy(outL, inL, (size_t)n * sizeof(float));
            memcpy(outR, inR, (size_t)n * sizeof(float));
            if (!PairIsSilent(inL, inR, n)) {
                c->idle[g] = false;
                c->idleSamples[g] = 0;
            }
        }
    }
    // 组外通道透传。
    for (long ch = (long)ng * 8; ch < ab->nbo && ch < 128; ++ch) {
        if (ab->w[ch] && ab->r[ch] && ab->w[ch] != ab->r[ch])
            memcpy(ab->w[ch], ab->r[ch], (size_t)n * sizeof(float));
    }
    c->frames += (uint64_t)n;
    QueryPerformanceCounter(&t1);
    const uint64_t dt = (uint64_t)(t1.QuadPart - t0.QuadPart);
    if (dt > c->maxCbTicks) c->maxCbTicks = dt;
    return 0;
}

std::wstring ToWide(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring w((size_t)n - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    return w;
}

// exe 所在目录。
std::wstring ExeDir() {
    wchar_t p[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, p, MAX_PATH);
    std::wstring s(p);
    const size_t k = s.find_last_of(L"\\/");
    return (k == std::wstring::npos) ? L"." : s.substr(0, k);
}

HMODULE TryLoadEngine(const std::string& hint, std::wstring& used) {
    std::vector<std::wstring> cands;
    if (!hint.empty()) cands.push_back(ToWide(hint));
    const std::wstring exe = ExeDir();
    cands.push_back(exe + L"\\auradsp_engine.dll");
    // windows-drivers/out/Release → 上三层到 desktop → windows/out/Release
    cands.push_back(exe + L"\\..\\..\\..\\windows\\out\\Release\\auradsp_engine.dll");
    cands.push_back(L"C:\\Program Files\\AuraDSP\\auradsp_engine.dll");
    for (const auto& c : cands) {
        HMODULE h = LoadLibraryW(c.c_str());
        if (h) {
            used = c;
            return h;
        }
    }
    return nullptr;
}

}  // namespace

int AuraVmPumpRun(AuraVmPump& p) {
    // Remote DLL：复用探测逻辑定的目录（注册表→默认），此处直接试两个标准位。
    const wchar_t* dirs[2] = {
        L"C:\\Program Files (x86)\\VB\\Voicemeeter\\VoicemeeterRemote64.dll",
        L"C:\\Program Files\\VB\\Voicemeeter\\VoicemeeterRemote64.dll",
    };
    HMODULE remote = nullptr;
    for (const wchar_t* d : dirs) {
        remote = LoadLibraryW(d);
        if (remote) break;
    }
    if (!remote) {
        p.note = "no-voicemeeter-remote-dll";
        return 0;
    }
    auto reg = (FnReg)GetProcAddress(remote, "VBVMR_AudioCallbackRegister");
    auto start = (FnStart)GetProcAddress(remote, "VBVMR_AudioCallbackStart");
    auto stop = (FnStop)GetProcAddress(remote, "VBVMR_AudioCallbackStop");
    auto unreg = (FnUnreg)GetProcAddress(remote, "VBVMR_AudioCallbackUnregister");
    auto login = (long(__stdcall*)())GetProcAddress(remote, "VBVMR_Login");
    auto logout = (long(__stdcall*)())GetProcAddress(remote, "VBVMR_Logout");
    if (!reg || !start || !stop || !unreg || !login || !logout) {
        FreeLibrary(remote);
        p.note = "remote-api-missing";
        return 0;
    }
    login();
    // EAPO 同式：Logout 配对（endSoftware 先 Logout 再 Unregister）。
    // 漏 Logout 会在托盘攒 R（每次运行 +1，经 6 次运行复现 R 全亮）。
    // 注意 FreeLibrary 只能一次：leave 幂等（remoteFreed 守卫），否则二次释放崩溃。
    bool remoteFreed = false;
    auto leave = [&](bool andUnreg) {
        logout();
        if (andUnreg) unreg();
        if (!remoteFreed) {
            remoteFreed = true;
            FreeLibrary(remote);
        }
    };
    char name[64] = {0};
    memcpy(name, "AuraDSP", 7);
    PumpCtx ctx;
    // 注册：1 = 被占（EAPO 同式直接让路）；其它非零 = 瞬时失败有界重试
    //（EAPO 30×100ms；泵是短命进程，10×100ms 足够，超时仍优雅退出）。
    long rc = -99;
    for (int tries = 0; tries < 10; ++tries) {
        rc = reg(kModeOut, OnVbCallback, &ctx, name);
        if (rc == 0 || rc == 1) break;
        Sleep(100);
    }
    p.startRc = (int)rc;
    if (rc == 1) {
        // OUT 槽被别的应用占住：优雅让路（smoke 记 note，不判 FAIL）。
        p.note = std::string("out-slot-busy-by:") + name;
        leave(true);
        return 0;
    }
    if (rc != 0) {
        char nb[64];
        snprintf(nb, sizeof(nb), "register-failed rc=%ld", rc);
        p.note = nb;
        leave(true);
        return 0;
    }
    // 引擎桥（主线程：加载 + 按版型预建 handle + 预分配）。
    // 版型决定最大组数（Potato 8 / Banana 5 / Standard 2；未知按 8 上限，
    // 运行时再按实际 min(nbi,nbo)/8 钳）。RT 内禁分配，故全在 Start 前建好。
    int wantGroups = PumpCtx::kMaxGroups;
    {
        const AuraVmDetect det = AuraVmDetectRun();
        if (det.edition == 1)
            wantGroups = 2;
        else if (det.edition == 2)
            wantGroups = 5;
        p.edition = det.edition;
    }
    std::wstring used;
    HMODULE eng = TryLoadEngine(p.engineDll, used);
    if (!used.empty()) {
        // UTF-16 → UTF-8 仅用于报告（ASCII 路径为主）。
        char narrow[MAX_PATH * 2] = {0};
        WideCharToMultiByte(CP_UTF8, 0, used.c_str(), -1, narrow, (int)sizeof(narrow), nullptr, nullptr);
        p.enginePath = narrow;
    }
    FnEngCreate create = nullptr;
    FnEngProcess process = nullptr;
    FnEngDestroy destroy = nullptr;
    FnEngSetParam setParam = nullptr;
    // 引擎重建（初始建 + CHANGE 重建共用；仅主线程调用，RT 内禁分配）。
    // sr 用当前 ctx.sr（CHANGE 时已更新）；create 与 sr 关系不大（vendor 内部
    // 按块自适应），但重建时用新 sr 更诚实。
    auto rebuildEngines = [&](int groups) {
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            if (ctx.eng[g] && ctx.destroy) ctx.destroy(ctx.eng[g]);
            ctx.eng[g] = nullptr;
        }
        ctx.nEng = 0;
        const float sr = ctx.sr > 0 ? (float)ctx.sr : 48000.0f;
        for (int g = 0; g < groups && create; ++g) {
            ctx.eng[g] = create(sr, 2048);
            if (ctx.eng[g]) ++ctx.nEng;
        }
        // 参数下发面：CLI --seti/--setf 全 handle 应用（失败只计数不中断）。
        if (setParam) {
            for (const auto& pm : p.params) {
                bool okAll = ctx.nEng > 0;
                for (int g = 0; g < ctx.nEng; ++g) {
                    int prc;
                    if (pm.isFloat)
                        prc = setParam(ctx.eng[g], pm.id.c_str(), &pm.f, 4);
                    else
                        prc = setParam(ctx.eng[g], pm.id.c_str(), &pm.i, 4);
                    if (prc != 0) {
                        okAll = false;
                        break;
                    }
                }
                if (okAll)
                    ++p.paramsApplied;
                else
                    ++p.paramsFailed;
            }
        } else if (!p.params.empty()) {
            p.paramsFailed = (int)p.params.size();
        }
        if (ctx.nEng == 0 || !ctx.scratchIn || !ctx.scratchOut) {
            for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
                if (ctx.eng[g] && ctx.destroy) ctx.destroy(ctx.eng[g]);
                ctx.eng[g] = nullptr;
            }
            ctx.nEng = 0;
        }
    };
    if (eng) {
        create = (FnEngCreate)GetProcAddress(eng, "auradsp_create");
        process = (FnEngProcess)GetProcAddress(eng, "auradsp_process");
        destroy = (FnEngDestroy)GetProcAddress(eng, "auradsp_destroy");
        setParam = (FnEngSetParam)GetProcAddress(eng, "auradsp_set_param");
        if (create && process && destroy) {
            ctx.process = process;
            ctx.destroy = destroy;
            ctx.scratchIn = (float*)malloc(sizeof(float) * 2 * kMaxNbs);
            ctx.scratchOut = (float*)malloc(sizeof(float) * 2 * kMaxNbs);
            rebuildEngines(wantGroups);
            if (!ctx.scratchIn || !ctx.scratchOut) {
                ctx.nEng = 0;
                ctx.process = nullptr;
            }
        }
        if (!ctx.process) {
            FreeLibrary(eng);
            eng = nullptr;
        }
    }
    if (start() != 0) {
        p.note = "start-failed";
        leave(true);
        return 0;
    }
    // 等首个 BUFFER 再计时（冷启动引擎 device negotiate 要几秒；至多等 10s）。
    // 等不到也继续跑完（frames=0 + note，smoke 按阈值判）。
    int waited = 0;
    while (!ctx.gotFirst && waited < 10000) {
        Sleep(50);
        waited += 50;
    }
    if (!ctx.gotFirst) p.note = "no-buffers-timeout";
    // 分段轮询：CHANGE 到达（采样率/缓冲变化）→ stop → 重建引擎 → start。
    // 总时长仍受 p.seconds 约束；重建不额外延长运行期。
    int elapsed = 0;
    const int totalMs = (p.seconds > 0 ? p.seconds : 5) * 1000;
    int lastFake = 0;
    while (elapsed < totalMs) {
        // 合成 CHANGE（测试用）：按周期置位，驱动重建路径。
        if (p.fakeChangeEveryMs > 0 && elapsed - lastFake >= p.fakeChangeEveryMs) {
            InterlockedExchange(&ctx.pendingChange, 1);
            lastFake = elapsed;
        }
        if (InterlockedExchange(&ctx.pendingChange, 0) != 0) {
            ++ctx.changes;
            printf("[CHANGE] sr=%ld nbs=%ld rebuild\n", ctx.sr, ctx.nbs);
            stop();
            rebuildEngines(ctx.groups > 0 ? ctx.groups : PumpCtx::kMaxGroups);
            if (start() != 0) break;
            ctx.gotFirst = 0;
        }
        Sleep(200);
        elapsed += 200;
    }
    stop();
    leave(true);  // 单次配对：logout + unreg（二次 logout 会 AV，勿加第二次）
    p.ran = true;
    p.frames = ctx.frames;
    p.maxDiff = ctx.maxDiff;
    p.bypassEntered = ctx.bypassEntered;
    p.sampleRate = (int)ctx.sr;
    p.nbs = (int)ctx.nbs;
    p.changes = ctx.changes;
    p.groups = ctx.groups;
    p.handles = ctx.nEng;
    p.warmupMs = waited;
    p.peakIn = ctx.peakIn;
    LARGE_INTEGER qpf;
    if (QueryPerformanceFrequency(&qpf) && qpf.QuadPart > 0)
        p.maxCbUs = (double)ctx.maxCbTicks * 1000000.0 / (double)qpf.QuadPart;
    if (ctx.scratchIn) free(ctx.scratchIn);
    if (ctx.scratchOut) free(ctx.scratchOut);
    if (eng) {
        if (ctx.destroy) {
            for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
                if (ctx.eng[g]) ctx.destroy(ctx.eng[g]);
            }
        }
        FreeLibrary(eng);
    }
    return 0;
}
