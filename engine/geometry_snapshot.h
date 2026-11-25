#pragma once

#include <atomic>
#include <cstdint>
#include <limits>
#include <utility>

namespace auradsp_detail {

struct GeometrySnapshot {
    uint64_t generation = 0;
    int32_t channels = 0;
    int32_t mode = 0;
};

/* 完整几何快照协议。generation=0 是发布中哨兵；payload 与两次代号读取
 * 全部 seq_cst，避免 relaxed payload 在代号校验前后重排。写入方必须 begin →
 * 写 payload → finish，且 generation 不允许回绕，因而双读之间不存在 ABA。
 * RT 不重试、不循环等待；冲突块失败关闭并保留旧 active。 */
template <typename AfterGeneration>
inline bool load_geometry_snapshot(
    const std::atomic<uint64_t>& generation,
    const std::atomic<int32_t>& channels,
    const std::atomic<int32_t>& mode,
    GeometrySnapshot* out,
    AfterGeneration&& after_generation) {
    const uint64_t observed =
        generation.load(std::memory_order_seq_cst);
    if (observed == 0) return false;
    after_generation();
    const int32_t observed_channels =
        channels.load(std::memory_order_seq_cst);
    const int32_t observed_mode =
        mode.load(std::memory_order_seq_cst);
    if (generation.load(std::memory_order_seq_cst) != observed) {
        return false;
    }
    out->generation = observed;
    out->channels = observed_channels;
    out->mode = observed_mode;
    return true;
}

inline bool load_geometry_snapshot(
    const std::atomic<uint64_t>& generation,
    const std::atomic<int32_t>& channels,
    const std::atomic<int32_t>& mode,
    GeometrySnapshot* out) {
    return load_geometry_snapshot(
        generation, channels, mode, out, [] {});
}

template <typename AfterGeneration>
inline bool load_pending_geometry_snapshot(
    const std::atomic<uint64_t>& pending_generation,
    const std::atomic<int32_t>& pending_channels,
    const std::atomic<int32_t>& pending_mode,
    GeometrySnapshot* out,
    AfterGeneration&& after_generation) {
    return load_geometry_snapshot(
        pending_generation, pending_channels, pending_mode, out,
        std::forward<AfterGeneration>(after_generation));
}

inline bool load_pending_geometry_snapshot(
    const std::atomic<uint64_t>& pending_generation,
    const std::atomic<int32_t>& pending_channels,
    const std::atomic<int32_t>& pending_mode,
    GeometrySnapshot* out) {
    return load_geometry_snapshot(
        pending_generation, pending_channels, pending_mode, out);
}

template <typename AfterGeneration>
inline bool load_active_geometry_snapshot(
    const std::atomic<uint64_t>& active_generation,
    const std::atomic<int32_t>& active_channels,
    const std::atomic<int32_t>& active_mode,
    GeometrySnapshot* out,
    AfterGeneration&& after_generation) {
    return load_geometry_snapshot(
        active_generation, active_channels, active_mode, out,
        std::forward<AfterGeneration>(after_generation));
}

inline bool load_active_geometry_snapshot(
    const std::atomic<uint64_t>& active_generation,
    const std::atomic<int32_t>& active_channels,
    const std::atomic<int32_t>& active_mode,
    GeometrySnapshot* out) {
    return load_geometry_snapshot(
        active_generation, active_channels, active_mode, out);
}

inline void begin_geometry_publication(std::atomic<uint64_t>& generation) {
    generation.store(0, std::memory_order_seq_cst);
}

inline bool finish_geometry_publication(std::atomic<uint64_t>& generation,
                                        uint64_t next) {
    if (next == 0) return false;
    generation.store(next, std::memory_order_seq_cst);
    return true;
}

/* reset_req 存目标 generation 而非布尔位。RT 只消费 active 代的 reset；
 * 若claim 期间控制侧发布更新代，恢复旧值时 CAS 失败，绝不覆盖新 reset。 */
template <typename AfterClaim>
inline bool claim_geometry_reset(std::atomic<uint64_t>& reset_request,
                                 uint64_t active_generation,
                                 AfterClaim&& after_claim) {
    const uint64_t claimed =
        reset_request.exchange(0, std::memory_order_acq_rel);
    after_claim();
    if (active_generation != 0 && claimed == active_generation) return true;
    if (claimed != 0) {
        uint64_t empty = 0;
        reset_request.compare_exchange_strong(
            empty, claimed, std::memory_order_acq_rel);
    }
    return false;
}

inline bool claim_geometry_reset(std::atomic<uint64_t>& reset_request,
                                 uint64_t active_generation) {
    return claim_geometry_reset(reset_request, active_generation, [] {});
}

inline bool next_geometry_generation(uint64_t current, uint64_t* next) {
    if (!next || current == 0 ||
        current == (std::numeric_limits<uint64_t>::max)()) {
        return false;
    }
    *next = current + 1;
    return true;
}

inline void publish_geometry_snapshot(
    std::atomic<uint64_t>& generation,
    std::atomic<int32_t>& channels,
    std::atomic<int32_t>& mode,
    uint64_t next,
    int32_t next_channels,
    int32_t next_mode) {
    begin_geometry_publication(generation);
    channels.store(next_channels, std::memory_order_seq_cst);
    mode.store(next_mode, std::memory_order_seq_cst);
    finish_geometry_publication(generation, next);
}

inline void publish_active_geometry_snapshot(
    std::atomic<uint64_t>& active_generation,
    std::atomic<int32_t>& active_channels,
    std::atomic<int32_t>& active_mode,
    uint64_t next,
    int32_t next_channels,
    int32_t next_mode) {
    publish_geometry_snapshot(active_generation, active_channels, active_mode,
                              next, next_channels, next_mode);
}

}  // namespace auradsp_detail
