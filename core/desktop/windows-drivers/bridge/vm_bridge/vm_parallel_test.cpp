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
//
// 输出：末行单行 JSON（smoke_vm_parallel.py 消费）。退出码 0 = 全过。
#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "../../02_voicemeeter_client/VmPumpCore.h"

using namespace vmcore;

namespace {

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
};

// 假插件 process：确定性变换（与线程/时序无关）+ QPC 校准人工成本。
// B2：hangGate 非空时，在写输出前先等事件——卡死的插件来不及写输出，
// 该组输出保持调用方预置的脏哨兵（冻结的可观测判据）。
void FakeProcess(void* eng, const float* in, float* out, int frames) {
    auto* fe = static_cast<FakeEng*>(eng);
    const float k = fe->gain;
    const int n2 = frames * 2;
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
        ctx.process = FakeProcess;
        ctx.idleSeconds = 3;
        ctx.qpfInvUs = g_qpfInvUs;
        ctx.busMask = 0xFF;
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            eng[g] = new FakeEng{1.0f + 0.01f * static_cast<float>(g)};
            ctx.eng[g] = eng[g];
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
        // 组内 2..7 透传（非双耳）
        for (int ch = base + 2; ch < base + 8 && r.ok; ++ch)
            for (int i = 0; i < 128; ++i)
                if (W(ch, i) != R(ch, i)) {
                    r.ok = false;
                    r.why = "inner passthrough mismatch";
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
           "\"stRan\":%s,\"stOk\":%s,\"stMaxCbMs\":%.1f,\"stReentered\":%s,"
           "\"stParOn\":%ld,\"stResume\":%s,\"stNote\":\"%s\"}\n",
           cores, workers, allOk ? "true" : "false", fullSerUs, fullParUs,
           perfOk ? "true" : "false", perfNote.c_str(), detail.c_str(),
           st.ran ? "true" : "false", st.ok ? "true" : "false", st.maxCbMs,
           st.reentered ? "true" : "false", st.parallelOnAfter,
           st.resumeOk ? "true" : "false",
           (st.ran ? st.why : ("skipped: " + st.why)).c_str());
    return allOk ? 0 : 1;
}
