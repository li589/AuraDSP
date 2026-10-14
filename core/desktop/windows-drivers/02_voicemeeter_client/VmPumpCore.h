// VmPumpCore.h — Voicemeeter 泵共享核心（05 桥用；02 泵保持原文件不动）。
//
// 与 VmAudioCallback.cpp 同源（PumpCtx/回调/引擎桥逻辑逐行对齐），
// 02 侧已绿故冻结，演进只在此头做；若改回调语义，两处必须同步改，
// 以 smoke_vm_pump.py 为准绳。相对 02 副本只增测试注入面（testKind 等
// 字段 + FillTestSignal + BUFFER_OUT 主对分支），供 bridge 的
// “测试源启动即静音主输入”语义。RT 铁律不变。
#pragma once

#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// ---- VBVMR 回调 ABI（官方 VoicemeeterRemote.h 誓约，动态加载不链 SDK） ----
namespace vmcore {

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
using FnEngVizRead = int(__cdecl*)(void*, void*, int);

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
    // 每组主对峰值（回调级衰减，半衰期约 1s，保证 viz 跟随“当前”有声组；
    // 旧 max-hold 会被僵尸热组霸榜：该组静默→idle→停产 viz 帧，viz 永久空）。
    double peakGrp[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    bool bypassEntered = false;
    // 用户旁路（bridge 用；pump 不碰，恒 0 即原行为）：置位时跳过 process，
    // 输入直通输出（测试注入仍生效：先填 scratchIn 再直通，与进程内 bypass?src:eng 同义）。
    volatile LONG userBypass = 0;
    // ---- 测试注入面（bridge 用；pump 不碰，全零即关闭） ----
    volatile LONG testKind = 0;  // 0=关 1=正弦440 2=粉噪 3=文件（RT 读，主线程 Interlocked 写）
    double testPhase = 0.0;      // 正弦相位（RT 独占）
    uint32_t testRng = 0x12345678u;  // xorshift 白噪声源（RT 独占，禁 rand()）
    double testPink[7] = {};     // 粉噪滤波器状态（RT 独占，Paul Kellet 系数对标 Dart）
    const float* testFile = nullptr;  // 主线程 test_start 时拷贝，stop 时先清 kind 再 Sleep 后释放
    uint64_t testFrames = 0;     // 源帧数（立体声交织帧）
    int testRate = 0;
    double testPos = 0.0;  // 文件播放头（源帧单位，RT 独占，循环）
};

inline bool PairIsSilent(const float* a, const float* b, long n) {
    // EAPO 同式：精确零才算静默（-100dBFS 的弱音也算有声，不误杀；见借鉴注）。
    for (long i = 0; i < n; ++i) {
        if (a[i] != 0.0f || b[i] != 0.0f) return false;
    }
    return true;
}

// 测试信号填充（RT-safe：纯数学，无分配无锁；与 Dart FileSource/ToneSource/PinkSource 同构）。
// 用户语义：测试源启动即静音主通道输入，本函数输出替代 VB 输入进同一条 DSP 链。
inline void FillTestSignal(PumpCtx* c, float* dst, long n) {
    const double sr = c->sr > 0 ? (double)c->sr : 48000.0;
    const long kind = c->testKind;  // 单次读，快照
    if (kind == 1) {
        const double d = 2.0 * 3.14159265358979 * 440.0 / sr;
        for (long i = 0; i < n; ++i) {
            const float s = (float)(0.3 * sin(c->testPhase));
            c->testPhase += d;
            if (c->testPhase > 2.0 * 3.14159265358979)
                c->testPhase -= 2.0 * 3.14159265358979;
            dst[i * 2] = s;
            dst[i * 2 + 1] = s;
        }
    } else if (kind == 2) {
        double b0 = c->testPink[0], b1 = c->testPink[1], b2 = c->testPink[2];
        double b3 = c->testPink[3], b4 = c->testPink[4], b5 = c->testPink[5],
               b6 = c->testPink[6];
        for (long i = 0; i < n; ++i) {
            uint32_t x = c->testRng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            if (x == 0) x = 0x12345678u;
            c->testRng = x;
            const double w = ((double)(int32_t)x / 2147483648.0) * 2.0 - 1.0;
            b0 = 0.99886 * b0 + w * 0.0555179;
            b1 = 0.99332 * b1 + w * 0.0750759;
            b2 = 0.96900 * b2 + w * 0.1538520;
            b3 = 0.86650 * b3 + w * 0.3104856;
            b4 = 0.55000 * b4 + w * 0.5329522;
            b5 = -0.7616 * b5 - w * 0.0168980;
            const float s =
                (float)((b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.05);
            b6 = w * 0.115926;
            dst[i * 2] = s;
            dst[i * 2 + 1] = s;
        }
        c->testPink[0] = b0;
        c->testPink[1] = b1;
        c->testPink[2] = b2;
        c->testPink[3] = b3;
        c->testPink[4] = b4;
        c->testPink[5] = b5;
        c->testPink[6] = b6;
    } else if (kind == 3 && c->testFile && c->testFrames > 0 && c->testRate > 0) {
        const double ratio = (double)c->testRate / sr;
        const uint64_t total = c->testFrames;
        for (long i = 0; i < n; ++i) {
            if (c->testPos >= (double)(total - 1)) c->testPos = 0.0;
            const uint64_t i0 = (uint64_t)c->testPos;
            const double frac = c->testPos - (double)i0;
            uint64_t i1 = i0 + 1;
            if (i1 >= total) i1 = total - 1;
            const float aL = c->testFile[i0 * 2], aR = c->testFile[i0 * 2 + 1];
            const float bL = c->testFile[i1 * 2], bR = c->testFile[i1 * 2 + 1];
            dst[i * 2] = (float)(aL * (1.0 - frac) + bL * frac);
            dst[i * 2 + 1] = (float)(aR * (1.0 - frac) + bR * frac);
            c->testPos += ratio;
        }
    } else {
        for (long i = 0; i < n; ++i) {
            dst[i * 2] = 0.0f;
            dst[i * 2 + 1] = 0.0f;
        }
    }
}

inline long OnVbCallback(void* lpUser, long cmd, void* lpData, long /*nnn*/) {
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
        double grpPeak = 0.0;
        for (long i = 0; i < n; ++i) {
            const double a = inL[i] < 0 ? -(double)inL[i] : (double)inL[i];
            const double b = inR[i] < 0 ? -(double)inR[i] : (double)inR[i];
            const double m = a > b ? a : b;
            if (m > c->peakIn) c->peakIn = m;
            if (m > grpPeak) grpPeak = m;
        }
        if (g < 8) {
            // 上升沿直接跟，下降沿每回调衰减（48k/s 下 0.99995 ≈ 半衰期约 1s）。
            if (grpPeak > c->peakGrp[g])
                c->peakGrp[g] = grpPeak;
            else
                c->peakGrp[g] *= 0.99995;
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
            if (c->testKind != 0) {
                // 测试注入：静音主通道 VB 输入，测试信号进同一条 DSP 链。
                FillTestSignal(c, c->scratchIn, n);
            } else {
                for (long i = 0; i < n; ++i) {
                    c->scratchIn[i * 2] = inL[i];
                    c->scratchIn[i * 2 + 1] = inR[i];
                }
            }
            bool outSilent = true;
            if (c->userBypass) {
                // 用户旁路：跳过 process，输入直通（测试信号同样直通）。
                for (long i = 0; i < n; ++i) {
                    outL[i] = c->scratchIn[i * 2];
                    outR[i] = c->scratchIn[i * 2 + 1];
                }
                // 旁路输出==输入：测试注入恒视为有声，否则看输入。
                outSilent = (c->testKind != 0) ? false : PairIsSilent(inL, inR, n);
            } else {
            c->process(c->eng[g], c->scratchIn, c->scratchOut, (int)n);
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
            }  // end else(!userBypass)：正常 DSP 处理
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

inline std::wstring ToWide(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring w((size_t)n - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
    return w;
}

// exe 所在目录。
inline std::wstring ExeDir() {
    wchar_t p[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, p, MAX_PATH);
    std::wstring s(p);
    const size_t k = s.find_last_of(L"\\/");
    return (k == std::wstring::npos) ? L"." : s.substr(0, k);
}

inline HMODULE TryLoadEngine(const std::string& hint, std::wstring& used) {
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

}  // namespace vmcore
