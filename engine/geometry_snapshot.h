#pragma once

#include <atomic>
#include <cstdint>

namespace auradsp_detail {

struct PendingGeometrySnapshot {
    uint64_t generation = 0;
    int32_t channels = 0;
    int32_t mode = 0;
};

/* RT 快照读取。测试回调只用于确定性地在两次读取之间插入控制侧发布；
 * 生产重载不执行回调，不做分配、锁、IO 或等待。 */
template <typename AfterGeneration>
inline bool load_pending_geometry_snapshot(
    const std::atomic<uint64_t>& pending_generation,
    const std::atomic<int32_t>& pending_channels,
    const std::atomic<int32_t>& pending_mode,
    PendingGeometrySnapshot* out,
    AfterGeneration&& after_generation) {
    const uint64_t generation =
        pending_generation.load(std::memory_order_acquire);
    if (generation == 0) return false;
    after_generation();
    const int32_t channels = pending_channels.load(std::memory_order_relaxed);
    const int32_t mode = pending_mode.load(std::memory_order_relaxed);
    if (pending_generation.load(std::memory_order_acquire) != generation) {
        return false;
    }
    out->generation = generation;
    out->channels = channels;
    out->mode = mode;
    return true;
}

inline bool load_pending_geometry_snapshot(
    const std::atomic<uint64_t>& pending_generation,
    const std::atomic<int32_t>& pending_channels,
    const std::atomic<int32_t>& pending_mode,
    PendingGeometrySnapshot* out) {
    return load_pending_geometry_snapshot(
        pending_generation, pending_channels, pending_mode, out, [] {});
}

}  // namespace auradsp_detail
