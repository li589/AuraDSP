// VmAudioCallback.cpp — 见头文件 v1 范围与 RT 铁律。
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
    uint64_t idleSamples[kMaxGroups] = {};  // 组独立（EAPO 同式）
    bool idle[kMaxGroups] = {};
    long sr = 0;
    long nbs = 0;
    long changes = 0;             // CHANGE 到达计数（v1 只观测，重启面后续 slice）
    int groups = 0;               // 本轮实际组数
    double maxDiff = 0.0;
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
        ++c->changes;  // v1 只计数不断链（重建面后续 slice；EAPO 用 PostThreadMessage 重启）
        return 0;
    }
    if (cmd != kCbBufferOut) return 0;
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
    if (!reg || !start || !stop || !unreg || !login) {
        FreeLibrary(remote);
        p.note = "remote-api-missing";
        return 0;
    }
    login();
    char name[64] = {0};
    memcpy(name, "AuraDSP", 7);
    PumpCtx ctx;
    const long rc = reg(kModeOut, OnVbCallback, &ctx, name);
    p.startRc = (int)rc;
    if (rc == 1) {
        // OUT 槽被别的应用占住：优雅让路（smoke 记 note，不判 FAIL）。
        p.note = std::string("out-slot-busy-by:") + name;
        unreg();
        FreeLibrary(remote);
        return 0;
    }
    if (rc != 0) {
        p.note = "register-failed";
        unreg();
        FreeLibrary(remote);
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
    if (eng) {
        auto create = (FnEngCreate)GetProcAddress(eng, "auradsp_create");
        auto process = (FnEngProcess)GetProcAddress(eng, "auradsp_process");
        auto destroy = (FnEngDestroy)GetProcAddress(eng, "auradsp_destroy");
        if (create && process && destroy) {
            // sr 未知（STARTING 才到）：先按 48k 建（与 sr 无关的纯内存 sizing；
            // 真实 sr 下 vendor 内部按块自适应，见 processFloatMultiplexd 注释）。
            ctx.process = process;
            ctx.destroy = destroy;
            ctx.scratchIn = (float*)malloc(sizeof(float) * 2 * kMaxNbs);
            ctx.scratchOut = (float*)malloc(sizeof(float) * 2 * kMaxNbs);
            for (int g = 0; g < wantGroups && ctx.scratchIn && ctx.scratchOut; ++g) {
                ctx.eng[g] = create(48000.0f, 2048);
                if (ctx.eng[g]) ++ctx.nEng;
            }
            if (ctx.nEng == 0 || !ctx.scratchIn || !ctx.scratchOut) {
                for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
                    if (ctx.eng[g]) destroy(ctx.eng[g]);
                    ctx.eng[g] = nullptr;
                }
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
        unreg();
        FreeLibrary(remote);
        return 0;
    }
    Sleep((DWORD)(p.seconds > 0 ? p.seconds : 5) * 1000);
    stop();
    unreg();
    p.ran = true;
    p.frames = ctx.frames;
    p.maxDiff = ctx.maxDiff;
    p.bypassEntered = ctx.bypassEntered;
    p.sampleRate = (int)ctx.sr;
    p.nbs = (int)ctx.nbs;
    p.changes = ctx.changes;
    p.groups = ctx.groups;
    p.handles = ctx.nEng;
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
    FreeLibrary(remote);
    return 0;
}
