// VmAudioCallback.cpp — 见头文件 v1 范围与 RT 铁律。
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
    void* eng = nullptr;
    float* scratchIn = nullptr;   // 主线程预分配 2*kMaxNbs
    float* scratchOut = nullptr;
    uint64_t frames = 0;
    uint64_t silentFrames = 0;
    long sr = 0;
    long nbs = 0;
    double maxDiff = 0.0;
    bool bypassEntered = false;
};

long __stdcall OnVbCallback(void* lpUser, long cmd, void* lpData, long /*nnn*/) {
    auto* c = (PumpCtx*)lpUser;
    if (cmd == kCbStarting) {
        auto* info = (VbAudioInfo*)lpData;
        c->sr = info->samplerate;
        c->nbs = info->nbSamplePerFrame;
        c->nbs = info->nbSamplePerFrame;
        c->frames = 0;
        c->silentFrames = 0;
        c->maxDiff = 0.0;
        c->bypassEntered = false;
        return 0;
    }
    if (cmd == kCbEnding || cmd == kCbChange) return 0;
    if (cmd != kCbBufferOut) return 0;
    auto* ab = (VbAudioBuffer*)lpData;
    if (ab->nbo < 2 || ab->nbs <= 0 || ab->nbs > kMaxNbs) return 0;
    const long n = ab->nbs;
    // 其余通道永远透传（v1 只动 A1 主对）。
    for (long ch = 2; ch < ab->nbo && ch < 128; ++ch) {
        if (ab->w[ch] && ab->r[ch] && ab->w[ch] != ab->r[ch])
            memcpy(ab->w[ch], ab->r[ch], (size_t)n * sizeof(float));
    }
    // v1：只动 A1 主对（ch0/1），其余透传（下面 memcpy）。
    const float* inL = ab->r[0];
    const float* inR = ab->r[1];
    float* outL = ab->w[0];
    float* outR = ab->w[1];
    if (!inL || !inR || !outL || !outR) return 0;
    // 无引擎桥（DLL 缺失/符号不全）：主对也透传，绝不吞声。
    if (c->process == nullptr || c->eng == nullptr) {
        if (outL != inL) memcpy(outL, inL, (size_t)n * sizeof(float));
        if (outR != inR) memcpy(outR, inR, (size_t)n * sizeof(float));
        c->frames += (uint64_t)n;
        return 0;
    }
    // 静音检测（doc §2.2：全 |x|<1e-5 持续 2s → 指针透传，CPU 归零）。
    float peak = 0.0f;
    for (long i = 0; i < n; ++i) {
        const float a = inL[i] < 0 ? -inL[i] : inL[i];
        const float b = inR[i] < 0 ? -inR[i] : inR[i];
        if (a > peak) peak = a;
        if (b > peak) peak = b;
    }
    if (peak < 1e-5f)
        c->silentFrames += (uint64_t)n;
    else
        c->silentFrames = 0;
    const bool bypass = c->sr > 0 && c->silentFrames > (uint64_t)c->sr * 2;
    if (bypass) {
        c->bypassEntered = true;
        memcpy(outL, inL, (size_t)n * sizeof(float));
        memcpy(outR, inR, (size_t)n * sizeof(float));
    } else {
        for (long i = 0; i < n; ++i) {
            c->scratchIn[i * 2] = inL[i];
            c->scratchIn[i * 2 + 1] = inR[i];
        }
        c->process(c->eng, c->scratchIn, c->scratchOut, (int)n);
        for (long i = 0; i < n; ++i) {
            const float oL = c->scratchOut[i * 2], oR = c->scratchOut[i * 2 + 1];
            outL[i] = oL;
            outR[i] = oR;
            const double dL = (double)oL - (double)inL[i];
            const double dR = (double)oR - (double)inR[i];
            const double d = dL < 0 ? -dL : (dR < 0 ? -dR : (dL > dR ? dL : dR));
            if (d > c->maxDiff) c->maxDiff = d;
        }
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
    // windows-drivers/out/Release → core/desktop/windows/out/Release
    cands.push_back(exe + L"\\..\\..\\windows\\out\\Release\\auradsp_engine.dll");
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
    // 引擎桥（主线程：加载 + 建 handle + 预分配）。
    std::wstring used;
    HMODULE eng = TryLoadEngine(p.engineDll, used);
    if (eng) {
        auto create = (FnEngCreate)GetProcAddress(eng, "auradsp_create");
        auto process = (FnEngProcess)GetProcAddress(eng, "auradsp_process");
        auto destroy = (FnEngDestroy)GetProcAddress(eng, "auradsp_destroy");
        if (create && process && destroy) {
            // sr 未知（STARTING 才到）：先按 48k 建，STARTING 后若不一致则重建。
            // v1 简化：STARTING 到来前不处理（ctx.process 为空即透传守卫实际在回调里
            // 表现为直接返回——此处先建默认，CHANGE 时暂不重建（后续 slice）。
            ctx.process = process;
            ctx.eng = create(48000.0f, 2048);
            ctx.scratchIn = (float*)malloc(sizeof(float) * 2 * kMaxNbs);
            ctx.scratchOut = (float*)malloc(sizeof(float) * 2 * kMaxNbs);
            if (!ctx.eng || !ctx.scratchIn || !ctx.scratchOut) {
                if (ctx.eng) destroy(ctx.eng);
                ctx.eng = nullptr;
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
    if (ctx.scratchIn) free(ctx.scratchIn);
    if (ctx.scratchOut) free(ctx.scratchOut);
    if (eng) {
        auto destroy = (FnEngDestroy)GetProcAddress(eng, "auradsp_destroy");
        if (destroy && ctx.eng) destroy(ctx.eng);
        FreeLibrary(eng);
    }
    FreeLibrary(remote);
    return 0;
}
