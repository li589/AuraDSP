// vm_parallel_test.cpp — Z17 组间并行处理验收（不依赖 Voicemeeter 在线）。
//
// 原理：两个同初态 Rig（ctxSer/ctxPar）喂同一段确定性输入块序列，分别走
// 串行/并行路径（唯一实现 ProcessGroupVm，两条调用路径），逐块 memcmp
// 输出缓冲 + 遥测终值精确相等；另测墙钟：8 组 × 250µs 假插件成本下并行
// 应显著小于串行。语义断言直验期望值（防"两条路一起错"——串行径是重构
// 后的新代码，02 冻结副本的 smoke_vm_pump 覆盖不到它）。
//
// 场景：
//   full8      全 8 组、无测试信号（墙钟 + 变换语义 + 组内/组外透传）
//   full8_tone 全 8 组 + 测试信号（RT 预填径；独立重放正弦序列验逐位一致）
//   ng2        nbi=nbo=16（2 组并行 + 组外透传）
//   mask_half  busMask=0x0F（半数组 mask 直通、半数进 DSP）
//   null_grp   第 3 组 VB 未给 buffer（grpLive 死灯 + 早退，仍占认领位）
//   straggler  B2：第 7 组（最高位，认领序最后）插件卡死——worker 进入
//               引擎后不返回。验证 fan-in 2ms 截止（回调墙钟有界，不被
//               钉死数秒）、超时后并行不停用（parallelOn 不被 RT 改动）、
//               卡死组不被重认领（无引擎重入）且输出保持不动、其余组照常
//               处理与串行参照逐位一致、worker 返回后该组恢复且逐位一致。
//               单核（workers==0）自动跳过（只报 note）。
//   geometry    per-handle pending/active ABI：2→4→6→8、部分组错宽、
//               失败回滚、重建/懒建代号保留，以及 straggler 几何快照保留。
//
// 输出：末行单行 JSON（smoke_vm_parallel.py 消费）。退出码 0 = 全过。
#include <windows.h>
#include <intrin.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace vmcore { struct PumpCtx; }

namespace {

// Test-only interleaving seam: pause a worker immediately after it successfully
// claims a group, before it reads expected geometry. This makes the former
// post-claim read of mutable curExpectedGeometry deterministic without adding a
// hook to the production pump.
struct ClaimHook {
    vmcore::PumpCtx* ctx = nullptr;
    LONG bit = 0;
    HANDLE claimed = nullptr;
    HANDLE release = nullptr;
    std::atomic<bool> used{false};
};

std::atomic<ClaimHook*> g_claimHook{nullptr};
std::atomic<DWORD> g_callbackThreadId{0};

inline LONGLONG HookedCompareExchange64(volatile LONGLONG* dst, LONGLONG value,
                                        LONGLONG comparand);

}  // namespace

#undef InterlockedCompareExchange64
#define InterlockedCompareExchange64 HookedCompareExchange64

#include "../../02_voicemeeter_client/VmPumpCore.h"

using namespace vmcore;

namespace {

inline LONGLONG HookedCompareExchange64(volatile LONGLONG* dst, LONGLONG value,
                                        LONGLONG comparand) {
    const LONGLONG result = _InterlockedCompareExchange64(dst, value, comparand);
    ClaimHook* hook = g_claimHook.load(std::memory_order_acquire);
    if (hook && !hook->used.load(std::memory_order_acquire) && result == comparand
        && dst == &hook->ctx->workClaimPacked
        && GetCurrentThreadId() != g_callbackThreadId.load(std::memory_order_acquire)
        && (value >> 32) == (comparand >> 32) && (comparand >> 32) != 0
        && (comparand & ~value & hook->bit) != 0) {
        hook->used.store(true, std::memory_order_release);
        SetEvent(hook->claimed);
        WaitForSingleObject(hook->release, 5000);
    }
    return result;
}

constexpr int kCh = 64;                 // 8 组 × 8ch（VbAudioBuffer 上限 128）
constexpr double kFakeCostUs = 250.0;   // 假插件人工成本（QPC 自旋校准）
constexpr double kTwoPi = 6.283185307179586;
// B2 straggler 场景参数：卡死引擎自愈上界（测试不依赖它——释放由主线程
// 保证；它只是"插件最终自己回来了"的兜底，防反向验证时无限挂死）。
constexpr DWORD kHangSelfHealMs = 5000;

double g_qpfInvUs = 0.0;

// B2：卡死注入面（仅 straggler 场景使用；全零即关闭）。
HANDLE g_hangGate = nullptr;            // 未 set = 卡死；set = 放行
std::atomic<long> g_inEngine{0};        // 卡死引擎内线程数（重入检测）
std::atomic<long> g_reentered{0};       // 1 = 发生过并发重入

struct FakeEng {
    float gain;
    double costUs = kFakeCostUs;        // 单次 process 人工成本（QPC 自旋）
    HANDLE hangGate = nullptr;          // 非空 = 进入引擎先等事件（模拟插件卡死）
    std::atomic<long>* inEngine = nullptr;
    std::atomic<long>* reentered = nullptr;
    // 每个 handle 独立 pending/active 代际；字段先写、generation release 发布，
    // 与真实引擎的完整快照契约一致。
    std::atomic<uint64_t> nextGeneration{2};
    std::atomic<uint64_t> pendingGeneration{1};
    std::atomic<uint64_t> activeGeneration{1};
    std::atomic<int32_t> pendingChannels{2};
    std::atomic<int32_t> activeChannels{2};
    std::atomic<int32_t> pendingMode{0};
    std::atomic<int32_t> activeMode{0};
    std::atomic<bool> failNextRequest{false};
    std::atomic<int> requestCalls{0};
    std::atomic<int> processCalls{0};
    std::atomic<uint64_t> lastExpectedGeneration{0};
    std::atomic<int32_t> lastExpectedChannels{0};
    std::atomic<int32_t> lastExpectedMode{-1};
};

auradsp_geometry FakeLoadGeometry(const std::atomic<uint64_t>& generation,
                                  const std::atomic<int32_t>& channels,
                                  const std::atomic<int32_t>& mode) {
    auradsp_geometry result{};
    result.generation = generation.load(std::memory_order_acquire);
    result.channels = channels.load(std::memory_order_relaxed);
    result.mode = mode.load(std::memory_order_relaxed);
    return result;
}

int FakeRequestGeometry(void* eng, int32_t channels, int32_t mode,
                        uint64_t* generation) {
    if (!eng || !generation || (channels != 2 && channels != 4 && channels != 6
                               && channels != 8) || (mode != 0 && mode != 1))
        return AURADSP_E_PARAM;
    auto* fe = static_cast<FakeEng*>(eng);
    if (fe->failNextRequest.exchange(false, std::memory_order_acq_rel))
        return AURADSP_E_STATE;
    const uint64_t next = fe->nextGeneration.fetch_add(1, std::memory_order_relaxed);
    fe->pendingChannels.store(channels, std::memory_order_relaxed);
    fe->pendingMode.store(mode, std::memory_order_relaxed);
    fe->pendingGeneration.store(next, std::memory_order_release);
    *generation = next;
    fe->requestCalls.fetch_add(1, std::memory_order_relaxed);
    return AURADSP_OK;
}

int FakeGetActiveGeometry(void* eng, auradsp_geometry* out) {
    if (!eng || !out) return AURADSP_E_PARAM;
    auto* fe = static_cast<FakeEng*>(eng);
    *out = FakeLoadGeometry(fe->activeGeneration, fe->activeChannels, fe->activeMode);
    return AURADSP_OK;
}

bool FakeGeometryMatches(const auradsp_geometry& a, const auradsp_geometry& b) {
    return a.generation == b.generation && a.channels == b.channels
           && a.mode == b.mode;
}

// 假插件 process：确定性变换（与线程/时序无关）+ QPC 校准人工成本。
// B2：hangGate 非空时，在写输出前先等事件——卡死的插件来不及写输出，
// 该组输出保持调用方预置的脏哨兵（冻结的可观测判据）。
void FakeProcessImpl(FakeEng* fe, const float* in, float* out, int frames,
                     int channels) {
    const float k = fe->gain;
    const int n2 = frames * channels;
    if (fe->hangGate) {
        // 重入检测：进入即计数；已有他者在引擎内 = 重入被占引擎（B2 须杜绝）
        if (fe->inEngine->fetch_add(1) != 0) fe->reentered->store(1);
        WaitForSingleObject(fe->hangGate, kHangSelfHealMs);
    }
    for (int i = 0; i < n2; ++i) out[i] = in[i] * k + 1e-4f;
    LARGE_INTEGER t0;
    QueryPerformanceCounter(&t0);
    for (;;) {
        LARGE_INTEGER t1;
        QueryPerformanceCounter(&t1);
        if ((double)(t1.QuadPart - t0.QuadPart) * g_qpfInvUs >= fe->costUs)
            break;
    }
    if (fe->hangGate) fe->inEngine->fetch_sub(1);
}

void FakeProcess(void* eng, const float* in, float* out, int frames) {
    auto* fe = static_cast<FakeEng*>(eng);
    FakeProcessImpl(fe, in, out, frames,
                    fe->activeChannels.load(std::memory_order_acquire));
}

int FakeProcessGeometry(void* eng, const float* in, float* out, int frames,
                        const auradsp_geometry* expected) {
    if (!eng || !expected) return AURADSP_E_PARAM;
    auto* fe = static_cast<FakeEng*>(eng);
    const auradsp_geometry active = FakeLoadGeometry(
        fe->activeGeneration, fe->activeChannels, fe->activeMode);
    const auradsp_geometry pending = FakeLoadGeometry(
        fe->pendingGeneration, fe->pendingChannels, fe->pendingMode);
    const bool activeMatch = FakeGeometryMatches(*expected, active);
    if (!activeMatch && !FakeGeometryMatches(*expected, pending))
        return AURADSP_E_STATE;
    const auradsp_geometry& target = activeMatch ? active : pending;
    fe->lastExpectedGeneration.store(expected->generation, std::memory_order_release);
    fe->lastExpectedChannels.store(expected->channels, std::memory_order_relaxed);
    fe->lastExpectedMode.store(expected->mode, std::memory_order_relaxed);
    fe->processCalls.fetch_add(1, std::memory_order_acq_rel);
    fe->activeChannels.store(target.channels, std::memory_order_relaxed);
    fe->activeMode.store(target.mode, std::memory_order_relaxed);
    fe->activeGeneration.store(target.generation, std::memory_order_release);
    FakeProcessImpl(fe, in, out, frames, expected->channels);
    return AURADSP_OK;
}

// 确定性输入（块间变化防冻结检测干扰；串/并行两块序列逐位相同）。
float InVal(long i, int g, int b) {
    const int m = (int)((i * 7 + b * 13 + g * 101) % 997);
    return 0.002f * (float)m - 0.001f;
}

struct Rig {
    PumpCtx ctx;
    VbAudioBuffer ab;
    std::vector<float> rStore;
    std::vector<float> wStore;
    FakeEng* eng[PumpCtx::kMaxGroups] = {};

    void Init() {
        LARGE_INTEGER qpf;
        QueryPerformanceFrequency(&qpf);
        g_qpfInvUs = 1e6 / (double)qpf.QuadPart;
        memset(&ctx, 0, sizeof(ctx));
        ctx.process = FakeProcess;  // haveEng/readiness marker; geometry path is authoritative.
        ctx.processGeometry = FakeProcessGeometry;
        ctx.requestGeometry = FakeRequestGeometry;
        ctx.getActiveGeometry = FakeGetActiveGeometry;
        ctx.idleSeconds = 3;
        ctx.qpfInvUs = g_qpfInvUs;
        ctx.busMask = 0xFF;
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            eng[g] = new FakeEng{1.0f + 0.01f * static_cast<float>(g)};
            ctx.eng[g] = eng[g];
            ctx.requestedGeneration[g] = 1;
            ctx.requestedChannels[g] = 2;
            ctx.requestedMode[g] = 0;
        }
        ctx.nEng = PumpCtx::kMaxGroups;
        rStore.assign(static_cast<size_t>(kCh) * 128, 0.0f);
        wStore.assign(static_cast<size_t>(kCh) * 128, 0.0f);
        memset(&ab, 0, sizeof(ab));
        ab.sr = 48000;
        ab.nbs = 128;
        ab.nbi = kCh;
        ab.nbo = kCh;
        for (int ch = 0; ch < kCh; ++ch) {
            ab.r[ch] = rStore.data() + static_cast<size_t>(ch) * 128;
            ab.w[ch] = wStore.data() + static_cast<size_t>(ch) * 128;
        }
        VbAudioInfo info{48000, 128};
        OnVbCallback(&ctx, kCbStarting, &info, 0);
    }

    void Destroy() {
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) delete eng[g];
    }

    bool RequestGroup(int g, int32_t channels, int32_t mode) {
        if (g < 0 || g >= PumpCtx::kMaxGroups || !eng[g]) return false;
        return VmRequestGroupGeometry(&ctx, g, eng[g], channels, mode);
    }

    bool RequestAll(int32_t channels, int32_t mode) {
        return VmApplyWorkGeometry(&ctx, channels, mode) == VmLiveEngineCount(&ctx);
    }

    // 模拟生产“先请求几何、后发布句柄”的重建/懒建顺序。新 handle 的
    // active 从 generation 1 开始，requested 必须保留 ABI 返回的真实代号。
    bool ReplaceGroup(int g, int32_t channels, int32_t mode) {
        if (g < 0 || g >= PumpCtx::kMaxGroups) return false;
        auto* replacement = new FakeEng{1.0f + 0.01f * static_cast<float>(g)};
        if (!VmRequestGroupGeometry(&ctx, g, replacement, channels, mode)) {
            delete replacement;
            return false;
        }
        FakeEng* old = eng[g];
        ctx.eng[g] = replacement;
        eng[g] = replacement;
        delete old;
        return true;
    }

    // 请求后的首个块只激活 pending 并静音；第二个块才发布宿主步进。
    bool PrimeGeometry(int32_t channels, int32_t mode) {
        if (!RequestAll(channels, mode)) return false;
        FillInputs(0, PumpCtx::kMaxGroups, -1);
        OnVbCallback(&ctx, kCbBufferOut, &ab, 0);
        FillInputs(1, PumpCtx::kMaxGroups, -1);
        OnVbCallback(&ctx, kCbBufferOut, &ab, 0);
        return InterlockedCompareExchange(&ctx.workCh, 0, 0) == channels
               && InterlockedCompareExchange(&ctx.chanMode, 0, 0) == mode;
    }

    // 填第 b 块输入：输出预置脏哨兵（捕捉"没被写"）；nullGroup 的组不给 buffer。
    void FillInputs(int b, int ng, int nullGroup) {
        for (int ch = 0; ch < kCh; ++ch)
            for (int i = 0; i < 128; ++i) ab.w[ch][i] = -12345.0f;
        for (int g = 0; g < ng; ++g) {
            const int base = g * 8;
            if (g == nullGroup) {
                ab.r[base] = nullptr;
                ab.r[base + 1] = nullptr;
                continue;
            }
            for (int i = 0; i < 128; ++i) {
                ab.r[base][i] = InVal(i, g, b);
                ab.r[base + 1][i] = InVal(i + 31, g, b);
            }
            for (int ch = base + 2; ch < base + 8; ++ch)
                for (int i = 0; i < 128; ++i)
                    ab.r[ch][i] = 0.001f * static_cast<float>(ch * 1000 + i % 17);
        }
        for (int ch = ng * 8; ch < kCh; ++ch)
            for (int i = 0; i < 128; ++i)
                ab.r[ch][i] = 0.0005f * static_cast<float>(ch + i % 5);
    }
};

// 独立重放测试正弦序列（与 FillTestSignalN kind=1 逐位同构：先取 sin(phase)
// 再推进 phase，超 2π 回绕——double 运算顺序必须一致）。
std::vector<float> MakeTone(long count) {
    std::vector<float> v;
    v.reserve(static_cast<size_t>(count));
    double phase = 0.0;
    const double d = 2.0 * 3.14159265358979 * 440.0 / 48000.0;
    for (long k = 0; k < count; ++k) {
        v.push_back(static_cast<float>(0.3 * sin(phase)));
        phase += d;
        if (phase > kTwoPi) phase -= kTwoPi;
    }
    return v;
}

struct ScenResult {
    bool ok = true;
    bool bitExact = true;
    bool teleEq = true;
    int diffCh = -1;
    long diffIdx = -1;
    double serUs = 0.0;
    double parUs = 0.0;
    int workers = 0;
    std::string why;
};

// 跑一个场景：ser 串行 / par 并行，逐块位级比对 + 末块语义断言。
ScenResult RunScenario(const char* name, int blocks, int ng, int nullGroup,
                       long busMask, long testKind) {
    ScenResult r;
    Rig ser, par;
    ser.Init();
    par.Init();
    if (!VmParallelInit(&par.ctx)) r.workers = 0;
    r.workers = static_cast<int>(par.ctx.nWorkers);
    // ser 侧：池也建（scratch 分配器）但强制串行——验证 worker 在场不干扰
    VmParallelInit(&ser.ctx);
    InterlockedExchange(&ser.ctx.parallelOn, 0);
    InterlockedExchange(&par.ctx.parallelOn, 1);
    InterlockedExchange(&ser.ctx.busMask, busMask);
    InterlockedExchange(&par.ctx.busMask, busMask);
    // 声道口径钉离散（第四十七轮 S2）：本场景族验证串/并行等价、
    // 掩码、空组与测试信号语义，FL/FR 期望是纯进纯出；矩阵折叠
    // gather 会把高声道折入主对，不属本族口径（折叠系数由
    // smoke_r47_vb_channel_discipline 源码门 + 引擎侧用例覆盖）。
    // 与生产一致：先请求 pending，静音激活一块，再让后续块发布 workCh/chanMode。
    if (!ser.PrimeGeometry(2, 1) || !par.PrimeGeometry(2, 1)) {
        r.ok = false;
        r.why = "initial geometry request/activation failed";
        VmParallelShutdown(&par.ctx);
        VmParallelShutdown(&ser.ctx);
        ser.Destroy();
        par.Destroy();
        return r;
    }
    InterlockedExchange(&ser.ctx.testKind, testKind);
    InterlockedExchange(&par.ctx.testKind, testKind);
    ser.ab.nbi = ng * 8;
    par.ab.nbi = ng * 8;
    ser.ab.nbo = kCh;  // 输出满 64ch：ng<8 时组外透传（ch>=ng*8）真正被 exercising
    par.ab.nbo = kCh;

    std::vector<float> snap(static_cast<size_t>(kCh) * 128);
    LARGE_INTEGER t0, t1;
    double serTicks = 0.0, parTicks = 0.0;
    for (int b = 0; b < blocks; ++b) {
        ser.FillInputs(b, ng, nullGroup);
        par.FillInputs(b, ng, nullGroup);  // 确定性同值
        QueryPerformanceCounter(&t0);
        OnVbCallback(&ser.ctx, kCbBufferOut, &ser.ab, 0);
        QueryPerformanceCounter(&t1);
        serTicks += static_cast<double>(t1.QuadPart - t0.QuadPart);
        memcpy(snap.data(), ser.wStore.data(), snap.size() * sizeof(float));
        QueryPerformanceCounter(&t0);
        OnVbCallback(&par.ctx, kCbBufferOut, &par.ab, 0);
        QueryPerformanceCounter(&t1);
        parTicks += static_cast<double>(t1.QuadPart - t0.QuadPart);
        if (memcmp(snap.data(), par.wStore.data(),
                   snap.size() * sizeof(float)) != 0) {
            r.bitExact = false;
            for (size_t k = 0; k < snap.size(); ++k) {
                if (snap[k] != par.wStore[k]) {
                    r.diffCh = static_cast<int>(k / 128);
                    r.diffIdx = static_cast<long>(k % 128);
                    break;
                }
            }
            break;
        }
    }
    r.serUs = serTicks * g_qpfInvUs;
    r.parUs = parTicks * g_qpfInvUs;

    // 遥测终值精确相等（同算法同输入 → 同账本）
    r.teleEq =
        ser.ctx.peakIn == par.ctx.peakIn && ser.ctx.maxDiff == par.ctx.maxDiff &&
        ser.ctx.frames == par.ctx.frames &&
        ser.ctx.bypassEntered == par.ctx.bypassEntered &&
        memcmp(ser.ctx.peakGrp, par.ctx.peakGrp, sizeof(ser.ctx.peakGrp)) == 0 &&
        memcmp(ser.ctx.idle, par.ctx.idle, sizeof(ser.ctx.idle)) == 0 &&
        memcmp(ser.ctx.grpLive, par.ctx.grpLive, sizeof(ser.ctx.grpLive)) == 0 &&
        ser.ctx.groups == par.ctx.groups;

    // ---- 末块语义断言（期望值直验，独立于"串==并行"）----
    const int b = blocks - 1;
    const float* w = ser.wStore.data();
    const float* rin = ser.rStore.data();
    auto W = [&](int ch, int i) { return w[static_cast<size_t>(ch) * 128 + i]; };
    auto R = [&](int ch, int i) { return rin[static_cast<size_t>(ch) * 128 + i]; };
    const std::vector<float> tone =
        testKind ? MakeTone(static_cast<long>(blocks) * ng * 128 + 8 * 128)
                 : std::vector<float>();
    for (int g = 0; g < ng && r.ok; ++g) {
        const int base = g * 8;
        const float gain = 1.0f + 0.01f * static_cast<float>(g);
        if (g == nullGroup) {
            // 未给 buffer：输出必须原封不动（脏哨兵），灯灭
            for (int i = 0; i < 128; ++i) {
                if (W(base, i) != -12345.0f || W(base + 1, i) != -12345.0f) {
                    r.ok = false;
                    r.why = "null-group output written";
                    break;
                }
            }
            if (ser.ctx.grpLive[g]) {
                r.ok = false;
                r.why = "null-group grpLive should be false";
            }
            continue;
        }
        const bool masked = (busMask & (1L << g)) == 0;
        for (int i = 0; i < 128; ++i) {
            float expL, expR;
            if (masked) {
                expL = R(base, i);
                expR = R(base + 1, i);
            } else if (testKind) {
                const long idx = static_cast<long>(b) * ng * 128 + g * 128 + i;
                expL = tone[idx] * gain + 1e-4f;
                expR = expL;
            } else {
                expL = R(base, i) * gain + 1e-4f;
                expR = R(base + 1, i) * gain + 1e-4f;
            }
            if (W(base, i) != expL || W(base + 1, i) != expR) {
                r.ok = false;
                char buf[160];
                snprintf(buf, sizeof(buf),
                         "g%d ch0 i%d got %.9g exp %.9g (masked=%d tone=%ld)",
                         g, i, W(base, i), expL, masked ? 1 : 0,
                         testKind);
                r.why = buf;
                break;
            }
        }
        // 组内 2..7（非双耳）：掩码关的组整组直通（W==R）；进引擎
        // 的组在工作声道之外一律清零（第四十七轮 S2 通道纪律——
        // 旧「原样透传」断言随定罪废止：透传使声道数量/模式设置
        // 在 VB 下完全失效，宾机实证输出恒 7.1）。
        for (int ch = base + 2; ch < base + 8 && r.ok; ++ch)
            for (int i = 0; i < 128; ++i)
                if (W(ch, i) != (masked ? R(ch, i) : 0.0f)) {
                    r.ok = false;
                    r.why = masked ? "inner passthrough mismatch"
                                   : "inner slot not zeroed (r47 discipline)";
                    break;
                }
    }
    // 组外透传（仅 VM 实际给出的通道：ch < nbo）
    for (int ch = ng * 8; ch < kCh && r.ok; ++ch)
        for (int i = 0; i < 128; ++i)
            if (W(ch, i) != R(ch, i)) {
                r.ok = false;
                r.why = "outer passthrough mismatch";
                break;
            }
    if (r.ok && ser.ctx.peakIn <= 0.0) {
        r.ok = false;
        r.why = "peakIn should be positive";
    }

    VmParallelShutdown(&par.ctx);
    VmParallelShutdown(&ser.ctx);
    ser.Destroy();
    par.Destroy();
    (void)name;
    return r;
}

// B2：straggler 场景——卡死组固定为 g7（认领序最高位：RT 与 worker 都从
// 最低位抢，g7 必落在 worker 头上）。RT 自行认领到卡死引擎时任何截止都
// 救不了音频线程（RT 即截止执行者）——该残余登记在
// docs/20-执行/VB模式按路插件处理方案-2026-10-22.md 的 B2 节，
// 不在本场景断言范围（健康机器上不会发生）。
struct StragglerResult {
    bool ran = false;
    bool ok = true;
    double maxCbMs = 0.0;
    bool reentered = false;
    long parallelOnAfter = 0;
    bool resumeOk = false;
    int spuriousStuck = 0;  // 非卡死组被误冻计数（负载机器宽容项，只报 note）
    std::string why;
};

StragglerResult RunStragglerScenario() {
    StragglerResult r;
    const int kHangG = 7;
    const int kFrozen = 4;   // 冻结窗口（卡死 arm 着的块数）
    const int kAfter = 12;   // 释放后的块数（观察恢复）
    const int kBlocks = kFrozen + kAfter;
    Rig ser, par;
    ser.Init();
    par.Init();
    g_hangGate = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_inEngine.store(0);
    g_reentered.store(0);
    if (!g_hangGate) {
        r.why = "CreateEventW failed";
        r.ok = false;
        ser.Destroy();
        par.Destroy();
        return r;
    }
    const bool hasPool = VmParallelInit(&par.ctx);
    const int workers = static_cast<int>(par.ctx.nWorkers);
    VmParallelInit(&ser.ctx);  // ser 侧同样建池（scratch 分配器），强制串行
    InterlockedExchange(&ser.ctx.parallelOn, 0);
    InterlockedExchange(&par.ctx.parallelOn, 1);
    if (!hasPool || workers < 1) {
        // 单核/建池失败：没有 worker，卡死注入只会落在 RT 自己头上（任何
        // 截止都救不了，见上注）——跳过只报 note，门禁在 python 侧判 PASS。
        CloseHandle(g_hangGate);
        g_hangGate = nullptr;
        VmParallelShutdown(&par.ctx);
        VmParallelShutdown(&ser.ctx);
        ser.Destroy();
        par.Destroy();
        r.why = "no workers (single-core?)";
        return r;
    }
    r.ran = true;
    if (!ser.PrimeGeometry(2, 1) || !par.PrimeGeometry(2, 1)) {
        r.ok = false;
        r.why = "initial geometry request/activation failed";
        CloseHandle(g_hangGate);
        g_hangGate = nullptr;
        VmParallelShutdown(&par.ctx);
        VmParallelShutdown(&ser.ctx);
        ser.Destroy();
        par.Destroy();
        return r;
    }
    // 卡死引擎注入（仅并行侧 g7）。全部引擎成本 500µs：RT 认领最低位后忙
    // 500µs，worker 们在 ~µs 级把剩余位（含 g7）认领完——g7 必落 worker。
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) par.eng[g]->costUs = 500.0;
    par.eng[kHangG]->hangGate = g_hangGate;
    par.eng[kHangG]->inEngine = &g_inEngine;
    par.eng[kHangG]->reentered = &g_reentered;

    std::vector<float> snap(static_cast<size_t>(kCh) * 128);
    bool resumed = false;
    for (int b = 0; b < kBlocks; ++b) {
        if (b == kFrozen) {
            // 冻结窗口结束：放行卡死的 worker（模拟"插件最终自己回来了"）。
            // 主线程非 RT，可睡；给 worker 完成 + 解冻留裕量（恢复检测是
            // 动态的，这点裕量不影响断言正确性）。
            SetEvent(g_hangGate);
            Sleep(100);
        }
        ser.FillInputs(b, 8, -1);
        par.FillInputs(b, 8, -1);
        OnVbCallback(&ser.ctx, kCbBufferOut, &ser.ab, 0);
        memcpy(snap.data(), ser.wStore.data(), snap.size() * sizeof(float));
        LARGE_INTEGER t0, t1;
        QueryPerformanceCounter(&t0);
        OnVbCallback(&par.ctx, kCbBufferOut, &par.ab, 0);
        QueryPerformanceCounter(&t1);
        const double ms =
            static_cast<double>(t1.QuadPart - t0.QuadPart) * g_qpfInvUs / 1000.0;
        if (ms > r.maxCbMs) r.maxCbMs = ms;
        // B2：RT 侧绝不改配置状态（超时路径不 mutate parallelOn）
        if (InterlockedCompareExchange(&par.ctx.parallelOn, 0, 0) != 1) {
            r.ok = false;
            r.why = "parallelOn mutated by RT";
        }
        // 输出比对。哨兵（-12345）= 该组本块未被处理（冻结/误冻）。
        auto cmpGroup = [&](int g) {
            for (int ch = g * 8; ch < g * 8 + 8; ++ch)
                for (int i = 0; i < 128; ++i)
                    if (par.wStore[static_cast<size_t>(ch) * 128 + i] !=
                        snap[static_cast<size_t>(ch) * 128 + i]) {
                        char buf[160];
                        snprintf(buf, sizeof(buf),
                                 "g%d ch%d i%d mismatch (b=%d)", g, ch, i, b);
                        r.why = buf;
                        return false;
                    }
            return true;
        };
        for (int g = 0; g < 8 && r.ok; ++g) {
            const bool sentinel =
                par.wStore[static_cast<size_t>(g) * 8 * 128] == -12345.0f;
            if (g == kHangG && b < kFrozen) {
                // 卡死组冻结窗口：输出必须原封不动（卡死的 process 来不及写）
                if (!sentinel) {
                    r.ok = false;
                    r.why = "hung group written during freeze";
                }
                continue;
            }
            if (g == kHangG) {
                if (sentinel) continue;  // 解冻有裕量：尚未恢复，跳过本块
                resumed = true;
            } else if (sentinel) {
                // 非卡死组出哨兵 = 被误冻（负载机器上 worker 唤醒慢于 2ms
                // 截止的宽容项）：记 note 不判红，跳过该组本块比对。
                if (b < kFrozen) ++r.spuriousStuck;
                continue;
            }
            if (!cmpGroup(g)) r.ok = false;
        }
        if (!r.ok) break;
    }
    r.resumeOk = resumed;
    if (!resumed) {
        r.ok = false;
        if (r.why.empty()) r.why = "hung group never resumed";
    }
    r.reentered = g_reentered.load() != 0;
    if (r.reentered) {
        r.ok = false;
        r.why = "engine re-entered while occupied";
    }
    r.parallelOnAfter = InterlockedCompareExchange(&par.ctx.parallelOn, 0, 0);
    if (r.parallelOnAfter != 1) r.ok = false;
    CloseHandle(g_hangGate);
    g_hangGate = nullptr;
    VmParallelShutdown(&par.ctx);
    VmParallelShutdown(&ser.ctx);
    ser.Destroy();
    par.Destroy();
    return r;
}

// 声道档位回归：泵送引擎的块步进必须等于引擎 channels.count。
// 旧结构固定 2/8，选 2.0/4.0/5.1 时引擎按 2/4/6 解释 8ch 缓冲，输入被
// 压缩成 4×/2×/1.33× 速的持续断续；4ch 还必须对到 Quad 的 BL/BR。
bool RunChannelScenario(int procCh, std::string& why) {
    Rig ser, par;
    ser.Init();
    par.Init();
    // 同 RunScenario：声道档位回归的期望是离散口径（引擎收纯
    // 总线声道、非引擎槽清零），钉离散（第四十七轮 S2）。
    VmParallelInit(&par.ctx);
    VmParallelInit(&ser.ctx);
    InterlockedExchange(&ser.ctx.parallelOn, 0);
    InterlockedExchange(&par.ctx.parallelOn, 1);
    if (!ser.PrimeGeometry(procCh, 1) || !par.PrimeGeometry(procCh, 1)) {
        why = "geometry request/activation failed";
        VmParallelShutdown(&par.ctx);
        VmParallelShutdown(&ser.ctx);
        ser.Destroy();
        par.Destroy();
        return false;
    }

    std::vector<float> snap(static_cast<size_t>(kCh) * 128);
    bool ok = true;
    for (int b = 0; b < 4 && ok; ++b) {
        ser.FillInputs(b, 8, -1);
        par.FillInputs(b, 8, -1);
        OnVbCallback(&ser.ctx, kCbBufferOut, &ser.ab, 0);
        memcpy(snap.data(), ser.wStore.data(), snap.size() * sizeof(float));
        OnVbCallback(&par.ctx, kCbBufferOut, &par.ab, 0);
        if (memcmp(snap.data(), par.wStore.data(),
                   snap.size() * sizeof(float)) != 0) {
            why = "serial/parallel mismatch";
            ok = false;
        }
    }

    // 引擎 4ch 是 Quad（FL,FR,BL,BR）：槽 2/3 对总线 6/7。
    int busOf[8] = {0, 1, 2, 3, 4, 5, 6, 7};
    if (procCh == 4) {
        busOf[2] = 6;
        busOf[3] = 7;
    }
    const float* w = ser.wStore.data();
    const float* rin = ser.rStore.data();
    auto W = [&](int ch, int i) { return w[static_cast<size_t>(ch) * 128 + i]; };
    auto R = [&](int ch, int i) { return rin[static_cast<size_t>(ch) * 128 + i]; };
    bool inSlot[8] = {};
    for (int c = 0; c < procCh; ++c) inSlot[busOf[c]] = true;
    for (int g = 0; g < 8 && ok; ++g) {
        const int base = g * 8;
        const float gain = 1.0f + 0.01f * static_cast<float>(g);
        for (int c = 0; c < procCh && ok; ++c) {
            const int ch = base + busOf[c];
            for (int i = 0; i < 128; ++i) {
                const float exp = R(ch, i) * gain + 1e-4f;
                if (W(ch, i) != exp) {
                    char buf[160];
                    snprintf(buf, sizeof(buf),
                             "pc%d g%d bus%d i%d got %.9g exp %.9g", procCh, g,
                             busOf[c], i, W(ch, i), exp);
                    why = buf;
                    ok = false;
                    break;
                }
            }
        }
        for (int ch = base; ch < base + 8 && ok; ++ch) {
            if (inSlot[ch - base]) continue;
            for (int i = 0; i < 128; ++i) {
                // 非引擎槽必须清零（第四十七轮 S2 通道纪律；
                // 旧「透传」断言随定罪废止，见 RunScenario 注）。
                if (W(ch, i) != 0.0f) {
                    why = "non-engine slot not zeroed (r47 discipline)";
                    ok = false;
                    break;
                }
            }
        }
    }
    if (ok && ser.ctx.peakIn <= 0.0) {
        why = "peakIn should be positive";
        ok = false;
    }
    VmParallelShutdown(&par.ctx);
    VmParallelShutdown(&ser.ctx);
    ser.Destroy();
    par.Destroy();
    return ok;
}

bool OutputsZero(const Rig& rig, int groups) {
    for (int ch = 0; ch < groups * 8; ++ch)
        for (int i = 0; i < 128; ++i)
            if (rig.wStore[static_cast<size_t>(ch) * 128 + i] != 0.0f)
                return false;
    return true;
}

// 2→4→6→8 must cross a silent activation block before the pump publishes the
// new width. A group that requests a different width keeps the whole pump on
// its last complete geometry; no subset is allowed to publish.
bool RunGeometryTransitionScenario(std::string& why) {
    Rig ser, par;
    ser.Init();
    par.Init();
    VmParallelInit(&ser.ctx);
    VmParallelInit(&par.ctx);
    InterlockedExchange(&ser.ctx.parallelOn, 0);
    InterlockedExchange(&par.ctx.parallelOn, 1);
    auto cleanup = [&] {
        VmParallelShutdown(&par.ctx);
        VmParallelShutdown(&ser.ctx);
        ser.Destroy();
        par.Destroy();
    };
    auto fail = [&](const std::string& message) {
        cleanup();
        why = message;
        return false;
    };
    if (!ser.PrimeGeometry(2, 0) || !par.PrimeGeometry(2, 0))
        return fail("initial geometry request/activation failed");

    int published = 2;
    int block = 0;
    std::vector<float> snap(static_cast<size_t>(kCh) * 128);
    for (int target : {2, 4, 6, 8}) {
        const uint64_t generation = par.eng[0]->nextGeneration.load(
            std::memory_order_relaxed);
        if (!ser.RequestAll(target, 0) || !par.RequestAll(target, 0))
            return fail("geometry request failed");
        for (Rig* rig : {&ser, &par}) {
            rig->FillInputs(block, 8, -1);
            OnVbCallback(&rig->ctx, kCbBufferOut, &rig->ab, 0);
            if (InterlockedCompareExchange(&rig->ctx.workCh, 0, 0) != published
                || !OutputsZero(*rig, 8)) {
                char message[160];
                snprintf(message, sizeof(message),
                         "pending geometry target=%d published=%d host=%ld zero=%d",
                         target, published,
                         InterlockedCompareExchange(&rig->ctx.workCh, 0, 0),
                         OutputsZero(*rig, 8) ? 1 : 0);
                return fail(message);
            }
            for (int g = 0; g < 8; ++g) {
                if (rig->eng[g]->activeGeneration.load(std::memory_order_acquire)
                        != generation
                    || rig->eng[g]->lastExpectedGeneration.load(
                           std::memory_order_acquire) != generation)
                    return fail("activation block did not consume complete geometry");
            }
            rig->FillInputs(block + 1, 8, -1);
            OnVbCallback(&rig->ctx, kCbBufferOut, &rig->ab, 0);
            if (InterlockedCompareExchange(&rig->ctx.workCh, 0, 0) != target)
                return fail("matching active geometry did not publish width");
        }
        memcpy(snap.data(), ser.wStore.data(), snap.size() * sizeof(float));
        if (memcmp(snap.data(), par.wStore.data(), snap.size() * sizeof(float)) != 0)
            return fail("serial/parallel geometry transition mismatch");
        published = target;
        block += 2;
    }

    // Three groups ask for 6ch while g3 asks for 4ch. Each handle can activate,
    // but the common host geometry is not complete and must remain at 8ch.
    for (int g = 0; g < 8; ++g) {
        const int target = g == 3 ? 4 : 6;
        if (!ser.RequestGroup(g, target, 0) || !par.RequestGroup(g, target, 0))
            return fail("partial geometry request failed");
    }
    for (Rig* rig : {&ser, &par}) {
        rig->FillInputs(block, 8, -1);
        OnVbCallback(&rig->ctx, kCbBufferOut, &rig->ab, 0);
    }
    int callsAfterActivation[8] = {};
    for (int g = 0; g < 8; ++g)
        callsAfterActivation[g] = par.eng[g]->processCalls.load(
            std::memory_order_acquire);
    for (Rig* rig : {&ser, &par}) {
        rig->FillInputs(block + 1, 8, -1);
        OnVbCallback(&rig->ctx, kCbBufferOut, &rig->ab, 0);
        if (InterlockedCompareExchange(&rig->ctx.workCh, 0, 0) != 8
            || !OutputsZero(*rig, 8))
            return fail("partial-group geometry published or produced audio");
    }
    for (int g = 0; g < 8; ++g)
        if (par.eng[g]->processCalls.load(std::memory_order_acquire)
            != callsAfterActivation[g])
            return fail("mismatched common geometry advanced a group");

    if (!ser.RequestAll(6, 0) || !par.RequestAll(6, 0))
        return fail("geometry recovery request failed");
    for (Rig* rig : {&ser, &par}) {
        rig->FillInputs(block + 2, 8, -1);
        OnVbCallback(&rig->ctx, kCbBufferOut, &rig->ab, 0);
        rig->FillInputs(block + 3, 8, -1);
        OnVbCallback(&rig->ctx, kCbBufferOut, &rig->ab, 0);
        if (InterlockedCompareExchange(&rig->ctx.workCh, 0, 0) != 6)
            return fail("complete geometry did not recover after mismatch");
    }
    cleanup();
    return true;
}

// 生产多组事务 helper 的失败回滚：g3 拒绝 6ch/1 后，g0..g2 已接受的
// 6ch/1 必须全部回滚到旧 pending；任何 6ch/1 残留都不得发布到泵。
bool RunGeometryRollbackScenario(std::string& why) {
    Rig rig;
    rig.Init();
    VmParallelInit(&rig.ctx);
    InterlockedExchange(&rig.ctx.parallelOn, 1);
    auto cleanup = [&] {
        VmParallelShutdown(&rig.ctx);
        rig.Destroy();
    };
    auto fail = [&](const std::string& message) {
        cleanup();
        why = message;
        return false;
    };
    if (!rig.PrimeGeometry(2, 0)) return fail("initial geometry activation failed");

    const int failGroup = 3;
    rig.eng[failGroup]->failNextRequest.store(true, std::memory_order_release);
    if (VmApplyWorkGeometry(&rig.ctx, 6, 1) != 0)
        return fail("partial geometry transaction unexpectedly succeeded");
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        const auradsp_geometry pending = FakeLoadGeometry(
            rig.eng[g]->pendingGeneration, rig.eng[g]->pendingChannels,
            rig.eng[g]->pendingMode);
        const uint64_t requested = (uint64_t)InterlockedCompareExchange64(
            &rig.ctx.requestedGeneration[g], 0, 0);
        if (pending.generation != requested || pending.channels != 2 ||
            pending.mode != 0)
            return fail("failed transaction left a different group pending");
    }

    rig.FillInputs(0, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    if (InterlockedCompareExchange(&rig.ctx.workCh, 0, 0) != 2 ||
        InterlockedCompareExchange(&rig.ctx.chanMode, 0, 0) != 0 ||
        !OutputsZero(rig, 8))
        return fail("rollback published partial geometry or audio");
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (rig.eng[g]->activeGeneration.load(std::memory_order_acquire) !=
            (uint64_t)InterlockedCompareExchange64(
                &rig.ctx.requestedGeneration[g], 0, 0))
            return fail("rollback generation was not retained through activation");
    }

    rig.FillInputs(1, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    if (InterlockedCompareExchange(&rig.ctx.workCh, 0, 0) != 2 ||
        InterlockedCompareExchange(&rig.ctx.chanMode, 0, 0) != 0)
        return fail("complete rollback geometry did not publish");
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g)
        if (rig.eng[g]->lastExpectedChannels.load(std::memory_order_acquire) != 2 ||
            rig.eng[g]->lastExpectedMode.load(std::memory_order_acquire) != 0)
            return fail("rollback activation used rejected geometry");
    cleanup();
    return true;
}

// 重建与懒建都先请求几何、后发布 handle。新 active 从 generation 1 起，
// requested 必须保留 ABI 返回代号并跨静默激活块继续匹配。
bool RunGeometryLifecycleScenario(std::string& why) {
    Rig rig;
    rig.Init();
    VmParallelInit(&rig.ctx);
    InterlockedExchange(&rig.ctx.parallelOn, 1);
    auto cleanup = [&] {
        VmParallelShutdown(&rig.ctx);
        rig.Destroy();
    };
    auto fail = [&](const std::string& message) {
        cleanup();
        why = message;
        return false;
    };
    if (!rig.PrimeGeometry(2, 0)) return fail("initial geometry activation failed");

    InterlockedExchange(&rig.ctx.parallelOn, 0);
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g)
        if (!rig.ReplaceGroup(g, 4, 0)) return fail("rebuild handle creation failed");
    InterlockedExchange(&rig.ctx.parallelOn, 1);
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        const uint64_t requested = (uint64_t)InterlockedCompareExchange64(
            &rig.ctx.requestedGeneration[g], 0, 0);
        if (requested != rig.eng[g]->pendingGeneration.load(std::memory_order_acquire) ||
            requested == 1)
            return fail("rebuild did not retain per-handle request generation");
    }
    rig.FillInputs(0, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    if (InterlockedCompareExchange(&rig.ctx.workCh, 0, 0) != 2 ||
        !OutputsZero(rig, 8))
        return fail("rebuild published geometry before active match");
    rig.FillInputs(1, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    if (InterlockedCompareExchange(&rig.ctx.workCh, 0, 0) != 4)
        return fail("rebuilt geometry did not publish after activation");

    if (!rig.RequestAll(6, 0)) return fail("geometry recovery request failed");
    rig.FillInputs(2, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    rig.FillInputs(3, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    if (InterlockedCompareExchange(&rig.ctx.workCh, 0, 0) != 6)
        return fail("pre-lazy geometry baseline did not publish");

    const int lazyGroup = 3;
    InterlockedExchange(&rig.ctx.parallelOn, 0);
    delete rig.eng[lazyGroup];
    rig.eng[lazyGroup] = nullptr;
    rig.ctx.eng[lazyGroup] = nullptr;
    if (!rig.ReplaceGroup(lazyGroup, 6, 0))
        return fail("lazy-create handle creation failed");
    InterlockedExchange(&rig.ctx.parallelOn, 1);
    const uint64_t lazyRequested = (uint64_t)InterlockedCompareExchange64(
        &rig.ctx.requestedGeneration[lazyGroup], 0, 0);
    if (lazyRequested !=
            rig.eng[lazyGroup]->pendingGeneration.load(std::memory_order_acquire) ||
        lazyRequested == 1)
        return fail("lazy-create did not retain per-handle request generation");

    rig.FillInputs(4, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    if (InterlockedCompareExchange(&rig.ctx.workCh, 0, 0) != 6 ||
        !OutputsZero(rig, 8))
        return fail("lazy-create published partial geometry or audio");
    rig.FillInputs(5, 8, -1);
    OnVbCallback(&rig.ctx, kCbBufferOut, &rig.ab, 0);
    if (InterlockedCompareExchange(&rig.ctx.workCh, 0, 0) != 6 ||
        rig.eng[lazyGroup]->lastExpectedGeneration.load(std::memory_order_acquire) !=
            lazyRequested ||
        rig.eng[lazyGroup]->lastExpectedChannels.load(std::memory_order_acquire) != 6 ||
        rig.eng[lazyGroup]->lastExpectedMode.load(std::memory_order_acquire) != 0)
        return fail("lazy-create generation was lost after activation");
    cleanup();
    return true;
}

struct GeometrySnapshotResult {
    bool ran = false;
    bool ok = true;
    std::string why;
};

// Deterministic former race: g7 is claimed by a worker, then fan-in times out.
// While that claimant is paused, the next block requests 8ch. The claimant must
// retain generation 1 / 2ch for its old buffers, not read the new block's 8ch.
GeometrySnapshotResult RunGeometrySnapshotScenario() {
    GeometrySnapshotResult r;
    Rig par;
    par.Init();
    if (!VmParallelInit(&par.ctx) || par.ctx.nWorkers < 1) {
        r.ran = false;
        r.why = "no workers (single-core?)";
        VmParallelShutdown(&par.ctx);
        par.Destroy();
        return r;
    }
    r.ran = true;
    InterlockedExchange(&par.ctx.parallelOn, 1);
    for (int g = 0; g < 7; ++g) par.eng[g]->costUs = 500.0;
    par.eng[7]->costUs = 0.0;

    HANDLE claimed = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!claimed || !release) {
        r.ok = false;
        r.why = "CreateEventW failed";
        if (claimed) CloseHandle(claimed);
        if (release) CloseHandle(release);
        VmParallelShutdown(&par.ctx);
        par.Destroy();
        return r;
    }
    ClaimHook hook;
    hook.ctx = &par.ctx;
    hook.bit = 1L << 7;
    hook.claimed = claimed;
    hook.release = release;
    g_callbackThreadId.store(GetCurrentThreadId(), std::memory_order_release);
    g_claimHook.store(&hook, std::memory_order_release);
    auto cleanup = [&] {
        g_claimHook.store(nullptr, std::memory_order_release);
        g_callbackThreadId.store(0, std::memory_order_release);
        SetEvent(release);
        VmParallelShutdown(&par.ctx);
        CloseHandle(claimed);
        CloseHandle(release);
        par.Destroy();
    };
    auto fail = [&](const std::string& message) {
        cleanup();
        r.ok = false;
        r.why = message;
        return r;
    };

    par.FillInputs(0, 8, -1);
    OnVbCallback(&par.ctx, kCbBufferOut, &par.ab, 0);
    g_claimHook.store(nullptr, std::memory_order_release);
    if (WaitForSingleObject(claimed, 0) != WAIT_OBJECT_0)
        return fail("worker did not claim g7 before fan-in timeout");

    // Publish the next generation while g7 is frozen. Its old claimant still
    // owns the old block buffers and must still use the old expected geometry.
    if (!par.RequestAll(8, 0)) return fail("next geometry request failed");
    par.FillInputs(1, 8, -1);
    OnVbCallback(&par.ctx, kCbBufferOut, &par.ab, 0);
    SetEvent(release);
    for (int i = 0; i < 5000; ++i) {
        if (par.eng[7]->processCalls.load(std::memory_order_acquire) == 1
            && (InterlockedCompareExchange(&par.ctx.workStuck, 0, 0)
                & (1L << 7)) == 0)
            break;
        Sleep(1);
    }
    if (par.eng[7]->lastExpectedGeneration.load(std::memory_order_acquire) != 1
        || par.eng[7]->lastExpectedChannels.load(std::memory_order_acquire) != 2
        || par.eng[7]->lastExpectedMode.load(std::memory_order_acquire) != 0)
        return fail("straggler combined old buffers with next-block geometry");
    cleanup();
    return r;
}

}  // namespace

int main() {
    struct Sc {
        const char* name;
        int blocks;
        int ng;
        int nullGroup;
        long mask;
        long testKind;
    };
    const Sc scenarios[] = {
        {"full8", 40, 8, -1, 0xFF, 0},
        {"full8_tone", 40, 8, -1, 0xFF, 1},
        {"ng2", 20, 2, -1, 0xFF, 0},
        {"mask_half", 20, 8, -1, 0x0F, 0},
        {"null_grp", 20, 8, 3, 0xFF, 0},
    };
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    const int cores = static_cast<int>(si.dwNumberOfProcessors);

    bool allOk = true;
    std::string detail;
    double fullSerUs = 0.0, fullParUs = 0.0;
    int workers = 0;
    for (const auto& s : scenarios) {
        ScenResult r = RunScenario(s.name, s.blocks, s.ng, s.nullGroup, s.mask,
                                   s.testKind);
        workers = r.workers;
        if (!strcmp(s.name, "full8")) {
            fullSerUs = r.serUs;
            fullParUs = r.parUs;
        }
        const bool scOk = r.ok && r.bitExact && r.teleEq;
        if (!scOk) {
            allOk = false;
            char buf[512];
            snprintf(buf, sizeof(buf),
                     "%s(sem=%d bit=%d tele=%d ch=%d idx=%ld us=%.0f/%.0f w=%d %s); ",
                     s.name, r.ok ? 1 : 0, r.bitExact ? 1 : 0, r.teleEq ? 1 : 0,
                     r.diffCh, r.diffIdx, r.serUs, r.parUs, r.workers,
                     r.why.c_str());
            detail += buf;
        }
    }
    // 声道档位：2/4/6/8 逐档验证步进、映射与串/并行一致性
    for (int pc : {2, 4, 6, 8}) {
        std::string why;
        if (!RunChannelScenario(pc, why)) {
            allOk = false;
            char buf[256];
            snprintf(buf, sizeof(buf), "chan%d(%s); ", pc, why.c_str());
            detail += buf;
        }
    }
    // Geometry ABI: sequential width changes, partial-group mismatch,
    // transactional rollback, rebuild/lazy-create retention, and a deterministic
    // post-claim/pre-geometry-read straggler interleaving.
    std::string geometryWhy;
    bool geometryCoreOk = true;
    if (!RunGeometryTransitionScenario(geometryWhy)) {
        geometryCoreOk = false;
        detail += "geometry(" + geometryWhy + "); ";
    }
    std::string rollbackWhy;
    if (!RunGeometryRollbackScenario(rollbackWhy)) {
        geometryCoreOk = false;
        geometryWhy += "rollback: " + rollbackWhy + "; ";
        detail += "geometry-rollback(" + rollbackWhy + "); ";
    }
    std::string lifecycleWhy;
    if (!RunGeometryLifecycleScenario(lifecycleWhy)) {
        geometryCoreOk = false;
        geometryWhy += "lifecycle: " + lifecycleWhy + "; ";
        detail += "geometry-lifecycle(" + lifecycleWhy + "); ";
    }
    if (!geometryCoreOk) allOk = false;
    GeometrySnapshotResult geo = RunGeometrySnapshotScenario();
    if (geo.ran && !geo.ok) {
        allOk = false;
        detail += "geo-snapshot(" + geo.why + "); ";
    }
    // B2 straggler 场景（卡死 worker → fan-in 截止 → 冻结 → 恢复）
    StragglerResult st = RunStragglerScenario();
    if (st.ran && !st.ok) {
        allOk = false;
        detail += "straggler(" + st.why + "); ";
    }
    // 墙钟断言（full8）：串行 ≈ 8×250µs×40 ≈ 80ms；并行应 <60%（多核）。
    // 单核（workers==0）时并行退化为串行，只报 note 不判红。
    bool perfOk = true;
    std::string perfNote;
    if (workers == 0) {
        perfNote = "single-core: perf assert skipped";
    } else {
        perfOk = fullSerUs > 30000.0 && fullParUs < fullSerUs * 0.6;
        if (!perfOk) {
            allOk = false;
            char buf[160];
            snprintf(buf, sizeof(buf),
                     "perf ser=%.0fus par=%.0fus ratio=%.2f", fullSerUs,
                     fullParUs, fullSerUs > 0 ? fullParUs / fullSerUs : 0.0);
            perfNote = buf;
        } else {
            char buf[160];
            snprintf(buf, sizeof(buf), "ser=%.0fus par=%.0fus ratio=%.2f",
                     fullSerUs, fullParUs,
                     fullSerUs > 0 ? fullParUs / fullSerUs : 0.0);
            perfNote = buf;
        }
    }
    printf("{\"ran\":true,\"cores\":%d,\"workers\":%d,\"allOk\":%s,"
           "\"serUs\":%.0f,\"parUs\":%.0f,\"perfOk\":%s,\"note\":\"%s\","
           "\"detail\":\"%s\","
           "\"geoCoreOk\":%s,\"geoCoreNote\":\"%s\","
           "\"geoRan\":%s,\"geoOk\":%s,\"geoNote\":\"%s\","
           "\"stRan\":%s,\"stOk\":%s,\"stMaxCbMs\":%.1f,\"stReentered\":%s,"
           "\"stParOn\":%ld,\"stResume\":%s,\"stNote\":\"%s\"}\n",
           cores, workers, allOk ? "true" : "false", fullSerUs, fullParUs,
           perfOk ? "true" : "false", perfNote.c_str(), detail.c_str(),
           geometryCoreOk ? "true" : "false", geometryWhy.c_str(),
           geo.ran ? "true" : "false", geo.ok ? "true" : "false", geo.why.c_str(),
           st.ran ? "true" : "false", st.ok ? "true" : "false", st.maxCbMs,
           st.reentered ? "true" : "false", st.parallelOnAfter,
           st.resumeOk ? "true" : "false",
           (st.ran ? st.why : ("skipped: " + st.why)).c_str());
    return allOk ? 0 : 1;
}
