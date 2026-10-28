// VmPumpCore.h — Voicemeeter 泵共享核心（bridge/vm_bridge 用；02 泵保持原文件不动）。
//
// 与 VmAudioCallback.cpp 同源（PumpCtx/回调/引擎桥逻辑逐行对齐），
// 02 侧已绿故冻结，演进只在此头做；若改回调语义，两处必须同步改，
// 以 smoke_vm_pump.py 为准绳。相对 02 副本只增测试注入面（testKind 等
// 字段 + FillTestSignal + BUFFER_OUT 主对分支），供 bridge 的
// “测试源启动即静音主输入”语义。RT 铁律不变。
//
// Z17（2026-10-24）组间并行：串行路径语义逐位保留（02 仍是串行参照），
// 并行为 bridge 独有opt-in（ctx.parallelOn，AURA_VM_PARALLEL=0 可强制
// 串行对账）。并行在 RT 回调内引入 2 次有界内核调用（SetEvent/ResetEvent，
// ~µs 级、无阻塞无竞争）——这是“零系统调用”铁律的唯一刻意例外：并行把
// 单回调墙钟从 Σ(8 组) 压到 ≈max(单组)（Ozone 级 6ms+ → ~1ms），收益
// 远大于两次调用的代价；串行路径零调用不变。
//
// B2（2026-10-24）fan-in 等待上界：原 4×10^8 自旋 ≈ 4-12s——worker 被插件
// 崩溃/死锁拖住时音频线程同被钉死数秒，比要避免的"永久自旋"只差一个数量级。
// 改 QPC 2ms 截止 + 自旋 2×10^5 兜底；超时即放弃本块：未完成组记账为
// straggler 冻结（后续块从 todo 扣除——RT 绝不重入被占引擎），完成信号代际化
// （straggler 的迟到完成丢弃、不串进下一块计数），超时路径不碰 parallelOn
// （主线程所有权）。
#pragma once

#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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
using FnEngGetParam = int(__cdecl*)(void*, const char*, void*, unsigned int);
using FnEngVizRead = int(__cdecl*)(void*, void*, int);
using FnEngAbi = unsigned(__cdecl*)(void);
// [PATCHED-AuraDSP P-028 §7-2] 桥 ABI 协商：桥按编译期 viz 帧布局（1600B/帧）做内存透传，
// 引擎 DLL 必须同 ABI 版本——TryLoadEngine 成功后用 auradsp_abi() 强校验，
// 缺符号或版本不符按引擎不可用处理（防跨版本静默错位读帧）。
constexpr unsigned kEngineAbiExpected = 2u;

constexpr int kMaxNbs = 4096;  // 超出则该对透传（防爆栈/堆，实测 VM 给 512/1024）

// B2：fan-in 等待截止（2026-10-27 改为预算感知，见 fan-in 处）。音频线程
// 禁阻塞 API，纯自旋 + YieldProcessor。墙钟可用时主判据是"回调总时长 ≤
// budget − margin"（大缓冲如本机 VB 2048 帧/42.7ms 预算给足余量，慢组不被
// 误冻；小缓冲 128 帧/2.67ms ≈ 旧 2ms 行为）；qpfInvUs 未初始化（无墙钟）
// 时回落自旋计数 2×10^5 兜底（≈2ms 同量级）。原 4×10^8 ≈ 4-12s：音频
// 线程被钉死数秒——比它要避免的"永久自旋"只差一个数量级。
constexpr double kVmFanInWaitMs = 2.0;
constexpr uint64_t kVmFanInSpinLimit = 200000ull;

struct PumpCtx {
    FnEngProcess process = nullptr;
    FnEngDestroy destroy = nullptr;
    static constexpr int kMaxGroups = 8;
    void* eng[kMaxGroups] = {};  // 主线程按版型预建（RT 内禁分配）
    int nEng = 0;
    float* scratchIn = nullptr;   // 主线程预分配 8*kMaxNbs（双耳 8ch / 普通 2ch 共用）
    float* scratchOut = nullptr;
    // 1=该组 8ch 送引擎做双耳虚拟环绕；0=旧的主对 2ch 路径。
    // 由 vb_set_param("spatial.binaural") 更新；RT 只读。
    volatile LONG binaural = 0;
    uint64_t frames = 0;
    uint64_t maxCbTicks = 0;  // 单次 BUFFER_OUT 最大耗时（QPC ticks；爆音预算证据）
    volatile LONG gotFirst = 0;  // 首个 BUFFER 到达（主线程轮询，RT 只存一次）
    uint64_t idleSamples[kMaxGroups] = {};  // 组独立（EAPO 同式）
    bool idle[kMaxGroups] = {};
    long sr = 0;
    long nbs = 0;
    long changes = 0;             // CHANGE 到达计数（已落地重建，见主循环）
    volatile LONG pendingChange = 0;  // RT 置位，主线程轮询消费（无锁单写单读）
    volatile LONG startInfo = 0;      // STARTING 到达计数（主线程 CHANGE 重建时等新 audioInfo）
    int groups = 0;               // 本轮实际组数
    double maxDiff = 0.0;
    double peakIn = 0.0;  // 主对输入峰值（判定“有没有声”，smoke 条件断言用）
    // 每组主对峰值（回调级衰减，半衰期约 1s，保证 viz 跟随“当前”有声组；
    // 旧 max-hold 会被僵尸热组霸榜：该组静默→idle→停产 viz 帧，viz 永久空）。
    double peakGrp[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    // 总线存活：本块四指针齐全即 true（VB 对未路由的总线给空指针；EAPO/Element
    // 同症）。UI 据此把"VB 没给"和"没声"分开显示，不再神秘黑灯。
    bool grpLive[8] = {false, false, false, false, false, false, false, false};
    // 冻结输入检测：VB 有时对无路由总线持续给同一块 buffer（非零但永不变），
    // 电平表会被钉死。滚动校验和 + 连续相同计数，超 0.5s 即判冻（只清表头峰值，
    // 音频路径不动——冻住的流怎么处理输出都是冻住的，不碰最安全）。
    uint32_t sigMark[8] = {};
    int sigSame[8] = {};
    // viz 跟随的现任组（HottestVizGroup 守擂用；memset 归零即 g0，无需特意复位）。
    int vizStick = 0;
    bool bypassEntered = false;
    // 用户旁路（bridge 用；pump 不碰，恒 0 即原行为）：置位时跳过 process，
    // 输入直通输出（测试注入仍生效：先填 scratchIn 再直通，与进程内 bypass?src:eng 同义）。
    volatile LONG userBypass = 0;
    // 总线处理掩码（bit g = 第 g 组进 DSP；0 = 该总线直通）。桥经 vb_set_bus_mask
    // 下发；电平表照常计量（仅跳过 process），重开即恢复，无需等 idle 退出。
    volatile LONG busMask = 0xFF;
    // L0（P2 性能）：每组 process 耗时峰值（QPC ticks），status 暴露供
    // 爆音定位（8 组串行是回调主成本，直方图定位真凶组）。
    uint64_t maxGroupTicks[8] = {};
    // L1b：无声 idle 判定秒数（默认 3s；原硬编码 10s 休眠太慢）。
    int idleSeconds = 3;
    // ---- Z12 超预算保护观测（2026-10-23）----
    // RT 单写者（OnVbCallback 尾部），守卫线程/桥只读。EMA 整数 µs：
    // ema += (dt-ema)/8（时间常数 ≈8 块，@48k/128 ≈ 21ms）。qpfInvUs 由桥在
    // 引擎构建点算好（QPF 是常量，RT 不调）；0 = 无效 → 观测停用。
    volatile LONG cbEmaUs = 0;
    volatile LONG cbOverStreak = 0;     // 连续超预算（EMA>85%）块数，回落即清零
    double qpfInvUs = 0.0;              // 1e6/QPF；0 = 未初始化
    volatile LONG protectTestMode = 0;  // 1 = RT 停更观测值（vb_protect_test 注入）
    // ---- 测试注入面（bridge 用；pump 不碰，全零即关闭） ----
    volatile LONG testKind = 0;  // 0=关 1=正弦440 2=粉噪 3=文件（RT 读，主线程 Interlocked 写）
    double testPhase = 0.0;      // 正弦相位（RT 独占）
    uint32_t testRng = 0x12345678u;  // xorshift 白噪声源（RT 独占，禁 rand()）
    double testPink[7] = {};     // 粉噪滤波器状态（RT 独占，Paul Kellet 系数对标 Dart）
    const float* testFile = nullptr;  // 主线程 test_start 时拷贝，stop 时先清 kind 再 Sleep 后释放
    uint64_t testFrames = 0;     // 源帧数（按 testFileCh 交织）
    int testRate = 0;
    int testFileCh = 2;          // testFile 交织声道数（2..8；pump 恒 2，ASIO 桥 B2c 可为 4/6/8）
    double testPos = 0.0;  // 文件播放头（源帧单位，RT 独占，循环）
    // ---- Z17 组间并行处理（2026-10-24；bridge 专用，02 泵冻结不跟进）----
    // 根因：VM 单回调内 8 组串行 process，Ozone 级插件实测 0.76ms/组 @128
    // 帧（2026-10-23 maxGroupTicks）→ 8 组 6ms+ 远超 2.67ms 回调预算即持续
    // 爆音；Z12 保护只减用户可用的组数，不增容量。并行后单回调墙钟 ≈
    // max(单组) 而非 Σ(8 组)（FL 多轨 mixer 同级）。
    // per-group scratch：每组独占一对（worker 间零共享写）。主线程预分配
    // （RT 禁分配）。共享 scratchIn/Out 保留给串行旧径与 02 对账。
    float* scratchInG[kMaxGroups] = {};
    float* scratchOutG[kMaxGroups] = {};
    HANDLE workerWake = nullptr;               // 手工复位事件：RT 发布 Set / worker 等待
    HANDLE workerThreads[kMaxGroups - 1] = {}; // 常驻 worker（RT 自身也是 claimer）
    volatile LONG nWorkers = 0;                // 实建 worker 数
    volatile LONG parallelOn = 0;              // 1=并行（RT 每块快照一次）；0=串行
    volatile LONG workerStop = 0;              // 1=请求退出（主线程置位 + SetEvent）
    volatile LONG rtInBlock = 0;               // RT 在途 BUFFER_OUT 计数（销毁句柄前等待归零）
    // 任务发布（RT 单写；worker 只读/认领；Interlocked 全屏障保序）：
    volatile LONG workGen = 0;        // 每块 +1：发布本块快照（RT 最后一步 bump）
    volatile LONG workExpect = 0;     // 本块 todo 组数（观测用；fan-in 判据是位图）
    // B2：完成位图，64 位打包 (gen<<32)|doneBitmap。RT 发布时置
    // (newGen<<32)|0；完成方 CAS 置位。代际不匹配即丢弃完成信号——
    // 防 straggler（fan-in 超时后仍在跑的 worker）把完成串进下一块：
    // 旧式 plain count + 每块清零在该场景令下一块 fan-in 提前放行，
    // 该块输出缺组。CAS 竞争失败重取，无锁。
    volatile LONGLONG workDonePacked = 0;
    // B2：straggler 冻结位图（bit g = 该组有 worker 超时后仍在引擎内）。
    // RT 在超时路径与下一块发布时记账（VmMarkStuck）；完成方无条件清位
    // （VmWorkComplete——清除点在 ProcessGroupVm 完全返回之后，故"位清零"
    // ⟹"该组输出缓冲无人在写"，可安全再认领）。发布时从 todo 扣除冻结组：
    // RT 绝不重入被占引擎（两个线程同进一个引擎实例 = 状态撕裂/UAF 级），
    // 该组输出冻结至 worker 真正返回。
    volatile LONG workStuck = 0;
    volatile LONG fanTimeouts = 0;  // fan-in 超时（冻结事件）累计（RT 单写；status 诊断）
    LONG curTodo = 0;  // RT 私有：上一并行块 todo 位图（超时 straggler 记账用）
    // 认领协议：64 位打包 (gen<<32)|bitmap。CAS 抢最低位；gen 字段随块轮换，
    // 防「上一块尾组刚完成、下一块已发布」的跨块 stale-claim（worker 持旧
    // 快照写到旧 ab 上的竞争——实测窗口 ns 级但真实存在）。
    volatile LONGLONG workClaimPacked = 0;
    // 本块快照（RT 在 bump workGen 之前写完；worker 见新 gen 后读）：
    void* curAb = nullptr;
    long curN = 0;
    long curMask = 0;
    long curHaveEng = 0;
    long curBinaural = 0;      // 块快照：worker 须与 RT 预填同口径（防测试信号翻转竞争）
    long curTestKind = 0;      // 块快照：testKind 翻转只影响下一块
    volatile LONG testReady = 0;      // bitmap：bit g = scratchInG[g] 已由 RT 预填测试信号
    // 共享量 per-group 中间槽：worker 写、RT fan-in 后归约。max/OR 与顺序
    // 无关，串/并行两条路径逐位同义（peakIn/maxDiff 本是 max-hold）。
    double peakInGrp[kMaxGroups] = {};
    double maxDiffGrp[kMaxGroups] = {};
    bool grpBypass[kMaxGroups] = {};
};

// D2（2026-10-24）：RT 在途守卫 + 确定性排空等待（三桥共用）。
//
// `rtInBlock` 必须严格成对增减，否则两种故障都很隐蔽：漏增 → 销毁前的等待
// 立即通过（等于没等，直接 free 掉 RT 还在读的缓冲 = UAF）；漏减 → 等待必然
// 超时，把正常卸载拖到上界。音频回调有多条提前 return（无块 / 用户旁路 /
// 无引擎句柄），手写法很容易漏，故用 RAII：析构逆序执行由编译器保证。
// 仅两条 Interlocked，无锁 / 无分配 / 无 syscall，符合 RT 铁律。
struct RtInBlockGuard {
    volatile LONG* counter;
    explicit RtInBlockGuard(volatile LONG* c) : counter(c) {
        if (counter) InterlockedIncrement(counter);
    }
    ~RtInBlockGuard() {
        if (counter) InterlockedDecrement(counter);
    }
    RtInBlockGuard(const RtInBlockGuard&) = delete;
    RtInBlockGuard& operator=(const RtInBlockGuard&) = delete;
};

// 确定性排空：轮询 rtInBlock 归零，墙钟上界 maxMs（默认 3s）。
// 替代原来的 Sleep(50)——那是在"猜一个够用的毫秒数"：重载 / 驱动线程被挂住
// 时不够（free 掉 RT 仍在读的缓冲 = UAF），正常情况又白等 50ms。
// 用 GetTickCount64 墙钟而不是计数循环：Sleep(1) 实际粒度 5-15ms，按 1ms 记
// 的 3000 次循环实测可达 15-45s（注释里的"3s 上限"从未成立）。
// 返回 false = 上界内未排空（RT 卡死 / 野指针），由调用方决定如何收场。
inline bool WaitRtDrained(volatile LONG* counter, DWORD maxMs = 3000) {
    if (!counter) return true;
    const ULONGLONG deadline = GetTickCount64() + (ULONGLONG)maxMs;
    for (;;) {
        if (InterlockedCompareExchange(counter, 0, 0) == 0) return true;
        if (GetTickCount64() >= deadline) break;
        Sleep(1);
    }
    return InterlockedCompareExchange(counter, 0, 0) == 0;
}

inline bool PairIsSilent(const float* a, const float* b, long n) {
    // EAPO 同式：精确零才算静默（-100dBFS 的弱音也算有声，不误杀；见借鉴注）。
    for (long i = 0; i < n; ++i) {
        if (a[i] != 0.0f || b[i] != 0.0f) return false;
    }
    return true;
}

// 表头峰值衰减：上升沿直跟、释放按块时长折算（nbs 变化手感不漂）。
// seconds=释放到 37% 的时间；调用方按场景选 0.2（正常）/ 0.05（总线消失快衰）。
inline void DecayGrpPeak(PumpCtx* c, int g, long n, double seconds) {
    const double blk = (c->sr > 0 && n > 0) ? (double)n / (double)c->sr : 0.01;
    double k = blk / seconds;
    if (k > 1.0) k = 1.0;
    if (k > 0.0) c->peakGrp[g] -= c->peakGrp[g] * k;
}

// 测试信号填充（RT-safe：纯数学，无分配无锁；与 Dart FileSource/ToneSource/PinkSource 同构）。
// 用户语义：测试源启动即静音主通道输入，本函数输出替代 VB 输入进同一条 DSP 链。
// FillTestSignalN：dst 为 ch 声道交织。kind1/2 源写 ch0/1（其余补零）；
// kind3 按 testFileCh→ch 复制（不足补零）。ch==2 即原 FillTestSignal 逐字节同义。
inline void FillTestSignalN(PumpCtx* c, float* dst, long n, int ch) {
    if (ch <= 0) return;
    const double sr = c->sr > 0 ? (double)c->sr : 48000.0;
    const long kind = c->testKind;  // 单次读，快照
    if (kind == 1) {
        const double d = 2.0 * 3.14159265358979 * 440.0 / sr;
        for (long i = 0; i < n; ++i) {
            const float s = (float)(0.3 * sin(c->testPhase));
            c->testPhase += d;
            if (c->testPhase > 2.0 * 3.14159265358979)
                c->testPhase -= 2.0 * 3.14159265358979;
            float* f = dst + (size_t)i * (size_t)ch;
            f[0] = s;
            if (ch > 1) f[1] = s;
            for (int k = 2; k < ch; ++k) f[k] = 0.0f;
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
            float* f = dst + (size_t)i * (size_t)ch;
            f[0] = s;
            if (ch > 1) f[1] = s;
            for (int k = 2; k < ch; ++k) f[k] = 0.0f;
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
        const int srcCh = (c->testFileCh >= 1 && c->testFileCh <= 8) ? c->testFileCh : 2;
        const int copy = (ch < srcCh) ? ch : srcCh;
        for (long i = 0; i < n; ++i) {
            if (c->testPos >= (double)(total - 1)) c->testPos = 0.0;
            const uint64_t i0 = (uint64_t)c->testPos;
            const double frac = c->testPos - (double)i0;
            uint64_t i1 = i0 + 1;
            if (i1 >= total) i1 = total - 1;
            const float* a = c->testFile + (size_t)i0 * (size_t)srcCh;
            const float* b = c->testFile + (size_t)i1 * (size_t)srcCh;
            float* f = dst + (size_t)i * (size_t)ch;
            for (int k = 0; k < copy; ++k)
                f[k] = (float)(a[k] * (1.0 - frac) + b[k] * frac);
            for (int k = copy; k < ch; ++k) f[k] = 0.0f;
            c->testPos += ratio;
        }
    } else {
        for (long i = 0; i < n; ++i) {
            float* f = dst + (size_t)i * (size_t)ch;
            for (int k = 0; k < ch; ++k) f[k] = 0.0f;
        }
    }
}

inline void FillTestSignal(PumpCtx* c, float* dst, long n) {
    FillTestSignalN(c, dst, n, 2);
}

// Z17：单组处理主体——串行/并行共用的唯一实现（两条路径必须逐位同义）。
// 由原 OnVbCallback 内联 for 循环体原样提取；差异仅：
//  1) scratch 改取每组独占对 scratchInG/OutG（并行时 worker 间零共享写；
//     串行旧径的共享 scratchIn/Out 保留未用，02 对账与回退参考）；
//  2) 三个共享量（peakIn/maxDiff/bypassEntered）改写 per-group 中间槽，
//     由调用方 fan-in 后归约（max/OR 与组间顺序无关）；
//  3) binaural/testKind 由调用方按块快照透传（原 per-group 活读，翻转时
//     组间可撕裂；并行预填更必须同口径，否则测试信号数据竞争）。
// testReady=true：scratchInG[g] 已由调用方（并行路径的 RT）按串行同序预填
// 测试信号——FillTestSignal 写共享 testPhase/testRng/testPink/testPos，
// 多线程并发即数据竞争，且各组按 g 顺序消费同一信号流才逐位一致。
inline void ProcessGroupVm(PumpCtx* c, VbAudioBuffer* ab, int g, long n,
                           long mask, bool haveEng, bool binaural,
                           long testKind, bool testReady) {
    const long base = (long)g * 8;
    // v2：每组主对（base+0/1）进该组引擎；组内其余 6 通道 + 组外全部透传。
    const float* inL = ab->r[base];
    const float* inR = ab->r[base + 1];
    float* outL = ab->w[base];
    float* outR = ab->w[base + 1];
    if (!inL || !inR || !outL || !outR) {
        // VB 没给这条总线 buffer（未路由/未分配）：标死 + 50ms 快衰，
        // 灯半秒内灭，不钉死也不闪瞎。
        if (g < 8) {
            c->grpLive[g] = false;
            DecayGrpPeak(c, g, n, 0.05);
        }
        return;
    }
    if (g < 8) c->grpLive[g] = true;
    // 输入峰值（全组主对的最大值；smoke 据此判定"有没有声"）。
    double grpPeak = 0.0;
    for (long i = 0; i < n; ++i) {
        const double a = inL[i] < 0 ? -(double)inL[i] : (double)inL[i];
        const double b = inR[i] < 0 ? -(double)inR[i] : (double)inR[i];
        const double m = a > b ? a : b;
        if (m > grpPeak) grpPeak = m;
    }
    if (g < 8) {
        // 冻结检测：步进 16 采、最多 64 点做 FNV 式折叠（RT 内纯整数运算）。
        // 同一块内容连续超 0.5s → 本块峰值按 0 计（只清表头）。
        uint32_t h = 2166136261u;
        const long step = n > 64 ? n / 64 : 1;
        for (long i = 0; i < n; i += step) {
            union {
                float f;
                uint32_t u;
            } xa, xb;
            xa.f = inL[i];
            xb.f = inR[i];
            h ^= xa.u + 0x9e3779b9u + (h << 6) + (h >> 2);
            h ^= xb.u + 0x9e3779b9u + (h << 6) + (h >> 2);
        }
        if (h == c->sigMark[g]) {
            if (c->sigSame[g] < 1000000) ++c->sigSame[g];
        } else {
            c->sigMark[g] = h;
            c->sigSame[g] = 0;
        }
        const long frozenAt =
            c->sr > 0 && n > 0 ? c->sr / n / 2 : 240;  // 约 0.5s 的块数
        if (frozenAt > 0 && c->sigSame[g] > frozenAt) grpPeak = 0.0;
    }
    if (g < 8) {
        // 上升沿直接跟，释放约 200ms（旧 0.99995/块半衰期约 1s，灯要两三秒
        // 才灭，用户读成"卡死"；200ms 人耳/人眼都跟得上，又不至于抖）。
        if (grpPeak > c->peakGrp[g])
            c->peakGrp[g] = grpPeak;
        else
            DecayGrpPeak(c, g, n, 0.2);
    }
    c->peakInGrp[g] = grpPeak;  // Z17：peakIn 归约中间槽（原直接 max 进 c->peakIn）
    for (long ch = base + 2; ch < base + 8; ++ch) {
        if (ab->w[ch] && ab->r[ch] && ab->w[ch] != ab->r[ch])
            memcpy(ab->w[ch], ab->r[ch], (size_t)n * sizeof(float));
    }
    // 无引擎桥（DLL 缺失/符号不全/组超预建）或本总线被 mask 关掉：主对透传，
    // 绝不吞声。电平表在上游已计量，不受影响；mask 与 idle 无关，重开即恢复。
    if (!haveEng || c->eng[g] == nullptr || (mask & (1L << g)) == 0) {
        if (outL != inL) memcpy(outL, inL, (size_t)n * sizeof(float));
        if (outR != inR) memcpy(outR, inR, (size_t)n * sizeof(float));
        return;
    }
    // 静音空转（组独立，EAPO 同式）。
    if (!c->idle[g]) {
        const int procCh = binaural ? 8 : 2;
        // per-group scratch 优先；分配不全的极端场景回退共享对（仅串行安全，
        // 并行判定已要求本块所有组 per-group 齐备，不会两条路混用）。
        float* sIn = c->scratchInG[g] ? c->scratchInG[g] : c->scratchIn;
        float* sOut = c->scratchOutG[g] ? c->scratchOutG[g] : c->scratchOut;
        if (binaural) {
            // 8ch：FL/FR/C/LFE/SL/SR/BL/BR 全量进引擎。
            if (!testReady) {
                for (long i = 0; i < n; ++i) {
                    for (int ch = 0; ch < 8; ++ch) {
                        const float* src = ab->r[base + ch];
                        sIn[i * 8 + ch] = src ? src[i] : 0.0f;
                    }
                }
            }
            if (testKind != 0 && !testReady) {
                // 测试信号仍按 stereo 生成，再展开到 FL/FR；其余置零。
                FillTestSignal(c, sIn, n);
                for (long i = n - 1; i >= 0; --i) {
                    sIn[i * 8] = sIn[i * 2];
                    sIn[i * 8 + 1] = sIn[i * 2 + 1];
                    for (int ch = 2; ch < 8; ++ch)
                        sIn[i * 8 + ch] = 0.0f;
                }
            }
        } else if (testKind != 0) {
            // 测试注入：静音主通道 VB 输入，测试信号进同一条 DSP 链。
            if (!testReady) FillTestSignal(c, sIn, n);
        } else {
            for (long i = 0; i < n; ++i) {
                sIn[i * 2] = inL[i];
                sIn[i * 2 + 1] = inR[i];
            }
        }
        bool outSilent = true;
        if (c->userBypass) {
            // 用户旁路：跳过 process，输入直通（测试信号同样直通）。
            for (long i = 0; i < n; ++i) {
                outL[i] = inL[i];
                outR[i] = inR[i];
            }
            // 旁路输出==输入：测试注入恒视为有声，否则看输入。
            outSilent = (testKind != 0) ? false : PairIsSilent(inL, inR, n);
        } else {
            // L0：per-group process 耗时打点（QPC ~50ns × 8 组，可忽略）。
            LARGE_INTEGER gt0, gt1;
            QueryPerformanceCounter(&gt0);
            c->process(c->eng[g], sIn, sOut, (int)n);
            QueryPerformanceCounter(&gt1);
            if (g < 8) {
                const uint64_t gt = (uint64_t)(gt1.QuadPart - gt0.QuadPart);
                if (gt > c->maxGroupTicks[g]) c->maxGroupTicks[g] = gt;
            }
            double grpDiff = 0.0;
            for (long i = 0; i < n; ++i) {
                const float oL = sOut[i * procCh];
                const float oR = sOut[i * procCh + 1];
                outL[i] = oL;
                outR[i] = oR;
                if (oL != 0.0f || oR != 0.0f) outSilent = false;
                const double dL = (double)oL - (double)inL[i];
                const double dR = (double)oR - (double)inR[i];
                const double d = dL < 0 ? -dL : (dR < 0 ? -dR : (dL > dR ? dL : dR));
                if (d > grpDiff) grpDiff = d;
            }
            c->maxDiffGrp[g] = grpDiff;  // Z17：maxDiff 归约中间槽
            if (binaural) {
                // 双耳输出只保留 FL/FR；其余置零，避免 VM 下混把原环绕混回来。
                for (long ch = base + 2; ch < base + 8; ++ch) {
                    if (ab->w[ch]) memset(ab->w[ch], 0, (size_t)n * sizeof(float));
                }
            }
            const bool inSilent = PairIsSilent(inL, inR, n);
            if (inSilent && outSilent)
                c->idleSamples[g] += (uint64_t)n;
            else
                c->idleSamples[g] = 0;
            c->idle[g] = c->sr > 0 &&
                         c->idleSamples[g] >
                             (uint64_t)c->sr * (uint64_t)(c->idleSeconds > 0 ? c->idleSeconds : 3);
        }
    } else {
        c->grpBypass[g] = true;  // Z17：bypassEntered 归约中间槽
        memcpy(outL, inL, (size_t)n * sizeof(float));
        memcpy(outR, inR, (size_t)n * sizeof(float));
        if (!PairIsSilent(inL, inR, n)) {
            c->idle[g] = false;
            c->idleSamples[g] = 0;
        }
    }
}

// B2：完成上报（RT 与 worker 同协议）。调用点保证发生在 ProcessGroupVm
// 完全返回之后——故"置完成位"与"清冻结位"两个动作都等价于"该组输出缓冲
// 已无人在写"，后续块可安全再认领该组。
// 代际匹配（正常路径）：CAS 置完成位（竞争失败重取，无锁）。
// 代际不匹配（本块已被 fan-in 超时放弃）：丢弃完成信号。
// 两条路径都无条件清冻结位：同代内一个组只有一个 claimer，完成时引擎内
// 必无他者，清位安全；而不清会留下"完成方先清、RT 后置位"的永久误冻
// 窗口（见 VmMarkStuck 的 mark-then-recheck 说明）。
inline void VmWorkComplete(PumpCtx* c, LONG gen, LONG bit) {
    for (;;) {
        const LONGLONG cur = InterlockedCompareExchange64(&c->workDonePacked, 0, 0);
        if ((LONG)(cur >> 32) == gen) {
            if (InterlockedCompareExchange64(&c->workDonePacked,
                                             cur | (LONGLONG)(uint32_t)bit,
                                             cur) == cur)
                break;
            continue;  // 与同代其他完成方竞争失败：重取再试
        }
        break;  // 代际已轮换：完成信号丢弃（不污染下一块位图）
    }
    InterlockedAnd(&c->workStuck, ~bit);
}

// B2：把"未完成"组记入冻结位图（mark-then-recheck）。完成方可能在 RT 读到
// 完成位图之后、OR 之前落盘——此刻它看到的还是本代，走"置完成位 + 清冻结
// 位"路径，其清位会被随后的 OR 覆盖 → 该组永久误冻。故 OR 后立刻复读
// 完成位图，把已落盘的位再清掉。复读必须仍在本代（调用方保证在代际清零
// 之前）。残留窗口只剩"复读后、完成方下一次 CAS 前"，那时完成方的清位
// 必然晚于 OR，覆盖关系正确。
inline void VmMarkStuck(PumpCtx* c, LONG bits) {
    if (!bits) return;
    InterlockedOr(&c->workStuck, bits);
    const LONG doneNow =
        (LONG)(InterlockedCompareExchange64(&c->workDonePacked, 0, 0) &
               0xFFFFFFFFLL);
    const LONG raced = bits & doneNow;
    if (raced) InterlockedAnd(&c->workStuck, ~raced);
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
            c->grpLive[g] = false;
            c->sigMark[g] = 0;
            c->sigSame[g] = 0;
        }
        c->maxDiff = 0.0;
        c->bypassEntered = false;
        InterlockedIncrement(&c->startInfo);
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
    // Z17：在途标记——重建/停止序列等它归零再销毁引擎句柄（并行 fan-in
    // 期间 worker 持句柄 process；先停回调也可能有块在飞，50ms 睡眠余量
    // 升级为确定性等待，见 DestroyEngines）。
    InterlockedIncrement(&c->rtInBlock);
    // 爆音预算：整块处理耗时打点（QPC 无等待，~50ns，可忽略）。
    LARGE_INTEGER t0, t1;
    QueryPerformanceCounter(&t0);
    auto* ab = (VbAudioBuffer*)lpData;
    if (ab->nbo < 2 || ab->nbs <= 0 || ab->nbs > kMaxNbs) {
        InterlockedDecrement(&c->rtInBlock);
        return 0;
    }
    const long n = ab->nbs;
    // 组数 = min(nbi,nbo)/8（EAPO 同式），钳到预建 handle 数。
    int ng = (int)(ab->nbi < ab->nbo ? ab->nbi : ab->nbo) / 8;
    if (ng < 1) ng = 1;
    // 只按硬上限钳；缺 handle 的组内各自透传（haveEng/eng[g] 守卫），不整体归零。
    if (ng > PumpCtx::kMaxGroups) ng = PumpCtx::kMaxGroups;
    c->groups = ng;
    const bool haveEng = c->process != nullptr;
    // 本组快照（整块统一口径，避免组间撕裂）。Z17：binaural/testKind 也
    // 按块快照（原 per-group 活读，翻转时组间可撕裂；并行预填更必须同口径，
    // 否则 FillTestSignal 的共享相位/RNG 状态会数据竞争）。
    const long mask = InterlockedCompareExchange(&c->busMask, 0, 0);
    const bool binaural = InterlockedCompareExchange(&c->binaural, 0, 0) != 0;
    const long testKind = InterlockedCompareExchange(&c->testKind, 0, 0);
    // 共享量归约槽清零（per-block；归约见尾部）。
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        c->peakInGrp[g] = 0.0;
        c->maxDiffGrp[g] = 0.0;
        c->grpBypass[g] = false;
    }
    // Z17 并行判定：池就绪 + 开关 + 多组 + 本块所有组 per-group scratch 齐备
    // （分配不全的极端场景只走串行，串行内可回退共享 scratch，绝不变竞赛）。
    bool par = c->parallelOn != 0 && c->nWorkers > 0 && ng > 1;
    if (par) {
        for (int g = 0; g < ng; ++g) {
            if (!c->scratchInG[g] || !c->scratchOutG[g]) {
                par = false;
                break;
            }
        }
    }
    if (par) {
        // ---- Z17 并行路径：发布 → 认领（RT 也是 claimer）→ fan-in ----
        // B2：先结清上一块的 straggler 账，再把冻结组从本块 todo 扣除。
        // 上一块 fan-in 若超时放弃，会有组处于"已认领未完成"（worker 仍在
        // 引擎内）；本块若放该组进 todo，认领方会重入被占引擎——两个线程
        // 同进一个引擎实例，状态撕裂/UAF 级。故超时块必须记账，且 RT 绝不
        // 自行重入（那会挂死音频线程）。prevDone 必须在下面的代际清零前读：
        // 清零会抹掉旧代际位图。
        const LONG prevDone =
            (LONG)(InterlockedCompareExchange64(&c->workDonePacked, 0, 0) &
                   0xFFFFFFFFLL);
        VmMarkStuck(c, c->curTodo & ~prevDone);  // 上一代未完成组 → 冻结
        const LONG stuck = InterlockedCompareExchange(&c->workStuck, 0, 0);
        LONG todo = 0;
        for (int g = 0; g < ng; ++g) todo |= (1L << g);
        todo &= ~stuck;
        LONG testRdy = 0;
        // 测试信号预填：FillTestSignal 写共享 testPhase/testRng/testPink/
        // testPos，且各组按 g 顺序消费同一信号流——必须 RT 单线程同序执行，
        // 才与串行路径逐位一致。只预填将真正进 DSP 的组（与 ProcessGroupVm
        // 内的 gather 条件同口径：eng 在、mask 开、非 idle）。B2：冻结组
        // 不预填——它本块不消费信号流（输出冻结），恢复后无缝续接。
        if (testKind != 0 && haveEng) {
            for (int g = 0; g < ng; ++g) {
                if (stuck & (1L << g)) continue;
                const long base = (long)g * 8;
                if (!ab->r[base] || !ab->r[base + 1] || !ab->w[base] ||
                    !ab->w[base + 1])
                    continue;
                if (!c->eng[g] || (mask & (1L << g)) == 0 || c->idle[g]) continue;
                float* sIn = c->scratchInG[g];
                FillTestSignal(c, sIn, n);
                if (binaural) {
                    for (long i = n - 1; i >= 0; --i) {
                        sIn[i * 8] = sIn[i * 2];
                        sIn[i * 8 + 1] = sIn[i * 2 + 1];
                        for (int ch = 2; ch < 8; ++ch)
                            sIn[i * 8 + ch] = 0.0f;
                    }
                }
                testRdy |= (1L << g);
            }
        }
        const LONG newGen = InterlockedCompareExchange(&c->workGen, 0, 0) + 1;
        // 完成位图切到新代际（旧代际位图作废；其未完成组已在上方结清为
        // straggler）。必须早于 gen bump——worker 见新 gen 时位图必已就绪。
        InterlockedExchange64(&c->workDonePacked, (LONGLONG)newGen << 32);
        c->curAb = ab;
        c->curN = n;
        c->curMask = mask;
        c->curHaveEng = haveEng ? 1 : 0;
        c->curBinaural = binaural ? 1 : 0;
        c->curTestKind = testKind;
        InterlockedExchange(&c->testReady, testRdy);
        LONG expect = 0;
        for (LONG t = todo; t; t &= t - 1) ++expect;
        InterlockedExchange(&c->workExpect, expect);
        c->curTodo = todo;  // RT 私有：供下一块 straggler 记账
        // 认领字（gen<<32|bitmap）先落、gen bump 最后：Interlocked 全屏障
        // 保证 worker 见新 gen 时快照与认领字必已就绪（无半成品发布）。
        InterlockedExchange64(&c->workClaimPacked,
                              ((LONGLONG)newGen << 32) |
                                  (LONGLONG)(uint32_t)todo);
        InterlockedIncrement(&c->workGen);
        SetEvent(c->workerWake);
        // RT 自身也是 claimer（与 worker 同协议，见 VmWorkerMain）。
        for (;;) {
            const LONGLONG cur =
                InterlockedCompareExchange64(&c->workClaimPacked, 0, 0);
            if ((LONG)(cur >> 32) != newGen) break;
            const LONG bm = (LONG)(cur & 0xFFFFFFFFLL);
            if (!bm) break;
            const LONG bit = bm & (~bm + 1);
            const LONGLONG next = ((LONGLONG)newGen << 32) |
                                  (LONGLONG)(uint32_t)(bm & ~bit);
            if (InterlockedCompareExchange64(&c->workClaimPacked, next, cur) !=
                cur)
                continue;
            int g = 0;
            for (LONG b = bit; !(b & 1); b >>= 1) ++g;
            ProcessGroupVm(c, ab, g, n, mask, haveEng, binaural, testKind,
                           (testRdy & bit) != 0);
            VmWorkComplete(c, newGen, bit);
        }
        // fan-in：音频线程禁阻塞 API，纯自旋（YieldProcessor 降耗降温）。
        // B2：QPC 墙钟为主判据、自旋计数仅作 qpf 不可用时的兜底（2×10^5，
        // 与旧固定 2ms 同量级）。超时 = 放弃本块：未完成组记账为 straggler
        // （后续块冻结该组直至 worker 真正离开引擎），绝不动 parallelOn
        // （主线程所有权，RT 侧改配置状态本身也是隐患），绝不清
        // workClaimPacked（代际字天然防跨块认领）。原 4×10^8 ≈ 4-12s 会把
        // 音频线程钉死数秒。
        //
        // 截止 = 预算感知（2026-10-27）：**从回调起点**钳总时长 ≤ budget −
        // margin（margin = max(200µs, 7.5% 预算)）。背景：本机 VB 缓冲
        // 2048 帧（预算 42.7ms）下单组 Ozone process ≈ 27ms，固定 2ms 截止
        // 会在加载/CPU 争用令组间耗时不均时，把稍慢的组误冻成 straggler
        // ——其输出停在上一块（陈旧/跳变 = 可听卡顿），而回调远未超预算
        // （实测 maxCbUs ≈ maxGrp0 + 2ms，正是每块撞截止的证据）。预算
        // 感知后：128 帧小缓冲 ≈ 旧行为（且总时长真正钳进预算），大缓冲
        // 给足余量，慢组得以完成而不再被误冻；总时长仍恒有上界 = 预算。
        LARGE_INTEGER tf0;
        QueryPerformanceCounter(&tf0);
        // 墙钟可用时的总耗时上界（从回调起点 t0 计）：budget − margin。
        // 0 = 无墙钟（回落旧固定 2ms + 自旋兜底）。
        double deadlineTotalUs = 0.0;
        if (c->qpfInvUs > 0.0 && c->sr > 0 && c->nbs > 0) {
            const long budgetUs =
                (long)((double)c->nbs * 1000000.0 / (double)c->sr);
            double marginUs = (double)budgetUs * 0.075;
            if (marginUs < 200.0) marginUs = 200.0;
            deadlineTotalUs = (double)budgetUs - marginUs;
        }
        uint64_t spins = 0;
        bool timedOut = false;
        for (;;) {
            const LONGLONG cur =
                InterlockedCompareExchange64(&c->workDonePacked, 0, 0);
            if ((LONG)(cur >> 32) != newGen) break;  // 防御：代际不该在此刻轮换
            if (((LONG)(cur & 0xFFFFFFFFLL) & todo) == todo) break;
            YieldProcessor();
            if (c->qpfInvUs > 0.0) {
                // 墙钟为主判据（0x3FF 采样降 QPC 开销；自旋计数不封顶——
                // 截止由墙钟决定，计数只做采样节奏）。
                if ((++spins & 0x3FF) == 0) {
                    LARGE_INTEGER tf1;
                    QueryPerformanceCounter(&tf1);
                    if ((double)(tf1.QuadPart - t0.QuadPart) * c->qpfInvUs >=
                        deadlineTotalUs) {
                        timedOut = true;
                        break;
                    }
                }
            } else if (++spins >= kVmFanInSpinLimit) {
                timedOut = true;
                break;
            }
        }
        if (timedOut) {
            InterlockedIncrement(&c->fanTimeouts);  // 诊断：冻结事件累计
            // 记账：未完成组 → 冻结。VmMarkStuck 内部 recheck 消除"完成方
            // 先清位、RT 后置位"的永久误冻窗口；此后才完成的 straggler 走
            // 代际不匹配路径自行解冻。
            const LONG done =
                (LONG)(InterlockedCompareExchange64(&c->workDonePacked, 0, 0) &
                       0xFFFFFFFFLL);
            VmMarkStuck(c, todo & ~done);
        }
        ResetEvent(c->workerWake);
    } else {
        // ---- 串行路径（原语义，经同一 ProcessGroupVm；testReady=false 自填）----
        // B2：串行同样跳过 straggler 冻结组——并行超时后若回串行，RT 自行
        // 处理冻结组等于重入被占引擎（挂死音频线程）。冻结组输出保持不动，
        // 直至 worker 真正离开引擎（VmWorkComplete 代际不匹配路径解冻）。
        const LONG stuck = InterlockedCompareExchange(&c->workStuck, 0, 0);
        for (int g = 0; g < ng; ++g) {
            if (stuck & (1L << g)) continue;
            ProcessGroupVm(c, ab, g, n, mask, haveEng, binaural, testKind,
                           false);
        }
        c->curTodo = 0;  // 本块无并行发布：清账，防下一块误判 straggler
    }
    // 共享量归约（串/并行共用；max/OR 与组间顺序无关，逐位同义）。
    for (int g = 0; g < ng; ++g) {
        if (c->peakInGrp[g] > c->peakIn) c->peakIn = c->peakInGrp[g];
        if (c->maxDiffGrp[g] > c->maxDiff) c->maxDiff = c->maxDiffGrp[g];
        if (c->grpBypass[g]) c->bypassEntered = true;
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
    // Z12 预算观测：EMA(µs) + 连续超 85% 预算块计数。纯整数 + 单写者
    // volatile store，RT 零等待；test 注入模式时停更（守卫冒烟驱动用）。
    if (c->qpfInvUs > 0.0 && c->sr > 0 && c->nbs > 0 && !c->protectTestMode) {
        const long dtUs = (long)((double)dt * c->qpfInvUs);
        const long ema = c->cbEmaUs;
        c->cbEmaUs = (LONG)(ema + (dtUs - ema) / 8);
        const long budgetUs = (long)((double)c->nbs * 1000000.0 / (double)c->sr);
        if (budgetUs > 0) {
            if (c->cbEmaUs * 100 > budgetUs * 85)
                ++c->cbOverStreak;
            else
                c->cbOverStreak = 0;
        }
    }
    InterlockedDecrement(&c->rtInBlock);
    return 0;
}

// Z17：常驻 worker（桥主线程建；THREAD_PRIORITY_TIME_CRITICAL——块预算
// 2.67ms 级的音频辅助线程）。协议：等事件 → 见新 gen → 读块快照 → 与 RT
// 同协议认领（64 位打包 CAS）→ ProcessGroupVm → VmWorkComplete 上报完成
// （代际化位图；本块已被 fan-in 超时放弃则丢弃完成信号并解除该组冻结）。
// 认领循环内代际不匹配即退出重取快照（防跨块 stale-claim，见
// workClaimPacked 注释）。
static DWORD WINAPI VmWorkerMain(LPVOID param) {
    auto* c = (PumpCtx*)param;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    LONG lastGen = InterlockedCompareExchange(&c->workGen, 0, 0);
    for (;;) {
        if (c->workerStop) break;
        const LONG gen = InterlockedCompareExchange(&c->workGen, 0, 0);
        if (gen == lastGen) {
            // 无新块：阻塞等事件（manual-reset，RT 发布时 Set、fan-in 后
            // Reset）。1s 超时只为兜底检查 workerStop。
            if (WaitForSingleObject(c->workerWake, 1000) != WAIT_OBJECT_0) {
                if (c->workerStop) break;
            }
            continue;
        }
        lastGen = gen;
        // 块快照（gen 屏障后就绪；binaural/testKind 必须与 RT 预填同口径）。
        auto* ab = (VbAudioBuffer*)c->curAb;
        const long n = c->curN;
        const long mask = c->curMask;
        const bool haveEng = c->curHaveEng != 0;
        const bool binaural = c->curBinaural != 0;
        const long testKind = c->curTestKind;
        const LONG testRdy = InterlockedCompareExchange(&c->testReady, 0, 0);
        for (;;) {
            const LONGLONG cur =
                InterlockedCompareExchange64(&c->workClaimPacked, 0, 0);
            if ((LONG)(cur >> 32) != gen) break;  // 块已轮换：重取快照
            const LONG bm = (LONG)(cur & 0xFFFFFFFFLL);
            if (!bm) break;
            const LONG bit = bm & (~bm + 1);
            const LONGLONG next = ((LONGLONG)gen << 32) |
                                  (LONGLONG)(uint32_t)(bm & ~bit);
            if (InterlockedCompareExchange64(&c->workClaimPacked, next, cur) !=
                cur)
                continue;
            int g = 0;
            for (LONG b = bit; !(b & 1); b >>= 1) ++g;
            ProcessGroupVm(c, ab, g, n, mask, haveEng, binaural, testKind,
                           (testRdy & bit) != 0);
            VmWorkComplete(c, gen, bit);
        }
    }
    return 0;
}

// Z17：worker 池生命周期（桥主线程调用；RT 只碰发布三件套）。
// 单核/建池失败 → parallelOn 保持 0，泵走串行（scratchInG 已分配则保留——
// 串行路径也用每组独占 scratch，见 ProcessGroupVm）。
inline void VmParallelShutdown(PumpCtx* c);

inline bool VmParallelInit(PumpCtx* c) {
    if (!c) return false;
    if (c->nWorkers > 0) return true;
    // per-group scratch（串/并行都用；RT 禁分配，主线程一次性建）
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (c->scratchInG[g]) continue;
        c->scratchInG[g] = (float*)malloc(sizeof(float) * 8 * kMaxNbs);
        c->scratchOutG[g] = (float*)malloc(sizeof(float) * 8 * kMaxNbs);
        if (!c->scratchInG[g] || !c->scratchOutG[g]) {
            // 不回收已分配的：串行路径可回退共享 scratch（par 判定按组检查
            // 齐备性，缺槽的组不会进并行）；统一回收只发生在显式 Shutdown。
            return false;
        }
    }
    // 逃生阀：环境变量强制串行（A/B 对账/排障用）
    const char* env = getenv("AURA_VM_PARALLEL");
    if (env && env[0] == '0') return false;
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    int want = (int)si.dwNumberOfProcessors - 1;  // RT 线程自占一核
    if (want > PumpCtx::kMaxGroups - 1) want = PumpCtx::kMaxGroups - 1;
    if (want < 1) return false;  // 单核：并行无收益（scratch 已留，串行照用）
    c->workerWake = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!c->workerWake) return false;
    int made = 0;
    for (int i = 0; i < want; ++i) {
        HANDLE h = CreateThread(nullptr, 0, VmWorkerMain, c, 0, nullptr);
        if (!h) break;
        c->workerThreads[made++] = h;
    }
    c->nWorkers = made;
    if (made == 0) {
        CloseHandle(c->workerWake);
        c->workerWake = nullptr;
        return false;
    }
    InterlockedExchange(&c->parallelOn, 1);
    return true;
}

inline void VmParallelShutdown(PumpCtx* c) {
    if (!c) return;
    InterlockedExchange(&c->parallelOn, 0);
    // 等在途块结束（含 fan-in：worker 持引擎句柄 process，绝不在销毁句柄
    // 途中还有 worker 在跑）
    for (int i = 0; i < 3000; ++i) {
        if (InterlockedCompareExchange(&c->rtInBlock, 0, 0) == 0) break;
        Sleep(1);
    }
    InterlockedExchange(&c->workerStop, 1);
    if (c->workerWake) SetEvent(c->workerWake);
    const int nw = c->nWorkers;
    if (nw > 0) {
        WaitForMultipleObjects((DWORD)nw, c->workerThreads, TRUE, 3000);
        for (int i = 0; i < nw; ++i) {
            CloseHandle(c->workerThreads[i]);
            c->workerThreads[i] = nullptr;
        }
    }
    c->nWorkers = 0;
    // B2：清并行协议残留（straggler 冻结位 / 待发布账 / 完成位图），便于
    // 后续 VmParallelInit 干净重来。被 join 超时遗弃的 worker 若仍在引擎内，
    // 它清的是一个已作废的位（对协议无害）；"worker 永世不返回时销毁引擎
    // 句柄"是既有残余（in-process 插件的固有面），B2 不改变该面。
    InterlockedExchange(&c->workStuck, 0);
    InterlockedExchange64(&c->workDonePacked, 0);
    c->curTodo = 0;
    if (c->workerWake) {
        CloseHandle(c->workerWake);
        c->workerWake = nullptr;
    }
    InterlockedExchange(&c->workerStop, 0);
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        free(c->scratchInG[g]);
        c->scratchInG[g] = nullptr;
        free(c->scratchOutG[g]);
        c->scratchOutG[g] = nullptr;
    }
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
