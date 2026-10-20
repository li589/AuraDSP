#pragma once
// RT 临界区守卫与排空上限。只依赖 std::atomic，不含格式/平台头。

#include <atomic>
#include <cstdint>

namespace auradsp {

/* RT 临界区守卫：进入时已由调用方 fetch_add(acq_rel) 计入 inFlight，
 * 析构时递减；若是最后一个离开者且控制线程正在等排空，则唤醒它。
 * 唤醒带 pend 检查，避免每块都触发一次无谓的 futex/WaitOnAddress 系统调用。 */
struct InFlightGuard {
    std::atomic<uint32_t>& counter;
    std::atomic<bool>& pending;
    InFlightGuard(std::atomic<uint32_t>& c, std::atomic<bool>& p) : counter(c), pending(p) {}
    ~InFlightGuard() {
        if (counter.fetch_sub(1, std::memory_order_release) == 1 &&
            pending.load(std::memory_order_relaxed)) {
            counter.notify_all();
        }
    }
    InFlightGuard(const InFlightGuard&) = delete;
    InFlightGuard& operator=(const InFlightGuard&) = delete;
};

/* 控制线程等待 RT 排空的自旋上限。正常路径 0~1 次 wait 即返回；
 * 超过上限视为「RT 线程异常滞留」，此时选择保留实例而不是冒险释放。 */
constexpr uint32_t kQuiesceSpinLimit = 4096;

} // namespace auradsp
