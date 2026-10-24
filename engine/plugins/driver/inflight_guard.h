#pragma once
// RT 临界区守卫与排空上限。只依赖 std::atomic，不含格式/平台头。

#include <atomic>
#include <cstdint>

namespace auradsp {

/* RT 临界区守卫：进入时已由调用方 fetch_add(acq_rel) 计入 inFlight，
 * 析构时递减；若是最后一个离开者且控制线程正在等排空，则唤醒它。
 * 唤醒带 pend 检查，避免每块都触发一次无谓的 futex/WaitOnAddress 系统调用。
 *
 * B3（2026-10-24）：递减改饱和 CAS。控制线程判定「RT 异常滞留」后会把计数
 * 清零并把实例移入隔离区；滞留线程稍后退出时若仍 fetch_sub，会从 0 下溢到
 * 0xFFFFFFFF，此后该槽每次卸载都误判滞留、反复隔离新实例。为 0 即视为
 * 「已被放弃」，不再递减。 */
struct InFlightGuard {
    std::atomic<uint32_t>& counter;
    std::atomic<bool>& pending;
    InFlightGuard(std::atomic<uint32_t>& c, std::atomic<bool>& p) : counter(c), pending(p) {}
    ~InFlightGuard() {
        uint32_t v = counter.load(std::memory_order_relaxed);
        for (;;) {
            if (v == 0) return;  // 控制线程已放弃本槽（隔离路径清零）：绝不下溢
            if (counter.compare_exchange_weak(v, v - 1, std::memory_order_release,
                                              std::memory_order_relaxed)) {
                if (v == 1 && pending.load(std::memory_order_relaxed)) {
                    counter.notify_all();
                }
                return;
            }
        }
    }
    InFlightGuard(const InFlightGuard&) = delete;
    InFlightGuard& operator=(const InFlightGuard&) = delete;
};

/* 控制线程等待 RT 排空的上界（B3 收口）。
 * 语义：先无系统调用地快自旋 kQuiesceSpinLimit 转（覆盖「恰好退出」的快路径），
 * 再按 GetTickCount64 墙钟 Sleep(1) 轮询到 kQuiesceWaitMs。
 * 为什么不能用 atomic::wait 做上界：wait(old) 只在「当前值 == old」时阻塞，
 * 没有超时参数——用 wait(0) 配非零计数是立即返回（等于没等），用 wait(当前值)
 * 则 RT 真挂死时把控制线程永久挂住。故一律墙钟收敛。
 * 超过上界视为「RT 线程异常滞留」（插件在 process 内死锁 / 音频线程被终止）：
 * 此时选择保留实例（调用方移入隔离区）而不是冒险释放——硬清零计数后照常
 * 销毁就是 use-after-free，与本节契约相反。
 * 100ms 覆盖到 kMaxNbs=4096 @44.1k 的大块（≈93ms），正常卸载几条块内即返回。 */
constexpr uint32_t kQuiesceSpinLimit = 4096;
constexpr uint32_t kQuiesceWaitMs = 100;

} // namespace auradsp
