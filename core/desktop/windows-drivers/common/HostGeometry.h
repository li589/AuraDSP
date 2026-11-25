#pragma once

#include <atomic>
#include <cstdint>
#include <utility>

namespace aurahost {

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "host geometry generation must remain lock-free on RT readers");
static_assert(std::atomic<int32_t>::is_always_lock_free,
              "host geometry payload must remain lock-free on RT readers");

struct GeometrySnapshot {
    uint64_t generation = 0;
    int32_t channels = 0;
    int32_t mode = 0;
};

inline bool ValidGeometry(const GeometrySnapshot& g) {
    return g.generation != 0 &&
           (g.channels == 2 || g.channels == 4 || g.channels == 6 ||
            g.channels == 8) &&
           (g.mode == 0 || g.mode == 1);
}

/* Host-side requested geometry. generation=0 is the publication sentinel;
 * readers double-read generation and never spin or retry. Publishers must be
 * serialized by the host control path (the RT pump only posts an intent). */
class GeometryState {
 public:
    bool Load(GeometrySnapshot* out) const { return Load(out, [] {}); }

    template <typename AfterGeneration>
    bool Load(GeometrySnapshot* out, AfterGeneration&& after_generation) const {
        if (!out) return false;
        const uint64_t observed =
            generation_.load(std::memory_order_seq_cst);
        if (observed == 0) return false;
        after_generation();
        const int32_t channels = channels_.load(std::memory_order_seq_cst);
        const int32_t mode = mode_.load(std::memory_order_seq_cst);
        if (generation_.load(std::memory_order_seq_cst) != observed) {
            return false;
        }
        const GeometrySnapshot candidate{observed, channels, mode};
        if (!ValidGeometry(candidate)) return false;
        *out = candidate;
        return true;
    }

    bool Publish(const GeometrySnapshot& next) {
        if (!ValidGeometry(next)) return false;
        const uint64_t current = generation_.load(std::memory_order_seq_cst);
        if (current != 0 && next.generation <= current) return false;
        generation_.store(0, std::memory_order_seq_cst);
        channels_.store(next.channels, std::memory_order_seq_cst);
        mode_.store(next.mode, std::memory_order_seq_cst);
        generation_.store(next.generation, std::memory_order_seq_cst);
        return true;
    }

    // Start/stop only, while no RT reader or geometry worker is active.
    void Reset() {
        generation_.store(0, std::memory_order_seq_cst);
        channels_.store(0, std::memory_order_seq_cst);
        mode_.store(0, std::memory_order_seq_cst);
    }

 private:
    std::atomic<uint64_t> generation_{0};
    std::atomic<int32_t> channels_{0};
    std::atomic<int32_t> mode_{0};
};

/* Single-slot, latest-wins intent queue. The RT producer performs only one
 * validated atomic store; the non-RT worker consumes it and enters the
 * serialized engine control path. */
class GeometryIntentQueue {
 public:
    bool Post(int32_t channels) {
        if (channels != 2 && channels != 4 && channels != 6 && channels != 8)
            return false;
        pending_.store(channels, std::memory_order_release);
        return true;
    }

    int32_t Take() {
        return pending_.exchange(0, std::memory_order_acquire);
    }

    void Clear() { pending_.store(0, std::memory_order_release); }

 private:
    std::atomic<int32_t> pending_{0};
};

}  // namespace aurahost
