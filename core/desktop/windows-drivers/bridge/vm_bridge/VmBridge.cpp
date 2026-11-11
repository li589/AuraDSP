// VmBridge.cpp — VB-Callback 持久桥实现。
//
// 线程模型（三线程，职责分离，沿用泵的无锁审计）：
// - VB RT 线程：OnVbCallback（零锁零分配；读 testKind/engines，只写自有计数）。
// - monitor 线程：CHANGE 重建（stop→rebuild→start）+ 退出事件等待。
// - Dart 线程：start/stop/set_param/test/viz/status（直接调，无一进 RT）。
// Login/Logout 与泵同式严格单次配对；OUT 槽被占（rc=1）直接返回 1 让 UI 提示。
#include "VmBridge.h"

#include "PluginBridge.h"
#include "VizSilence.h"
#include "../../02_voicemeeter_client/VmPumpCore.h"
#include "../../02_voicemeeter_client/VmRemoteLoader.h"

#include <cstdio>
#include <cstring>

#include <atomic>
#include <chrono>
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
using vmcore::FnEngAbi;
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
    int busMask = 0x03;  // 总线处理掩码（bit=组使能；出厂 A1/A2；memset 会清 ctx，session 级保管在此）
    long long gateSr = 0;  // P3：门控 hold 换算用的采样率（STARTING 迟到时 monitor 补配）
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
    // A1 关路后 eng[0] 为空：读操作/编辑器回落到第一个在用句柄，
    // 避免"关掉 A1 就再也读不到插件状态"（2026-11-07 懒建句柄）。
    if (g_b.ctx.nEng <= 0) return nullptr;
    if (g_b.ctx.eng[0]) return g_b.ctx.eng[0];
    for (int g = 1; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g]) return g_b.ctx.eng[g];
    }
    return nullptr;
}

static int PluginEngineCount() {
    return g_b.ctx.nEng;
}

static int LiveEngineCount() {
    int n = 0;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g]) ++n;
    }
    return n;
}

static int FirstLiveGroup() {
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g]) return g;
    }
    return -1;
}

static void* PluginEngineAt(int g) {
    return (g >= 0 && g < g_b.ctx.nEng) ? g_b.ctx.eng[g] : nullptr;
}

// 按路插件处理掩码（bit g = 组 g 吃插件链）。session 级保管于桥静态区
// （ctx 会被 memset，CHANGE 重建不丢，重建后经 ApplyPluginGroupMask 重放）。
// 出厂只勾 A1/A2；该掩码只决定"有实例的路是否参与插件处理"，不决定实例生死。
static volatile LONG g_pluginGroupMask = 0x03;

// 加载期平滑（2026-10-27）：后台补挂期间临时旁路全部已加载链。
// 实测 @128 帧：补挂第 2/3 个 Ozone 时在跑组 process 峰值 5-6ms（预算
// 2.67ms），每秒 15-20 块超预算；旁路后同窗口 0 超预算，恢复后无尖峰。
// 只在预算紧张（<8ms）且已有实例在跑时启用；恢复走 ApplyPluginGroupMask，
// 用户掩码 / Z12 保护态原样重放，不记忆也不覆盖用户开关。
static volatile LONG g_loadSuspending = 0;  // 1 = 补挂批次进行中（链全旁路）

// ---- Z12 超预算自动保护（2026-10-23）--------------------------------------
// 症状：Ozone 12 级重插件逐组串行（每实例 ~0.76ms 均 / 2.33ms 峰 @128 帧），
// N≥2 组即超预算（128 帧 @48k = 2.67ms）→ VM 回调持续欠载 → 必卡。
// 机制：RT 回调尾部只写观测值（cbEmaUs/cbOverStreak，纯整数零等待）；
// 后台补齐线程兼职守卫（500ms 轮询 ProtectTick）——超预算持续 ~170ms 即把
// 有效掩码收窄到最热组（viz 跟随 = 用户大概率监听的总线），EMA 回落到 50%
// 预算以下持续 6s 自动恢复用户掩码。用户手动改掩码 / 关保护立即让位。
// 语义代价：保护期非热组插件链旁通（该总线直通，厂商 DSP 照常）——好于全
// 总线爆音。单组版面 / 引擎无链开关时守卫自动失效。
static volatile LONG g_autoProtect = 1;        // 用户开关（vb_plugin_auto_protect）
static volatile LONG g_protectActive = 0;      // 1 = 已收窄到热组
static volatile LONG g_protectHot = 0;         // 保护期放行的组
static volatile LONG g_protectUnderWakes = 0;  // EMA<50% 连续轮询计数
static volatile LONG g_protectManualAt = 0;    // 用户手动改掩码时刻（秒，冷却用）
static const LONG kProtectEnterStreak = 64;    // 连续超限块数（@48k/128 ≈ 170ms）
static const LONG kProtectEnterPct = 85;       // 进入阈值（EMA/预算 %）
static const LONG kProtectExitWakes = 12;      // 12 × 500ms = 6s 低于 50% 才恢复

// 把掩码下发到全部组引擎（引擎链级开关，原子布尔，RT 安全）。
// 引擎 DLL 无链开关符号（旧版本）时静默跳过——掩码仍被记录，
// 升级引擎后自然生效。不在 RT 线程调用（控制线程语义）。
// Z12：自动保护激活时**有效掩码**收窄为仅热组（用户掩码 plugMask 原样保留，
// 恢复即重放，不需要记住"保护前"状态）。
// 该组插件集是否装载完成（前台同步 + 后台补齐）。
// 未完成 → 链保持关闭：音频只走厂商 DSP，绝不混入"半套插件"的加工程度。
static bool PluginsReadyForGroup(int g);
// 该组是否有装载失败/超时缺口：有则链必须保持关闭（不放半套插件进处理）。
static bool GroupHasLoadFailure(int g);

static void ApplyPluginGroupMask() {
    if (!g_pluginFns.HasChainEnable()) return;
    int eff = InterlockedCompareExchange(&g_pluginGroupMask, 0, 0);
    if (InterlockedCompareExchange(&g_protectActive, 0, 0)) {
        eff = 1 << InterlockedCompareExchange(&g_protectHot, 0, 0);
    }
    // 加载期：全部链旁路。Ozone 初始化与在跑实例争用会令 process 峰值
    // 冲到 5-6ms；旁路让 RT 只做透传，补挂结束后由 EndLoadSuspension
    // 清除标记并重放用户/保护掩码。
    if (InterlockedCompareExchange(&g_loadSuspending, 0, 0)) eff = 0;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        void* e = g_b.ctx.eng[g];
        if (!e) continue;
        // 插件没装完/装失败/超时的组不开链：新开一路时先直通，装载完成才进处理。
        const int on = ((eff >> g) & 1) && PluginsReadyForGroup(g) &&
                      !GroupHasLoadFailure(g);
        g_pluginFns.chainSetEnabled(e, on);
    }
}

// 引擎构建点调用：观测基准重算 + 保护态作废（热组/句柄可能已变）。
static void InitProtectObs() {
    LARGE_INTEGER qpf;
    g_b.ctx.qpfInvUs =
        (QueryPerformanceFrequency(&qpf) && qpf.QuadPart > 0)
            ? 1000000.0 / (double)qpf.QuadPart
            : 0.0;
    InterlockedExchange(&g_b.ctx.cbEmaUs, 0);
    InterlockedExchange(&g_b.ctx.cbOverStreak, 0);
    InterlockedExchange(&g_b.ctx.protectTestMode, 0);
    InterlockedExchange(&g_protectActive, 0);
    InterlockedExchange(&g_protectUnderWakes, 0);
    InterlockedExchange(&g_loadSuspending, 0);
}

// 守卫一次轮询（后台补齐线程调用，非 RT）。所有引擎/链操作都在本线程，
// RT 路径零新增成本。
static void ProtectTick() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return;
    // 加载旁路期观测不代表真实负载（旁路本身就是 0.02ms 级透传），
    // 不参与保护状态机，避免无谓进入/退出。
    if (InterlockedCompareExchange(&g_loadSuspending, 0, 0)) return;
    if (g_b.ctx.nEng <= 1) return;  // 单组无从收窄
    // 句柄按路懒建：nEng 是版型槽数，实际在用句柄另计。
    if (LiveEngineCount() <= 1) return;
    if (!g_pluginFns.HasChainEnable()) return;
    const long sr = g_b.ctx.sr, nbs = g_b.ctx.nbs;
    if (sr <= 0 || nbs <= 0) return;
    const long budgetUs = (long)((double)nbs * 1000000.0 / (double)sr);
    const long ema = g_b.ctx.cbEmaUs;
    const long streak = g_b.ctx.cbOverStreak;
    if (InterlockedCompareExchange(&g_protectActive, 0, 0)) {
        if (ema * 100 < budgetUs * 50) {
            if (InterlockedIncrement(&g_protectUnderWakes) >=
                kProtectExitWakes) {
                InterlockedExchange(&g_protectActive, 0);
                InterlockedExchange(&g_protectUnderWakes, 0);
                ApplyPluginGroupMask();  // 恢复用户掩码
            }
        } else {
            InterlockedExchange(&g_protectUnderWakes, 0);
        }
        return;
    }
    if (!InterlockedCompareExchange(&g_autoProtect, 0, 0)) return;
    const ULONGLONG nowS = GetTickCount64() / 1000ULL;
    if ((LONG)(nowS & 0x7FFFFFFF) - InterlockedCompareExchange(
                                            &g_protectManualAt, 0, 0) < 60)
        return;  // 用户手动接管后的 60s 冷却
    if (streak < kProtectEnterStreak || ema * 100 <= budgetUs * kProtectEnterPct)
        return;
    int hot = g_b.ctx.vizStick;
    if (hot < 0 || hot >= g_b.ctx.nEng) hot = 0;
    InterlockedExchange(&g_protectHot, hot);
    InterlockedExchange(&g_protectActive, 1);
    InterlockedExchange(&g_protectUnderWakes, 0);
    ApplyPluginGroupMask();
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
    int group = -1;  // >=0 = 只补这一组（开路/重建后按路补挂）；-1 = 全组
};
static std::deque<PendingGroupLoad> g_bgJobs;
// 后台正在装的 (组,槽)：用于去重——job 已出队但实例还没落位时，重复入队
// 会二次实例化（重插件多花 2-4s 且白占内存）。-1 = 空闲。
static std::atomic<int> g_bgActiveGroup{-1};
static std::atomic<int> g_bgActiveSlot{-1};

static void BeginBgActive(int g, int slot) {
    g_bgActiveGroup.store(g, std::memory_order_release);
    g_bgActiveSlot.store(slot, std::memory_order_release);
}
static void EndBgActive() {
    g_bgActiveSlot.store(-1, std::memory_order_release);
    g_bgActiveGroup.store(-1, std::memory_order_release);
}

// 引擎级互斥：后台补齐与 unload/同步 load 不得并发碰同一组引擎。
static std::mutex g_engineMut;

// 每组已加载槽位位图（bit slot）：判定该组是否就绪（决定预设即时应用还是
// 挂起）；由同步加载、后台补齐、卸载共同维护。
static std::atomic<uint32_t> g_grpLoaded[PumpCtx::kMaxGroups];

// 加载终态兜底（2026-11-07 真机反馈：路行永久停在"加载中"、永不收敛）。
// 旧判据只有"已加载位图"，任何一次装载失败/漏调度都会让该组永远凑不齐：
//   - routeState 恒为 1（UI 一直转圈）；
//   - 插件链永不开启（插件静默失效）。
// 下面三组标记把"失败"也变成确定终态：failed 置位的槽位视为已结算（不再等），
// 该组判"失败·直通"；超时（kRouteSettleMs）未集齐同样判失败，绝不允许无限挂起。
static std::atomic<uint32_t> g_grpFailed[PumpCtx::kMaxGroups];    // 装载失败槽位
static std::atomic<uint64_t> g_grpWaitAt[PumpCtx::kMaxGroups];   // 最近期望装载时刻(ms)
static std::atomic<bool> g_grpCreateFail[PumpCtx::kMaxGroups];   // 建引擎失败
static const uint64_t kRouteSettleMs = 20000;

// 清掉该路的失败/超时/建引擎失败标记（开路、建成功后调用）。
static void ClearGroupLoadFlags(int g) {
    if (g < 0 || g >= PumpCtx::kMaxGroups) return;
    g_grpFailed[g].store(0, std::memory_order_release);
    g_grpCreateFail[g].store(false, std::memory_order_release);
    g_grpWaitAt[g].store(0, std::memory_order_release);
}

// 该组是否有装载失败/建引擎失败（链必须保持关闭，避免"半套插件"）。
static bool GroupHasLoadFailure(int g) {
    if (g < 0 || g >= PumpCtx::kMaxGroups) return true;
    return g_grpCreateFail[g].load(std::memory_order_acquire) ||
           g_grpFailed[g].load(std::memory_order_acquire) != 0;
}

// 该路是否已到确定终态：全部集齐，或失败位已覆盖缺口，或已超时。
// routeState 的 1（加载中）只允许出现在这里返回 false 的窗口内。
static bool GroupRouteSettled(int g, uint64_t now) {
    const uint32_t want = g_pluginMirror.LoadedMask();
    const uint32_t got = g_grpLoaded[g].load(std::memory_order_acquire);
    const uint32_t failed = g_grpFailed[g].load(std::memory_order_acquire);
    if ((got & want) == want) return true;                // 集齐
    if (g_grpCreateFail[g].load(std::memory_order_acquire)) return true;
    if ((want & ~(got | failed)) == 0) return true;       // 缺口全部是失败槽
    const uint64_t at = g_grpWaitAt[g].load(std::memory_order_acquire);
    return at != 0 && now >= at && now - at >= kRouteSettleMs;  // 超时
}

// 路开关异步化（2026-11-07）：Dart 侧启停不得等待 g_engineMut——后台补挂
// 单实例要 2-4s，期间同步拿锁会让 UI 心跳停摆、后续命令排队。拿不到锁时
// 只置标记，由后台线程在下一个空闲窗口完成建/拆；mask 位已先切，RT 立刻
// 按新语义直通（关闭=直通、新建=句柄发布前直通），听感不受延迟影响。
static std::atomic<bool> g_grpKill[PumpCtx::kMaxGroups];    // 待拆
static std::atomic<bool> g_grpCreate[PumpCtx::kMaxGroups];  // 待建
// 处理待建/待拆（onlyGroup < 0 = 全部）。g_engineMut 内建/拆，锁外补挂。
static bool ProcessGroupLifecycle(int onlyGroup);

// 挂起预设：[group][slot] = 最近一次请求的路径；该组补齐后应用一次。
static std::mutex g_pendMutex;
static std::string g_pendPreset[PumpCtx::kMaxGroups][auraplugin::kSlots];
static bool g_pendHasPreset[PumpCtx::kMaxGroups][auraplugin::kSlots] = {};

// 该组是否需要持有插件实例 = 路开关（DSP）打开。
// 语义（2026-11-07 用户明确）：路开关决定实例生死；插件复选框只决定
// "有实例的路是否参与插件处理"（链开关），不决定实例是否存在。
// 路关掉时该组连引擎句柄一起释放（见 DestroyGroupEngine），所以这里
// 也是"实例范围"的唯一判据。VM 会把输入复制到全部总线：不为关掉的路
// 建实例是内存与回调 CPU 的核心杠杆。
static bool GroupNeedsPlugin(int g) {
    if (g < 0 || g >= PumpCtx::kMaxGroups) return false;
    const int bm = InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0);
    return ((bm >> g) & 1) != 0;
}

// 该路是否要"吃插件链"= 路开着 AND 该路插件复选框勾选。
// 复选框未勾选的路不预建插件实例（该路插件不参与处理，实例纯属浪费），
// 于是它没有可等的东西——routeState 应该瞬时就绪，不该出现"加载中"
// （2026-11-07 用户口径：无插件可加载的路连加载态都不该出现）。
// 之后勾选复选框会由 BackfillGroupsForMask 现场补挂（只加载、不卸载）。
static bool GroupWantsPluginChain(int g) {
    if (!GroupNeedsPlugin(g)) return false;
    const int pm = InterlockedCompareExchange(&g_pluginGroupMask, 0, 0);
    return ((pm >> g) & 1) != 0;
}

// 该组插件集是否装载完成：已挂载槽位全部落到该组引擎。
// 不吃插件链的路无需等待（返回 true），否则无插件的路会被错误地判成加载中。
static bool PluginsReadyForGroup(int g) {
    if (g < 0 || g >= PumpCtx::kMaxGroups) return false;
    if (!g_b.ctx.eng[g]) return false;
    if (!GroupWantsPluginChain(g)) return true;
    const uint32_t want = g_pluginMirror.LoadedMask();
    const uint32_t got = g_grpLoaded[g].load(std::memory_order_acquire);
    return (got & want) == want;
}

// ---- 加载期平滑（2026-10-27）---------------------------------------------
// 预算够宽时不必旁路：补挂尖峰实测 5-6ms，384 帧 @48k（8ms）以上已能吸收，
// 旁路只会白丢几秒插件音色。sr/nbs 未就绪（回调还没跑）时也不旁路——没有
// 音频在跑，本来就无抖动可言。
static bool LoadSuspensionUseful() {
    const long sr = g_b.ctx.sr, nbs = g_b.ctx.nbs;
    if (sr <= 0 || nbs <= 0) return false;
    const long budgetUs = (long)((double)nbs * 1000000.0 / (double)sr);
    return budgetUs > 0 && budgetUs < 8000;
}

// 是否有组已挂过插件（同步挂载时用于判断「在跑实例会被加载争用」）。
static bool AnyPluginLoaded() {
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_grpLoaded[g].load(std::memory_order_acquire) != 0) return true;
    }
    return false;
}

// 幂等：首个调用者置位并立即旁路全部链；已有旁路时不再重复下发。
static void BeginLoadSuspension() {
    if (!LoadSuspensionUseful()) return;
    if (InterlockedExchange(&g_loadSuspending, 1) == 0) ApplyPluginGroupMask();
}

// 队列排空才恢复。只在 worker / 无后台 job 的同步路径调用——后台 job 一旦
// 入队，恢复权归 worker（否则「worker 已取走 job、调用方却看到队列空」会把
// 旁路提前撤掉，正好赶上加载尖峰）。
static void EndLoadSuspensionIfIdle() {
    {
        std::lock_guard<std::mutex> lk(g_bgMutex);
        if (!g_bgJobs.empty()) return;
    }
    if (InterlockedExchange(&g_loadSuspending, 0)) ApplyPluginGroupMask();
}


// 后台补一个组：加载 → 镜像状态回放 → 挂起预设应用。
// 返回 true = 该组已就绪。
static bool LoadGroupForSlot(int g, int slot, const char* path, const char* id) {
    if (!path || !*path) return false;
    // 句柄必须在本互斥内读取：关路销毁会持同一把锁并置空指针，锁外取出的
    // e 可能在锁内已失效（UAF）。
    std::lock_guard<std::mutex> eng(g_engineMut);
    void* e = PluginEngineAt(g);
    if (!e) return false;
    // 不写镜像（SlotLoad 内部会把镜像改成引擎出厂态，这里改为直调 load）。
    // 加载前后各读一次镜像：加载那 2-4s 里用户可能改过旁路/阶段，以镜像
    // 最终值为准，避免"用户取消旁路、后台组却仍旁路"（只影响一组的错态）。
    int stage = 3, wantBypass = 1, wantCh = 0xFF;
    if (!g_pluginMirror.GetSlot(slot, &stage, &wantBypass, &wantCh)) {
        g_pluginMirror.SetLoad(slot, path, id ? id : "", stage, wantBypass,
                               wantCh);
    }
    if (g_pluginFns.load(e, slot, path, id ? id : "") != 1) {
        // 失败必须记成终态：否则该组永远"未集齐"——routeState 恒为 1，
        // UI 永久停在加载态，链也永不开启（2026-11-07 真机根因之一）。
        g_grpFailed[g].fetch_or(1u << slot, std::memory_order_acq_rel);
        return false;
    }
    g_pluginMirror.GetSlot(slot, &stage, &wantBypass, &wantCh);
    g_pluginFns.setChannels(e, slot, wantCh);
    g_pluginFns.setStage(e, slot, stage);
    g_pluginFns.setBypass(e, slot, wantBypass);
    std::string preset;
    {
        std::lock_guard<std::mutex> lk(g_pendMutex);
        if (g_pendHasPreset[g][slot]) {
            preset = g_pendPreset[g][slot];
            g_pendHasPreset[g][slot] = false;
        }
    }
    if (!preset.empty()) g_pluginFns.loadPreset(e, slot, preset.c_str());
    g_grpFailed[g].fetch_and(~(1u << slot), std::memory_order_acq_rel);
    g_grpLoaded[g].fetch_or(1u << slot);
    // 该组集齐后才允许开链（加载期间保持旁路，避免半套插件出声）。
    if (PluginsReadyForGroup(g)) ApplyPluginGroupMask();
    return true;
}

static void GroupLoadWorker() {
    for (;;) {
        PendingGroupLoad job;
        bool hasJob = false;
        {
            std::unique_lock<std::mutex> lk(g_bgMutex);
            // Z12：wait→wait_for(500ms)——本线程兼职超预算守卫（ProtectTick），
            // 空闲也要周期醒来；有 job 时照常即时处理，守卫不抢加载活。
            g_bgCv.wait_for(lk, std::chrono::milliseconds(500),
                            [] { return g_bgStop || !g_bgJobs.empty(); });
            if (g_bgStop) return;
            if (!g_bgJobs.empty()) {
                job = std::move(g_bgJobs.front());
                g_bgJobs.pop_front();
                hasJob = true;
            }
        }
        // 路开关的延迟结构动作（关路拆除/开路新建）优先：拿不到锁时压在
        // 这里做，Dart 侧命令不等锁（见 vb_set_bus_mask）。
        ProcessGroupLifecycle(-1);
        if (hasJob) {
            const bool suspend = LoadSuspensionUseful();
            if (suspend) BeginLoadSuspension();
            const int n = PluginEngineCount();
            HANDLE thr = GetCurrentThread();
            const int oldPrio = GetThreadPriority(thr);
            // 同同步路径：加载是重 IO/内存操作，压低本线程让 RT 回调优先。
            SetThreadPriority(thr, THREAD_PRIORITY_BELOW_NORMAL);
            if (job.group < 0) {
                for (int g = 1; g < n; ++g) {
                    if (g_bgGen.load(std::memory_order_acquire) != job.gen)
                        break;
                    if (!GroupWantsPluginChain(g)) continue;  // 关掉/不吃链的路不加载
                    // 同步加载可能已落在非 0 组（A1 关路时 syncG = 首个在用路）；
                    // 已加载的组别重复挂载（重复实例化浪费 2-4s 且白占内存）。
                    if (job.slot >= 0 &&
                        (g_grpLoaded[g].load(std::memory_order_acquire) &
                         (1u << job.slot)))
                        continue;
                    BeginBgActive(g, job.slot);
                    LoadGroupForSlot(g, job.slot, job.path.c_str(),
                                     job.id.c_str());
                    EndBgActive();
                }
            }
            // 单组任务（开一路/重建后按路补挂）：只碰目标组。
            if (job.group >= 0 &&
                g_bgGen.load(std::memory_order_acquire) == job.gen &&
                GroupWantsPluginChain(job.group) && job.slot >= 0 &&
                !(g_grpLoaded[job.group].load(std::memory_order_acquire) &
                  (1u << job.slot))) {
                BeginBgActive(job.group, job.slot);
                LoadGroupForSlot(job.group, job.slot, job.path.c_str(),
                                 job.id.c_str());
                EndBgActive();
                // 该组已集齐时 LoadGroupForSlot 内部会重放掩码。
            }
            SetThreadPriority(thr, oldPrio);
            if (suspend) EndLoadSuspensionIfIdle();
        }
        ProtectTick();
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
    // 兜底：worker 在 stop 前若卡在加载中，join 返回时批次已结束；清掉
    // 旁路标记并重放掩码（引擎此时仍有效，调用方随后才销毁）。
    if (InterlockedExchange(&g_loadSuspending, 0)) ApplyPluginGroupMask();
}

// 该 (组,槽) 是否已在队列里或正在后台装载（去重用）。
static bool BgJobInFlight(int g, int s);

// 掩码新使能的组：若镜像里已有插件、但该组实例尚缺（加载时被掩码跳过），
// 后台补挂——否则该总线只有厂商 DSP、插件永远不生效。
// added = 新使能位图；调用方保证与旧掩码已切换。
static void BackfillGroupsForMask(int added) {
    if (!added) return;
    std::vector<PendingGroupLoad> jobs;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (!((added >> g) & 1) || !PluginEngineAt(g) ||
            !GroupWantsPluginChain(g))
            continue;
        for (int s = 0; s < auraplugin::kSlots; ++s) {
            if (g_grpLoaded[g].load() & (1u << s)) continue;
            if (BgJobInFlight(g, s)) continue;
            char p[512] = {0};
            char id[128] = {0};
            int stage = 3, bypass = 1, ch = 0xFF;
            if (!g_pluginMirror.GetSlot(s, &stage, &bypass, &ch, p, sizeof(p), id,
                                        sizeof(id)) ||
                p[0] == '\0') {
                continue;
            }
            jobs.push_back(PendingGroupLoad{g_bgGen.load(), s, p, id, g});
        }
    }
    if (jobs.empty()) return;
    EnsureBgThread();
    const uint64_t now = GetTickCount64();
    {
        std::lock_guard<std::mutex> lk(g_bgMutex);
        for (auto& j : jobs) {
            // 已入队的同 (组,槽) 不重复（重复实例化白耗 2-4s 与内存）。
            bool dup = false;
            for (const auto& q : g_bgJobs) {
                if (q.group == j.group && q.slot == j.slot) { dup = true; break; }
            }
            if (dup) continue;
            g_grpWaitAt[j.group].store(now, std::memory_order_release);
            g_bgJobs.push_back(std::move(j));
        }
    }
    g_bgCv.notify_one();
}

// 该 (组,槽) 是否已在队列里或正在后台装载（去重用）。
static bool BgJobQueued(int g, int s) {
    std::lock_guard<std::mutex> lk(g_bgMutex);
    for (const auto& q : g_bgJobs) {
        if (q.group == g && q.slot == s) return true;
    }
    return false;
}
static bool BgJobInFlight(int g, int s) {
    if (g_bgActiveGroup.load(std::memory_order_acquire) == g &&
        g_bgActiveSlot.load(std::memory_order_acquire) == s)
        return true;
    return BgJobQueued(g, s);
}

// 按路补挂（2026-11-07）：某一路的引擎刚建好时，把镜像里已挂载的槽位
// 在该组实例化（后台线程，不阻塞开路命令；加载期间该路链保持关闭=直通）。
static bool EnqueueGroupLoads(int g) {
    if (g < 0 || g >= PumpCtx::kMaxGroups || !PluginEngineAt(g)) return false;
    // 不吃插件链的路没有可等的东西：不排队 = 该路瞬时就绪（无加载态）。
    if (!GroupWantsPluginChain(g)) return false;
    std::vector<PendingGroupLoad> jobs;
    const uint32_t gen = g_bgGen.load(std::memory_order_acquire);
    for (int s = 0; s < auraplugin::kSlots; ++s) {
        if (g_grpLoaded[g].load() & (1u << s)) continue;
        // 已在队列/正在装：不要再排（否则开关重复点击会二次实例化）。
        if (BgJobInFlight(g, s)) continue;
        char p[512] = {0};
        char id[128] = {0};
        int stage = 3, bypass = 1, ch = 0xFF;
        if (!g_pluginMirror.GetSlot(s, &stage, &bypass, &ch, p,
                                    sizeof(p), id, sizeof(id)) ||
            p[0] == '\0') {
            continue;
        }
        PendingGroupLoad job;
        job.gen = gen;
        job.slot = s;
        job.path = p;
        job.id = id;
        job.group = g;
        jobs.push_back(std::move(job));
    }
    if (jobs.empty()) return false;
    EnsureBgThread();
    {
        std::lock_guard<std::mutex> lk(g_bgMutex);
        for (auto& j : jobs) g_bgJobs.push_back(std::move(j));
    }
    // 记录"期望装载时刻"：超过 kRouteSettleMs 仍不集齐 → routeState 收敛为
    // 失败（直通），UI 的加载态绝不无限挂起。
    g_grpWaitAt[g].store(GetTickCount64(), std::memory_order_release);
    g_bgCv.notify_one();
    return true;
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

// 引擎工作声道数 = 泵的块步进数，channels.count 是唯一真相。二者一旦错位，
// auradsp_process 会按错误步长解释交织缓冲（8ch 缓冲喂给 2/4/6 档位 =
// 4×/2×/1.33× 速的持续断续）。只有全部 live handle 接受后才发布影子，
// 避免“部分引擎已换档、泵仍按旧档步进”的中间态。
int ApplyWorkChannels(FnEngSetParam setParam, int32_t requested) {
    if (!setParam) return 0;
    const int32_t ch = (requested == 4 || requested == 6 || requested == 8)
                           ? requested : 2;
    int ok = 0;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g] && setParam(g_b.ctx.eng[g], "channels.count", &ch,
                                       sizeof(ch)) == 0)
            ++ok;
    }
    // 懒建句柄后 nEng 是版型槽数，实际在用句柄按 live 计数比较。
    const int live = LiveEngineCount();
    if (live > 0 && ok == live) InterlockedExchange(&g_b.ctx.workCh, ch);
    return ok;
}

// 重建回放后把泵影子同步到镜像里的 channels.count（缺失/非法按 2）。
void SyncWorkChFromMirror(FnEngSetParam setParam) {
    int32_t ch = 2;
    for (int i = 0; i < g_mirrorN; ++i) {
        if (!g_mirror[i].isFloat &&
            strcmp(g_mirror[i].id, "channels.count") == 0) {
            ch = g_mirror[i].i;
            break;
        }
    }
    ApplyWorkChannels(setParam, ch);
}

void MirrorReplay(FnEngSetParam setParam) {
    if (!setParam || g_mirrorN <= 0) return;
    int ok = 0, bad = 0;
    for (int i = 0; i < g_mirrorN; ++i) {
        const MirrorEnt& e = g_mirror[i];
        // 脚本启用位留到代码回放之后（加载顺序：效果器 → 脚本编译 → 已应用
        // 才启用）。这里先跳过，由 ApplyLiveprogEnableAll 收尾。
        if (strcmp(e.id, "liveprog.enable") == 0) continue;
        const void* v = e.isFloat ? (const void*)&e.f : (const void*)&e.i;
        bool all = LiveEngineCount() > 0;
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            if (!g_b.ctx.eng[g]) continue;  // 关掉的路没有句柄
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
    if (!setParam || g_strMirrorN <= 0) return 0;
    int ok = 0;
    for (int i = 0; i < g_strMirrorN; ++i) {
        const StrMirrorEnt& e = g_strMirror[i];
        bool all = LiveEngineCount() > 0;
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            if (!g_b.ctx.eng[g]) continue;
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
    // Z17：确定性等在途 BUFFER_OUT 块结束（含并行 fan-in——worker 持句柄
    // process）。原 Sleep(50) 余量在重载下可能不够（块墙钟随插件成本涨），
    // 已是 rtInBlock 轮询；D2 起改用共用 WaitRtDrained：**按墙钟** 3s 上界。
    // 原 `for (i<3000) Sleep(1)` 名义 3s，实际因 Sleep(1) 粒度 5-15ms
    // 可拖到 15-45s——注释声称的上界从未成立。
    vmcore::WaitRtDrained(&g_b.ctx.rtInBlock);
    // 与按路建/销串行：Dart 线程的 vb_set_bus_mask 可能同时在动单组句柄。
    std::lock_guard<std::mutex> eng(g_engineMut);
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g] && g_b.ctx.destroy) g_b.ctx.destroy(g_b.ctx.eng[g]);
        g_b.ctx.eng[g] = nullptr;
        g_grpLoaded[g].store(0);
        ClearGroupLoadFlags(g);
        // P3：句柄销毁后门控状态一并作废（避免下次 start 沿用旧 gated）。
        g_b.ctx.gate[g].Reset();
        g_b.ctx.gate[g].enabled = false;
    }
    g_b.ctx.nEng = 0;
    // 引擎全拆：作废按路生命周期待办（重建后按新 mask 重新判定）。
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        g_grpKill[g].store(false);
        g_grpCreate[g].store(false);
    }
}

// P3 静音门控：逐组配置（控制线程）。采样率未由 STARTING 送达时按 48k 配
// hold（初始引擎同样固定 48k 建），CHANGE 重建会用实际 sr 重新配置。
// 没有引擎的组保持禁用——没有 DSP 可跳，门控无意义。
void ConfigureGates(long long sr) {
    g_b.gateSr = sr > 0 ? sr : 48000;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g]) {
            g_b.ctx.gate[g].Configure(sr > 0 ? sr : 48000);
        } else {
            g_b.ctx.gate[g].Reset();
            g_b.ctx.gate[g].enabled = false;
        }
    }
}

// 重建/开路后把插件镜像回放到"在用且路开关打开"的组。
// 顺序（用户明确 2026-11-07）：效果器参数 → 脚本 → 插件。
// 调用点必须在 MirrorReplay/StrMirrorReplay 之后；本函数只做插件实例化。
void ReplayPluginsForEnabledGroups() {
    if (!g_pluginFns.Ready()) return;
    // 逐槽回放并按槽更新"该组已加载位图"。旧实现只调 Replay 计数、不落位，
    // 于是 CHANGE 重建后每组都永远"未集齐"：routeState 恒为 1（UI 永久加载中）
    // 且插件链永不开启（插件静默失效）。这是 2026-11-07 真机反馈的根因之一。
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        void* e = g_b.ctx.eng[g];
        if (!e || !GroupNeedsPlugin(g)) continue;
        for (int s = 0; s < auraplugin::kSlots; ++s) {
            bool mounted = false;
            const bool ok = g_pluginMirror.ReplaySlot(e, g_pluginFns, s, &mounted);
            if (!mounted) continue;
            if (ok) {
                g_grpLoaded[g].fetch_or(1u << s, std::memory_order_acq_rel);
                g_grpFailed[g].fetch_and(~(1u << s), std::memory_order_acq_rel);
            } else {
                // 回放失败也是确定终态：记失败位，UI 显示"失败·直通"，不转圈。
                g_grpFailed[g].fetch_or(1u << s, std::memory_order_acq_rel);
            }
        }
        g_grpWaitAt[g].store(GetTickCount64(), std::memory_order_release);
    }
    // 新引擎出厂 = 链全开；按路掩码重放（未勾选组重新关闭）。
    // Z12：观测基准重算 + 保护态作废（热组/句柄已变）；守卫线程需在场
    // （与后台补齐同线程驱动），重建后 EnsureBgThread 补启。
    ApplyPluginGroupMask();
    EnsureBgThread();
}

// ---- 按路引擎生命周期（2026-11-07）---------------------------------------
// 路开关 = 绝对生命周期：关路销毁该组句柄（连带效果器/脚本/插件内存），
// 开路重建并按"效果器 → 脚本 → 插件"顺序恢复。
// 安全边界：先把 busMask 位清零（RT 新块不再进该组），再摘指针，等
// rtInBlock 归零与该组 workStuck 位清空，最后 destroy——RT 绝不触碰
// 已发布后被销毁的指针。等待期在控制线程，音频线程零成本。

// 只把一个句柄回放镜像（效果器参数；liveprog.enable 单独留到脚本之后）。
static void MirrorReplayOne(void* e, FnEngSetParam setP) {
    if (!e || !setP) return;
    for (int i = 0; i < g_mirrorN; ++i) {
        const MirrorEnt& m = g_mirror[i];
        if (strcmp(m.id, "liveprog.enable") == 0) continue;
        const void* v = m.isFloat ? (const void*)&m.f : (const void*)&m.i;
        setP(e, m.id, v, 4);
    }
}

// 脚本"已应用"位：只有用户点过"应用"（liveprog.enable=1）才回放为启用。
// 仅编译未应用的脚本不在这里被隐式启用（2026-11-07 用户明确）。
static void ApplyLiveprogEnable(void* e, FnEngSetParam setP) {
    if (!e || !setP) return;
    for (int i = 0; i < g_mirrorN; ++i) {
        if (!g_mirror[i].isFloat &&
            strcmp(g_mirror[i].id, "liveprog.enable") == 0) {
            int32_t on = g_mirror[i].i;
            setP(e, "liveprog.enable", &on, 4);
            return;
        }
    }
}

// CHANGE 重建路径：代码回放完成后，对全部在用句柄落"已应用"状态。
static void ApplyLiveprogEnableAll(FnEngSetParam setP) {
    if (!setP) return;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g]) ApplyLiveprogEnable(g_b.ctx.eng[g], setP);
    }
}

static bool CreateGroupEngineLocked(int g, float sr) {
    if (g < 0 || g >= PumpCtx::kMaxGroups) return false;
    if (g_b.ctx.eng[g]) {
        EnqueueGroupLoads(g);
        return true;
    }
    if (!g_b.create) {
        g_grpCreateFail[g].store(true, std::memory_order_release);
        return false;
    }
    auto setP = g_b.eng
                   ? (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param")
                   : nullptr;
    void* e = g_b.create(sr, 2048);
    if (!e) {
        // 建引擎失败也必须是确定终态：否则该路 mask 位在、句柄永空，
        // routeState 会永远停在 1（UI 无限转圈）。收敛为"失败·直通"。
        g_grpCreateFail[g].store(true, std::memory_order_release);
        return false;
    }
    // 全新句柄：无已装插件、无失败记录；装载等待窗口从此刻开始计（超时兜底）。
    g_grpCreateFail[g].store(false, std::memory_order_release);
    g_grpFailed[g].store(0, std::memory_order_release);
    g_grpWaitAt[g].store(GetTickCount64(), std::memory_order_release);
    // 1) 效果器：镜像里的启用状态逐条回放；关闭的效果器在引擎内直通。
    MirrorReplayOne(e, setP);
    // 2) 脚本：先编译代码；编译成功后才按"已应用"状态启用。
    for (int i = 0; i < g_strMirrorN; ++i) {
        const StrMirrorEnt& s = g_strMirror[i];
        if (setP) setP(e, s.id, s.text, (unsigned)s.bytes);
    }
    ApplyLiveprogEnable(e, setP);
    // 3) 插件由后台线程装载（重插件 2-4s，期间该路链关闭=直通）。
    // 参数/脚本就绪后才发布句柄：中途 RT 只看到 mask 位+空句柄 → 直通，
    // 绝不会拿到"参数还没回放"的出厂引擎。
    InterlockedExchangePointer((PVOID volatile*)&g_b.ctx.eng[g], e);
    ConfigureGates(g_b.gateSr);
    ApplyPluginGroupMask();  // 插件未齐 → 链保持关闭
    EnqueueGroupLoads(g);
    return true;
}

static void DestroyGroupEngineLocked(int g) {
    if (g < 0 || g >= PumpCtx::kMaxGroups) return;
    // 作废排队中的补齐任务（代际递增；在途任务会在引擎互斥上先完成）。
    g_bgGen.fetch_add(1, std::memory_order_acq_rel);
    // 卸载反向序（用户明确 2026-11-07）：先把该组已加载槽位全部内部旁路，
    // 再摘句柄销毁（destroy 即卸载实例）。调用方已先清 busMask 位，RT 新块
    // 不再进该组；旁路只为给"已进块"的最后一帧留出干净收尾，不制造爆音。
    if (g_b.ctx.eng[g] && g_pluginFns.setBypass) {
        const uint32_t loaded = g_grpLoaded[g].load(std::memory_order_acquire);
        for (int s = 0; s < auraplugin::kSlots; ++s) {
            if (loaded & (1u << s)) g_pluginFns.setBypass(g_b.ctx.eng[g], s, 1);
        }
    }
    void* e = InterlockedExchangePointer((PVOID volatile*)&g_b.ctx.eng[g],
                                         nullptr);
    g_grpLoaded[g].store(0);
    ClearGroupLoadFlags(g);
    g_b.ctx.gate[g].Reset();
    g_b.ctx.gate[g].enabled = false;
    g_b.ctx.idleSamples[g] = 0;
    g_b.ctx.idle[g] = false;
    g_b.ctx.peakGrp[g] = 0.0;
    g_b.ctx.sigMark[g] = 0;
    g_b.ctx.sigSame[g] = 0;
    if (!e) return;
    // mask 位已由调用方清零：等这一轮在途回调退出（新块不再进该组）。
    vmcore::WaitRtDrained(&g_b.ctx.rtInBlock);
    // 并行 fan-in 超时留下的 straggler 仍在引擎内：等它的 workStuck 位清零
    // （完成点在 ProcessGroupVm 完全返回之后）。上限 500ms；仍不归零则
    // 宁可不销毁（泄漏一个句柄）也不制造 UAF。
    bool stuck = false;
    for (int i = 0; i < 100; ++i) {
        stuck = ((InterlockedCompareExchange(&g_b.ctx.workStuck, 0, 0) >> g) &
                 1) != 0;
        if (!stuck) break;
        Sleep(5);
    }
    if (stuck) {
        snprintf(g_b.note, sizeof(g_b.note), "group%d-busy-leak", g);
        return;
    }
    if (g_b.ctx.destroy) g_b.ctx.destroy(e);
}

// 待建/待拆的执行体（后台线程空闲窗口）。mask 已由 vb_set_bus_mask 先切，
// 这里只做结构变更；锁内建/拆，锁外补挂与掩码重放。
// 关路：句柄在且在关 → DestroyGroupEngineLocked（卸载插件/效果器/脚本内存）。
// 开路：句柄缺且仍在开 → CreateGroupEngineLocked（回放效果器/脚本后再发布）。
static bool ProcessGroupLifecycle(int onlyGroup) {
    bool did = false;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (onlyGroup >= 0 && g != onlyGroup) continue;
        if (!g_grpKill[g].load(std::memory_order_acquire) &&
            !g_grpCreate[g].load(std::memory_order_acquire))
            continue;
        // 先消费标记：期间用户反向操作（关后又开）由下一次命令重新置位，
        // 这里按当前 mask 判定，绝不误拆正在用的路。
        const bool kill =
            g_grpKill[g].exchange(false, std::memory_order_acq_rel);
        const bool create =
            g_grpCreate[g].exchange(false, std::memory_order_acq_rel);
        bool touched = false;
        {
            std::lock_guard<std::mutex> eng(g_engineMut);
            if (kill && g_b.ctx.eng[g] && !GroupNeedsPlugin(g)) {
                DestroyGroupEngineLocked(g);
                touched = true;
            }
            if (create && !g_b.ctx.eng[g] && GroupNeedsPlugin(g) &&
                g < g_b.groupCount) {
                const float sr = (float)(g_b.ctx.sr > 0
                                             ? g_b.ctx.sr
                                             : g_b.gateSr > 0 ? g_b.gateSr
                                                              : 48000);
                // 失败已在 CreateGroupEngineLocked 内置 createFail 标记：
                // routeState 会收敛为"失败·直通"，不会永远停"创建中"。
                CreateGroupEngineLocked(g, sr);
                touched = true;
            }
        }
        if (touched) {
            EnqueueGroupLoads(g);   // 新建路的插件后台补挂（拆除路无句柄跳过）
            ApplyPluginGroupMask(); // 新句柄按"插件是否就绪"落链
            did = true;
        }
    }
    return did;
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
        // 懒建句柄：只为路开关打开的组建 DSP 链路（出厂 A1/A2）。
        // 关掉的路不建句柄 = 不占 DSP/效果器/脚本/插件内存；按需开路再建。
        std::lock_guard<std::mutex> eng(g_engineMut);
        const int bm = InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0);
        const int want = groups < PumpCtx::kMaxGroups ? groups
                                                     : PumpCtx::kMaxGroups;
        for (int g = 0; g < want; ++g) {
            if (((bm >> g) & 1) == 0) continue;
            g_b.ctx.eng[g] = g_b.create(sr, 2048);
            // 新句柄的装载等待窗口从此开始：超时（kRouteSettleMs）未集齐即
            // 判失败，routeState 不会永远停在"加载中"。
            if (g_b.ctx.eng[g]) {
                ClearGroupLoadFlags(g);
                g_grpWaitAt[g].store(GetTickCount64(), std::memory_order_release);
            } else {
                g_grpCreateFail[g].store(true, std::memory_order_release);
            }
        }
        // nEng 保留为"版型槽数"（0..want），稀疏句柄由各调用点跳过 nullptr。
        g_b.ctx.nEng = want;
    }
    if (LiveEngineCount() == 0 || !g_b.ctx.scratchIn || !g_b.ctx.scratchOut) {
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
    ConfigureGates((long long)(sr > 0.0f ? sr : 48000.0f));
    g_b.ctx.gotFirst = 0;
    // 观测基准重算 + 保护态作废（热组/句柄已变）。
    InitProtectObs();
    // 后台线程在 DestroyEngines 里被 Stop/join；重建后必须补启（守卫兼补挂）。
    EnsureBgThread();
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
        bool okAll = LiveEngineCount() > 0;
        if (strchr(vs, '.') || strchr(vs, 'e') || strchr(vs, 'E')) {
            const float f = (float)atof(vs);
            for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
                if (!g_b.ctx.eng[g]) continue;
                if (setParam(g_b.ctx.eng[g], id, &f, 4) != 0) {
                    okAll = false;
                    break;
                }
            }
        } else {
            const int32_t iv = (int32_t)atoi(vs);
            for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
                if (!g_b.ctx.eng[g]) continue;
                if (setParam(g_b.ctx.eng[g], id, &iv, 4) != 0) {
                    okAll = false;
                    break;
                }
            }
            if (okAll) {
                // 泵步进影子必须与引擎同值（channels.count 是唯一真相）。
                if (strcmp(id, "channels.count") == 0)
                    InterlockedExchange(&g_b.ctx.workCh,
                                        vmcore::NormalizeWorkCh(iv));
                else if (strcmp(id, "spatial.binaural") == 0)
                    InterlockedExchange(&g_b.ctx.spatialBinaural, iv ? 1 : 0);
                else if (strcmp(id, "spatial.enable") == 0)
                    InterlockedExchange(&g_b.ctx.spatialEnable, iv ? 1 : 0);
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
        // P3：STARTING 在 start 返回后送达真实采样率，hold=2000ms 需按它换算。
        // 只在变化时重配（控制线程；AURADSP_GATE 环境变量也只在这里读）。
        const long long liveSr = g_b.ctx.sr;
        if (liveSr > 0 && liveSr != g_b.gateSr) ConfigureGates(liveSr);
        if (InterlockedExchange(&g_b.ctx.pendingChange, 0) != 0) {
            // 重建窗口内帧计数本就不动，看门狗此时闭嘴（别把"重启中"判成"走了"）。
            lastFrames = g_b.ctx.frames;
            stillRounds = 0;
            ++g_b.ctx.changes;
            // RT-safe 重建序列：stop → 等在途块退出 → 销毁旧句柄（确认无回调
            // 在跑）→ start 等新 STARTING 取新采样率 → 重建 → 回放参数镜像。
            // D2：原为 Sleep(50) 余量（"应该够了吧"），改确定性排空。
            // 引擎只在本线程建/销；start 到重建完成之间 process==nullptr，泵退化为
            // 直通（不吞声、不吊野指针），绝不在音频线程 create/destroy。
            const long oldSr = g_b.ctx.sr;  // STARTING 迟到时的兜底，别退回 48k
            if (g_b.stop) g_b.stop();
            vmcore::WaitRtDrained(&g_b.ctx.rtInBlock);
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
                // 重试退避（非"等 RT 退出"）：VM 的 start 在设备重建期间会失败，
                // 20 次 × 50ms 共 1s 的退避窗口。D2 只收口"释放/销毁前等 RT"，
                // 本处保留固定间隔是刻意的——这里要的是让出时间给对方状态机。
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
                int sok = 0;
                {
                    // 控制侧结构互斥：与"关路销毁/插件后台补挂"串行，避免
                    // 本线程回放时句柄被另一线程拆掉（UAF）。
                    std::lock_guard<std::mutex> eng(g_engineMut);
                    MirrorReplay(setP);
                    SyncWorkChFromMirror(setP);
                    sok = StrMirrorReplay(
                        (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param"));
                    // 脚本先编译、后落"已应用"位（与开路路径同序：效果器 →
                    // 脚本 → 插件）。仅编译未应用（镜像无 enable=1）不会被
                    // 这里隐式启用。
                    ApplyLiveprogEnableAll(setP);
                    // 顺序收口：效果器（MirrorReplay）→ 脚本（StrMirrorReplay）
                    // → 插件实例化。插件最后装载，避免脚本编译与插件初始化争用。
                    ReplayPluginsForEnabledGroups();
                }
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
    // 先清 kind 让 RT 停用，再等**在途块退出**（D2：原为 Sleep(50) 猜测——
    // 重载时不够会 free 掉 RT 仍在读的缓冲，空闲时又白睡），最后释放。
    InterlockedExchange(&g_b.ctx.testKind, 0);
    if (!vmcore::WaitRtDrained(&g_b.ctx.rtInBlock)) {
        // 极端：3s 内 RT 没退出（驱动卡死）。free 会踩在途读 → 整块保留不释放
        //（与 B3 quarantine 同一哲学：可控泄漏换不可控崩溃）。
        return;
    }
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
    FnEngAbi engAbiFn = nullptr;
    unsigned engAbi = 0;
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
        // [PATCHED-AuraDSP P-028 §7-2] 引擎在位即强校验 ABI（缺符号同罪）；
        // 不符按引擎不可用降级透传——VM 桥无引擎本就合法，不比 ASIO/VAIO 硬失败。
        engAbiFn = (FnEngAbi)GetProcAddress(g_b.eng, "auradsp_abi");
        engAbi = engAbiFn ? engAbiFn() : 0;
        g_b.getParam =
            (FnEngGetParam)GetProcAddress(g_b.eng, "auradsp_get_param");
        g_pluginFns.Resolve(g_b.eng);
        const bool abiOk =
            engAbiFn && engAbi == vmcore::kEngineAbiExpected;
        if (abiOk && create && g_b.ctx.process && g_b.ctx.destroy) {
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
            // 出厂只建路开关打开的路（A1/A2 = 0x03）；其余按需开路再建。
            const int bm0 =
                InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0) & 0xFF;
            for (int g = 0; g < want; ++g) {
                if (((bm0 >> g) & 1) == 0) continue;
                g_b.ctx.eng[g] = create(sr0, 2048);
                if (g_b.ctx.eng[g]) {
                    ClearGroupLoadFlags(g);
                    g_grpWaitAt[g].store(GetTickCount64(),
                                         std::memory_order_release);
                } else {
                    g_grpCreateFail[g].store(true, std::memory_order_release);
                }
            }
            // nEng = 版型槽数（稀疏句柄由调用点跳过 nullptr）。
            g_b.ctx.nEng = want;
            if (!g_b.ctx.scratchIn || !g_b.ctx.scratchOut ||
                LiveEngineCount() == 0) {
                DestroyEngines();
                g_b.ctx.process = nullptr;
            }
        }
        if (!g_b.ctx.process) {
            if (engAbiFn && engAbi != vmcore::kEngineAbiExpected)
                snprintf(g_b.note, sizeof(g_b.note),
                         "engine-abi-mismatch: bridge=%u engine=%u",
                         vmcore::kEngineAbiExpected, engAbi);
            FreeLibrary(g_b.eng);
            g_b.eng = nullptr;
        }
    }
    // Z17：组间并行 worker 池（引擎就绪即建；回调尚未 start，worker 静默）。
    // 失败/单核/AURA_VM_PARALLEL=0 → parallelOn=0，泵走串行（逐位同义）。
    vmcore::VmParallelInit(&g_b.ctx);
    ApplyParamsString(params_json);
    if (g_b.start() != 0) {
        snprintf(g_b.note, sizeof(g_b.note), "start-failed");
        DestroyEngines();
        LeaveCtl(true);
        return -4;
    }
    // P3 静音门控：初始引擎已建（48k），此刻逐组启用；CHANGE 重建再按实际 sr。
    ConfigureGates((long long)(g_b.ctx.sr > 0 ? g_b.ctx.sr : 48000));
    g_b.monitor = CreateThread(nullptr, 0, MonitorProc, nullptr, 0, nullptr);
    InterlockedExchange(&g_b.running, 1);
    // 启动后应用按路插件掩码（新引擎出厂 = 链全开，会话掩码覆盖之）。
    // Z12：观测基准 + 守卫线程就位（守卫与后台补齐同线程，启动即需在岗）。
    InitProtectObs();
    EnsureBgThread();
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
    // Z17：先收 worker 池（内部等 RT 在途块归零——fan-in 期间 worker 持
    // 引擎句柄 process，绝不能在它们还在跑时销毁句柄），再销毁引擎。
    vmcore::VmParallelShutdown(&g_b.ctx);
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

// P3 收口：整桥静音判定——与 status 的 gated 同口径（所有已建引擎且门控启用
// 的组都 GATED/idle）。viz_read 用它决定是否补静音帧；status 仍需自行统计
// idleMs，故不合并。
static bool AllGroupsGated() {
    int groups = 0;
    int gated = 0;
    for (int g = 0; g < g_b.ctx.nEng && g < vmcore::PumpCtx::kMaxGroups; ++g) {
        const aurabridge::SilenceGate& gt = g_b.ctx.gate[g];
        if (!gt.enabled) continue;
        ++groups;
        if (gt.gated || g_b.ctx.idle[g]) ++gated;
    }
    return groups > 0 && gated == groups;
}

// GATED 后引擎不再产 viz 帧；整桥静音时由桥补合法静音帧（仅控制线程）。
static aurabridge::SilentVizEmitter g_silentViz;

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
    // Z12：预算（µs）与保护状态透出——UI 据此显示预算占用与保护横幅。
    long budgetUs = 0;
    if (g_b.ctx.sr > 0 && g_b.ctx.nbs > 0)
        budgetUs = (long)((double)g_b.ctx.nbs * 1000000.0 / (double)g_b.ctx.sr);
    const int protOn = InterlockedCompareExchange(&g_protectActive, 0, 0);
    // P3 门控遥测：整桥空闲 = 所有有引擎的组都 GATED（部分组有声时不降泵，
    // viz 照常跟热组）。idleMs 取各组 GATED 时长的最大值。
    int gateGroups = 0;
    int gateGated = 0;
    long long idleMs = 0;
    for (int g = 0; g < g_b.ctx.nEng && g < vmcore::PumpCtx::kMaxGroups; ++g) {
        const aurabridge::SilenceGate& gt = g_b.ctx.gate[g];
        if (!gt.enabled) continue;
        ++gateGroups;
        if (gt.gated || g_b.ctx.idle[g]) {
            ++gateGated;
            if (gt.gated && gt.IdleMs() > idleMs) idleMs = gt.IdleMs();
        }
    }
    const int gated = (gateGroups > 0 && gateGated == gateGroups) ? 1 : 0;
    // 按路状态（2026-11-07）：0=路关闭(直通)，1=加载中(直通)，2=就绪(处理中)，
    // 3=失败/超时(直通)。四态都必须能收敛：1 只允许出现在"还可能在等"的
    // 窗口内（GroupRouteSettled=false），集齐/失败/建引擎失败/20s 超时一律
    // 落到 2 或 3 —— UI 的加载动画只由 1 驱动，绝不允许无限挂住。
    char routeState[64] = {0};
    {
        int st[8] = {0};
        const int bm = InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0) & 0xFF;
        const uint64_t now = GetTickCount64();
        const uint32_t want = g_pluginMirror.LoadedMask();
        for (int g = 0; g < 8; ++g) {
            if (((bm >> g) & 1) == 0 || g >= g_b.groupCount) {
                st[g] = 0;  // 路关闭 / 版型无此槽位：不存在该路
                continue;
            }
            if (g_grpCreateFail[g].load(std::memory_order_acquire)) {
                st[g] = 3;  // 建引擎失败：不会再有句柄，直接终态
                continue;
            }
            if (!g_b.ctx.eng[g]) {
                // 句柄由 ProcessGroupLifecycle 延迟创建：没有插件可等（want=0）
                // 时不该显示加载中，就绪与否只取决于句柄何时发布；有插件可等
                // 则给 20s 窗口，超时按失败收敛。
                if (want == 0) st[g] = 2;
                else st[g] = GroupRouteSettled(g, now) ? 3 : 1;
                continue;
            }
            if (GroupHasLoadFailure(g)) {
                st[g] = 3;  // 已有槽装载失败：链保持关闭，终态“失败·直通”
                continue;
            }
            if (PluginsReadyForGroup(g)) {
                st[g] = 2;  // 集齐（含“不该吃链”→ 瞬时就绪）
            } else {
                st[g] = GroupRouteSettled(g, now) ? 3 : 1;
            }
        }
        snprintf(routeState, sizeof(routeState), "[%d,%d,%d,%d,%d,%d,%d,%d]",
                 st[0], st[1], st[2], st[3], st[4], st[5], st[6], st[7]);
    }
    int n = snprintf(out, (size_t)cap,
                     "{\"running\":%s,\"frames\":%llu,\"sr\":%ld,\"nbs\":%ld,"
                     "\"groups\":%d,\"handles\":%d,\"peakIn\":%.6f,"
                     "\"gated\":%d,\"idleMs\":%lld,"
                     "\"maxCbUs\":%.1f,\"startRc\":%d,\"note\":\"%s\","
                     "\"testKind\":%ld,\"bypass\":%ld,\"vizGrp\":%d,"
                     "\"changes\":%lld,\"mirrorN\":%d,\"busMask\":%d,\"grpLive\":%d,"
                     "\"protect\":%d,\"cbEmaUs\":%ld,\"budgetUs\":%ld,"
                     "\"hotGrp\":%d,\"plugMask\":%d,\"loadSuspend\":%d,"
                     "\"parallel\":%d,\"workers\":%d,"
                     "\"stuckG\":%ld,\"fanTimeouts\":%ld,"
                     "\"peakGrp\":%s,\"maxGroupUs\":%s,\"routeState\":%s,"
                     "\"edition\":%d,\"engine\":\"%s\"}",
                      InterlockedCompareExchange(&g_b.running, 0, 0) ? "true"
                                                                     : "false",
                      (unsigned long long)g_b.ctx.frames, g_b.ctx.sr,
                      g_b.ctx.nbs, g_b.ctx.groups, g_b.ctx.nEng, g_b.ctx.peakIn,
                      gated, idleMs,
                      cbUs, g_b.startRc, g_b.note, (long)g_b.ctx.testKind,
                      (long)g_b.ctx.userBypass, vizGrp,
                      (long long)g_b.ctx.changes, g_mirrorN + g_strMirrorN,
                      (int)(InterlockedCompareExchange(&g_b.ctx.busMask, 0, 0) &
                            0xFF),
                      liveMask,
                      protOn, g_b.ctx.cbEmaUs, budgetUs,
                      protOn ? InterlockedCompareExchange(&g_protectHot, 0, 0)
                             : -1,
                     InterlockedCompareExchange(&g_pluginGroupMask, 0, 0),
                     (int)InterlockedCompareExchange(&g_loadSuspending, 0, 0),
                     (int)(InterlockedCompareExchange(&g_b.ctx.parallelOn, 0, 0) &&
                           g_b.ctx.nWorkers > 0),
                     (int)g_b.ctx.nWorkers,
                     InterlockedCompareExchange(&g_b.ctx.workStuck, 0, 0),
                     InterlockedCompareExchange(&g_b.ctx.fanTimeouts, 0, 0),
                     peaks, maxG, routeState, g_b.edition, eng);
    // peakGrp 已在回调级衰减，此处不再动（避免与回调线程叠加衰减失真）。
    return (n >= 0 && n < cap) ? n : -1;
}

int vb_set_param(const char* id, int isFloat, const void* v4) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    if (!id || !v4 || !g_b.eng) return -2;
    auto setParam = (FnEngSetParam)GetProcAddress(g_b.eng, "auradsp_set_param");
    if (!setParam) return -3;
    // Z17：桥级开关（非引擎参数，不进 MirrorSet 回放；worker 池跨 CHANGE
    // 重建存活，无需回放）。语义同引擎 fan-out：返回生效的路数。
    if (!isFloat && strcmp(id, "parallel.enable") == 0) {
        const int on = *(const int32_t*)v4 ? 1 : 0;
        if (on && g_b.ctx.nWorkers == 0) vmcore::VmParallelInit(&g_b.ctx);
        InterlockedExchange(&g_b.ctx.parallelOn,
                            (on && g_b.ctx.nWorkers > 0) ? 1 : 0);
        return g_b.ctx.parallelOn ? LiveEngineCount() : 0;
    }
    // channels.count 走专用通道：归一化 → 全部 handle 生效 → 才更新泵影子。
    // 否则“引擎 4ch / 泵按 8ch 步进”会让输入帧率瞬间变成 2×，表现为持续哒哒。
    if (!isFloat && strcmp(id, "channels.count") == 0) {
        const int32_t ch = *(const int32_t*)v4;
        MirrorSet(id, false, &ch);
        return ApplyWorkChannels(setParam, ch);
    }
    MirrorSet(id, isFloat != 0, v4);  // 重建后要靠它回放
    int ok = 0;
    for (int g = 0; g < g_b.ctx.nEng; ++g) {
        if (g_b.ctx.eng[g] && setParam(g_b.ctx.eng[g], id, v4, 4) == 0) ++ok;
    }
    // 双耳是否真正生效由泵按“两个开关 && 工作声道数>=4”判定（与引擎同口径）。
    if (!isFloat && strcmp(id, "spatial.binaural") == 0)
        InterlockedExchange(&g_b.ctx.spatialBinaural, *(const int32_t*)v4 ? 1 : 0);
    else if (!isFloat && strcmp(id, "spatial.enable") == 0)
        InterlockedExchange(&g_b.ctx.spatialEnable, *(const int32_t*)v4 ? 1 : 0);
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
    // 否则重建后新句柄会被坏代码清空）。懒建句柄后按在用路数比较：
    // nEng 是版型槽数（含未开路），拿它比较会让镜像永远记不进去。
    if (ok > 0 && ok == LiveEngineCount())
        StrMirrorSet(id, utf8, bytes);
    return ok;
}

int vb_get_param(const char* id, int isFloat, void* out4) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    // A1 关路后 eng[0] 为空：读操作回落到第一个在用句柄（不再因关 A1 读不到）。
    void* e = PluginEngine();
    if (!id || !out4 || !g_b.getParam || !e) return -2;
    return g_b.getParam(e, id, out4, 4) == 0 ? 0 : -3;
}

int vb_get_param_str(const char* id, char* out, int cap) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    void* e = PluginEngine();
    if (!id || !out || cap <= 1 || !g_b.getParam || !e) return -2;
    out[0] = 0;
    if (g_b.getParam(e, id, out, (unsigned)cap) != 0) return -3;
    out[cap - 1] = 0;  // 引擎保证 NUL 结尾，这里再兜一层
    return (int)strlen(out);
}

int vb_test_change() {
    // 诊断/回归用：模拟一次 VM CHANGE（真实路径由 VB 推 kCbChange 置位同标志）。
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return -1;
    InterlockedExchange(&g_b.ctx.pendingChange, 1);
    return 0;
}

int vb_viz_read(void* out1600, int count) {
    if (!out1600 || count <= 0) return -1;
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (!g_b.vizRead) return 0;
    const int g = HottestVizGroup();
    if (!g_b.ctx.eng[g]) return 0;
    const int n = g_b.vizRead(g_b.ctx.eng[g], out1600, count);
    if (n > 0) return n;
    // P3 收口：门控 GATED 后桥不再调 process，引擎 ring 不再产帧。整桥静音
    // 时补一帧合法静音帧，UI 不再先冻结 1.5s 等 stale 兜底。旁路/测试注入
    // 期间门控不 Tick（gated 可能是旧值），一律不补。
    if (InterlockedCompareExchange(&g_b.ctx.userBypass, 0, 0)) return 0;
    if (InterlockedCompareExchange(&g_b.ctx.testKind, 0, 0) != 0) return 0;
    if (!AllGroupsGated()) return 0;
    // 静音帧的通道数必须与引擎工作声道数一致（否则 UI 表头在静音时跳变）。
    return g_silentViz.Emit(
        out1600, 0, vmcore::NormalizeWorkCh(g_b.ctx.workCh));
}

// §7-2（P-028）桥 ABI 协商：返回桥编译所依据的引擎 ABI 版本（viz 帧布局代际）。
unsigned vb_abi(void) { return vmcore::kEngineAbiExpected; }

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
    // 先切掩码：RT 新块立刻不再进即将被拆的组（关路语义的第一道闸）。
    g_b.busMask = mask;  // session 级保管（ctx 会被 memset，CHANGE 重建不丢）
    InterlockedExchange(&g_b.ctx.busMask, (LONG)mask);
    if (!g_b.create || !g_b.ctx.destroy) return mask;
    // 路开关 = 绝对生命周期：关 → 拆该组句柄（连带效果器/脚本/插件内存）；
    // 开 → 重建句柄并回放效果器/脚本，插件后台装载（期间该路直通）。
    const bool suspend = LoadSuspensionUseful() && AnyPluginLoaded();
    if (suspend) BeginLoadSuspension();
    const float sr =
        (float)(g_b.ctx.sr > 0 ? g_b.ctx.sr : g_b.gateSr > 0 ? g_b.gateSr : 48000);
    {
        // 不等待：后台补挂可能持锁 2-4s，等锁会让 Dart 侧命令与状态心跳
        // 一起停摆（用户实测体感问题）。try_lock 失败只置标记，交后台
        // 线程的空闲窗口完成；mask 已先切，RT 从下一个块起就按新语义
        // 直通，听感不因结构动作延后而变化。
        std::unique_lock<std::mutex> eng(g_engineMut, std::try_to_lock);
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            const int was = (oldBus >> g) & 1;
            const int now = (mask >> g) & 1;
            if (was == now) continue;
            const bool closing = was && !now;
            // 反向操作以最后一次命令为准：先清掉相反方向的待办。
            if (closing) {
                g_grpCreate[g].store(false);
                // 关路即释放：该路装载进度/失败/超时记录一并作废。
                ClearGroupLoadFlags(g);
            } else {
                g_grpKill[g].store(false);
                // 开路：重置终态标记并起算装载等待窗口（超时兜底从此刻计）。
                ClearGroupLoadFlags(g);
                g_grpWaitAt[g].store(GetTickCount64(), std::memory_order_release);
            }
            if (!eng.owns_lock()) {
                if (closing) {
                    g_grpKill[g].store(true);
                } else if (g < g_b.groupCount) {
                    // 版型不提供该总线时不建句柄（持久化掩码可能来自 Potato 会话）。
                    g_grpCreate[g].store(true);
                }
                continue;
            }
            // 快速路径（锁空闲）：当场建/拆，保持原有即时生效时序。
            if (closing) {
                g_grpKill[g].store(false);
                DestroyGroupEngineLocked(g);
            } else if (g < g_b.groupCount) {
                g_grpCreate[g].store(false);
                CreateGroupEngineLocked(g, sr);
            }
        }
    }
    // 锁被占：唤醒后台线程（它每 500ms 也会自行醒来兜底）。
    EnsureBgThread();
    // 拆/建路会递增代际，作废在途的后台补挂：按每组缺槽重新排队，避免
    // 其余在用路因漏槽而永远凑不齐（链一直关闭）。
    bool queued = false;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g] && EnqueueGroupLoads(g)) queued = true;
    }
    if (suspend && !queued) EndLoadSuspensionIfIdle();
    // 让新增组的链按"插件是否就绪"重新落位；去掉的组已无句柄。
    ApplyPluginGroupMask();
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
    if (!path || !*path) return 0;
    // 本次加载起，此前排队/在途的后台补齐一律作废（代际递增）。
    // 作废的槽位不会丢：下面的 EnqueueGroupLoads 按每组缺槽重新排队。
    g_bgGen.fetch_add(1, std::memory_order_acq_rel);
    // 加载前记下期望状态（阶段/旁路/声道）：SlotLoad 成功会改写镜像为引擎
    // 出厂态，所以先取、后落位、再写回镜像。新挂槽无记录 → 默认旁路。
    int stage = 3, wantBypass = 1, wantCh = 0xFF;
    g_pluginMirror.GetSlot(slot, &stage, &wantBypass, &wantCh);
    // 实例范围 = 路开关（2026-11-07）：没有在用路时只记镜像，零实例化。
    const int syncG = FirstLiveGroup();
    if (syncG < 0) {
        g_pluginMirror.SetLoad(slot, path, plugin_id, stage, wantBypass, wantCh);
        return 1;
    }
    // P2 防抖：加载是重 IO/内存操作，压低当前线程优先级，让 RT 回调
    // （Pro Audio）优先拿 CPU——消加载期抢核导致的断续。
    HANDLE thr = GetCurrentThread();
    int oldPrio = GetThreadPriority(thr);
    SetThreadPriority(thr, THREAD_PRIORITY_BELOW_NORMAL);
    // 同步加载第一个在用路（用户主监听/编辑器立即可用）；其余在用路后台补。
    const bool suspendSync = LoadSuspensionUseful() && AnyPluginLoaded();
    if (suspendSync) BeginLoadSuspension();
    int rc0 = 0;
    {
        std::lock_guard<std::mutex> eng(g_engineMut);
        // 句柄在锁内取：关路销毁同锁置空，锁外取会 UAF。
        void* syncE = PluginEngineAt(syncG);
        if (syncE && g_pluginFns.Ready()) {
            rc0 = g_pluginFns.load(syncE, slot, path,
                                   plugin_id ? plugin_id : "");
            if (rc0 == 1) {
                g_pluginFns.setChannels(syncE, slot, wantCh);
                g_pluginFns.setStage(syncE, slot, stage);
                g_pluginFns.setBypass(syncE, slot, wantBypass);
                // 镜像按"期望值"落位（新挂槽默认旁路），不跟引擎出厂态走。
                g_pluginMirror.SetLoad(slot, path, plugin_id, stage, wantBypass,
                                       wantCh);
            }
        }
    }
    SetThreadPriority(thr, oldPrio);
    if (rc0 != 1) {   // 首个在用组失败 = 整体失败（镜像未被改写）
        // 同步组失败记成终态：否则该路永远"未集齐"，routeState 恒为 1。
        g_grpFailed[syncG].fetch_or(1u << slot, std::memory_order_acq_rel);
        if (suspendSync) EndLoadSuspensionIfIdle();
        return 0;
    }
    g_grpFailed[syncG].fetch_and(~(1u << slot), std::memory_order_acq_rel);
    g_grpLoaded[syncG].fetch_or(1u << slot);
    g_grpWaitAt[syncG].store(GetTickCount64(), std::memory_order_release);
    // 新加载：该槽的挂起预设作废（旧请求属于上一次挂载）。
    {
        std::lock_guard<std::mutex> lk(g_pendMutex);
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g)
            g_pendHasPreset[g][slot] = false;
    }
    // 其余在用路（路开关打开）：后台按组补挂，期间那些路链保持关闭。
    // 不只补本次槽位——代际递增会作废在途的其它槽位补挂（用户连续挂两个
    // 插件时常见），这里按"每组缺哪些镜像槽位"重新排队，避免漏槽导致
    // 该组永远凑不齐、链永远关闭。
    bool queued = false;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (!g_b.ctx.eng[g] || !GroupNeedsPlugin(g)) continue;
        // 同步组只在"已集齐"时跳过：代际递增会作废该组此前排队的其它槽位，
        // 无条件跳过会让它永远缺槽（链永久关闭、该路一直直通）。
        // EnqueueGroupLoads 只排缺失槽位，不会重复实例化刚加载的那个。
        if (g == syncG && PluginsReadyForGroup(syncG)) continue;
        if (EnqueueGroupLoads(g)) queued = true;
    }
    // 有后台任务时恢复权归 worker（旁路撤得太早会正好撞上加载尖峰）。
    if (!queued && suspendSync) EndLoadSuspensionIfIdle();
    // 槽位状态变了：若首组已集齐则允许开链。
    if (PluginsReadyForGroup(syncG)) ApplyPluginGroupMask();
    return 1;
}

int vb_plugin_slot_unload(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    // 取消在途/排队中的后台补齐（代际递增），并与其互斥（不得并发碰引擎）。
    g_bgGen.fetch_add(1);
    // 卸载 teardown 同样是重操作；已有其它实例在跑时同样先旁路，避免
    // deactivate/destroy 与 RT process 争用（与 load 同源，实测同窗口）。
    const bool suspend = LoadSuspensionUseful() && AnyPluginLoaded();
    if (suspend) BeginLoadSuspension();
    // 同 load：卸载 teardown 也是重操作，降优先级护 RT。
    HANDLE thr = GetCurrentThread();
    int oldPrio = GetThreadPriority(thr);
    SetThreadPriority(thr, THREAD_PRIORITY_BELOW_NORMAL);
    {
        std::lock_guard<std::mutex> eng(g_engineMut);
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
            void* e = PluginEngineAt(g);
            if (!e) continue;
            // 卸载顺序（用户明确）：先内部旁路，再卸载实例——先切断处理，
            // 再 teardown，避免最后一个 buffer 处于半销毁状态而爆音。
            g_pluginFns.setBypass(e, slot, 1);
            auraplugin::SlotUnload(e, g_pluginFns, g_pluginMirror, slot);
        }
        // 没有任何在用路时也要清镜像（否则重开路会"复活"已删插件）。
        g_pluginMirror.SetUnload(slot);
    }
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        g_grpLoaded[g].fetch_and(~(1u << slot));
        // 该槽已卸载：其失败/超时记录一并清掉（不再计入该路的终态判定）。
        g_grpFailed[g].fetch_and(~(1u << slot), std::memory_order_acq_rel);
    }
    {
        std::lock_guard<std::mutex> lk(g_pendMutex);
        for (int g = 0; g < PumpCtx::kMaxGroups; ++g) g_pendHasPreset[g][slot] = false;
    }
    SetThreadPriority(thr, oldPrio);
    // 代际递增作废了在途的其它槽位补挂：按每组缺槽重新排队，否则被作废
    // 的槽位会让该组永远凑不齐（链一直关闭、该路一直直通）。
    bool queued = false;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (g_b.ctx.eng[g] && EnqueueGroupLoads(g)) queued = true;
    }
    // 队列里可能还有被代际作废的补挂 job——worker 逐个取走后才算排空；
    // 若此刻已空则立即恢复用户/保护掩码。
    if (suspend && !queued) EndLoadSuspensionIfIdle();
    ApplyPluginGroupMask();
    return 1;
}

int vb_plugin_slot_set_bypass(int slot, int bypass) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    // 槽旁路只是处理层开关（2026-11-07 用户明确）：任何情况下都不卸载实例。
    // 没有在用句柄时仅更新镜像（下次开路按该状态落位）。
    g_pluginMirror.SetBypass(slot, bypass ? 1 : 0);
    const int by = bypass ? 1 : 0;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        // 该组还没装完这个槽：不动引擎，装载收尾时会按镜像最新值落位。
        if (!(g_grpLoaded[g].load(std::memory_order_acquire) & (1u << slot)))
            continue;
        void* e = PluginEngineAt(g);
        if (!e) continue;
        g_pluginFns.setBypass(e, slot, by);
    }
    return 1;
}

int vb_plugin_slot_get_bypass(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    int by = 1;
    if (!g_pluginMirror.GetSlot(slot, nullptr, &by, nullptr)) return 0;
    if (!g_pluginFns.Ready()) return by;
    // 优先读"已装完该槽"的组；所有组都还在装载/未开路时回答镜像值。
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (!(g_grpLoaded[g].load(std::memory_order_acquire) & (1u << slot)))
            continue;
        void* e = PluginEngineAt(g);
        if (e) return g_pluginFns.getBypass(e, slot);
    }
    return by;
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
    int applied = 0;
    for (int g = 0; g < n; ++g) {
        void* e = PluginEngineAt(g);
        if (!e) continue;
        if (!g_pluginFns.loadPreset(e, slot, path)) return 0;
        ++applied;
    }
    return applied > 0 ? 1 : 0;
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
    // 镜像先行（无在用路时也只记状态，开路后按它落位）。
    g_pluginMirror.SetStage(slot, stage);
    const int n = PluginEngineCount();
    int applied = 0;
    for (int g = 0; g < n; ++g) {
        void* e = PluginEngineAt(g);
        if (!e) continue;
        auraplugin::SlotSetStage(e, g_pluginFns, g_pluginMirror, slot, stage);
        ++applied;
    }
    int st = 3, by = 0, ch = 0xFF;
    return (applied > 0 || g_pluginMirror.GetSlot(slot, &st, &by, &ch)) ? 1
                                                                        : 0;
}

int vb_plugin_slot_get_insert_stage(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 3;
    // 优先读"已装完该槽"的组；否则回答镜像（未开路/装载中）。
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (!(g_grpLoaded[g].load(std::memory_order_acquire) & (1u << slot)))
            continue;
        void* e = PluginEngineAt(g);
        if (e && g_pluginFns.Ready()) return g_pluginFns.getStage(e, slot);
    }
    int st = 3, by = 0, ch = 0xFF;
    return g_pluginMirror.GetSlot(slot, &st, &by, &ch) ? st : 3;
}

int vb_plugin_slot_set_channels(int slot, int channels) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    g_pluginMirror.SetChannels(slot, channels);
    const int n = PluginEngineCount();
    int applied = 0;
    for (int g = 0; g < n; ++g) {
        void* e = PluginEngineAt(g);
        if (!e) continue;
        auraplugin::SlotSetChannels(e, g_pluginFns, g_pluginMirror, slot,
                                    channels);
        ++applied;
    }
    int st = 3, by = 0, ch = 0xFF;
    return (applied > 0 || g_pluginMirror.GetSlot(slot, &st, &by, &ch)) ? 1
                                                                        : 0;
}

int vb_plugin_slot_get_channels(int slot) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0xFF;
    for (int g = 0; g < PumpCtx::kMaxGroups; ++g) {
        if (!(g_grpLoaded[g].load(std::memory_order_acquire) & (1u << slot)))
            continue;
        void* e = PluginEngineAt(g);
        if (e && g_pluginFns.Ready()) return g_pluginFns.getChannels(e, slot);
    }
    int st = 3, by = 0, ch = 0xFF;
    return g_pluginMirror.GetSlot(slot, &st, &by, &ch) ? ch : 0xFF;
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
    // Z12：用户手动接管——立即取消自动保护并冷却 60s（尊重手动意图，
    // 免守卫与用户来回拉扯）。掩码未变化（no-op）不算接管：进桥时的
    // 掩码同步、重复开关都不该把守卫挡在门外。
    if (mask != (int)oldMask) {
        if (InterlockedCompareExchange(&g_protectActive, 0, 0)) {
            InterlockedExchange(&g_protectActive, 0);
            InterlockedExchange(&g_protectUnderWakes, 0);
        }
        InterlockedExchange(&g_protectManualAt,
                            (LONG)(GetTickCount64() / 1000ULL));
    }
    ApplyPluginGroupMask();
    // 加速（2026-10-23）：新使能的组若已挂插件但该组实例尚缺（加载时被
    // 掩码跳过），后台补齐——否则该总线只有厂商 DSP、插件永远不生效。
    BackfillGroupsForMask(mask & ~(int)oldMask);
    return mask;
}

int vb_plugin_group_mask() {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0x03;
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

// ---- Z12 超预算自动保护：用户开关 + 测试注入口 ----
// on < 0 = 查询；否则置位。关闭时若保护已激活，立即恢复用户掩码。
int vb_plugin_auto_protect(int on) {
    if (on < 0) return InterlockedCompareExchange(&g_autoProtect, 0, 0);
    InterlockedExchange(&g_autoProtect, on ? 1 : 0);
    if (!on && InterlockedCompareExchange(&g_protectActive, 0, 0)) {
        InterlockedExchange(&g_protectActive, 0);
        InterlockedExchange(&g_protectUnderWakes, 0);
        ApplyPluginGroupMask();
    }
    return InterlockedCompareExchange(&g_autoProtect, 0, 0);
}

// 测试注入（smoke_vm_protect.py）：直接喂守卫观测值。protectTestMode=1 时
// RT 停更 cbEmaUs/cbOverStreak，守卫线程按注入值判定。overStreak < 0 =
// 退出测试模式并清零观测（恢复 RT 自更新）。须桥已 start。
int vb_protect_test(int emaUs, int overStreak) {
    if (!InterlockedCompareExchange(&g_b.running, 0, 0)) return 0;
    if (overStreak < 0) {
        InterlockedExchange(&g_b.ctx.protectTestMode, 0);
        InterlockedExchange(&g_b.ctx.cbEmaUs, 0);
        InterlockedExchange(&g_b.ctx.cbOverStreak, 0);
        return 1;
    }
    InterlockedExchange(&g_b.ctx.protectTestMode, 1);
    InterlockedExchange(&g_b.ctx.cbEmaUs, (LONG)emaUs);
    InterlockedExchange(&g_b.ctx.cbOverStreak, (LONG)overStreak);
    return 1;
}

// ---- P5 统一桥契约（ab_*）：旧前缀过渡转发，见 bridge/common/aurabridge.h ----
// VM 没有宿主专属启动参数，config_json 忽略（方案 §4.1 过渡期，保留一个版本）。
static int AbStartAdapt(const char* engine_dll, const char* params_json,
                        const char* config_json) {
    (void)config_json;
    return vb_start(engine_dll, params_json);
}
#define AB_LEGACY vb
#define AB_CAPS_JSON                     \
    "{\"bridge\":\"vm\",\"busGroups\":8," \
    "\"pluginGroups\":8,\"autoProtect\":true,\"gating\":true}"
#include "aurabridge_impl.h"
