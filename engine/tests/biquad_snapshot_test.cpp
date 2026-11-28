#include "engine_internal.h"

#include <atomic>
#include <cstdio>
#include <memory>
#include <thread>

namespace {

using Coefficients = BiquadCoefficients;

constexpr Coefficients kIdentity{1.0, 0.0, 0.0, 0.0, 0.0};
constexpr Coefficients kA{1.0, 0.5, 0.25, -0.75, 0.5};
constexpr Coefficients kB{0.5, 0.25, 0.125, -0.5, 0.75};

bool CoeffsEqual(const Coefficients& a, const Coefficients& b) {
    return a.b0 == b.b0 && a.b1 == b.b1 && a.b2 == b.b2 &&
           a.a1 == b.a1 && a.a2 == b.a2;
}

bool IsKnown(const Coefficients& c) {
    return CoeffsEqual(c, kIdentity) || CoeffsEqual(c, kA) || CoeffsEqual(c, kB);
}

int CheckInitialIdentity() {
    VersionedBiquad biquad;
    const Coefficients init = biquad.snapshot();
    if (!CoeffsEqual(init, kIdentity)) {
        std::fprintf(stderr, "FAIL: default VersionedBiquad a2=%.6f (expected 0)\n",
                     init.a2);
        return 1;
    }
    /* Simulate auradsp_create (single publish) before any snapshot refreshes rt. */
    VersionedBiquad created;
    created.publish(kA);
    std::atomic<bool> start{false};
    std::atomic<int> bad{0};
    std::thread writer([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for (int i = 0; i < 50000; ++i) {
            created.publish((i & 1) ? kA : kB);
        }
    });
    start.store(true, std::memory_order_release);
    for (int i = 0; i < 50000; ++i) {
        if (!IsKnown(created.snapshot())) ++bad;
    }
    writer.join();
    if (bad != 0) {
        std::fprintf(stderr, "FAIL: initial-block race returned %d bad/unstable snapshots\n",
                     bad.load());
        return 1;
    }
    std::puts("initial VersionedBiquad identity and first-block fallback: coherent");
    return 0;
}

template <typename Biquad>
int Run(Biquad& biquad, const char* name) {
    biquad.coefficients.publish(kA);

    std::atomic<bool> start{false};
    std::atomic<int> mixed{0};
    std::thread writer([&] {
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        for (int i = 0; i < 200000; ++i) {
            const Coefficients& c = (i & 1) ? kA : kB;
            biquad.coefficients.publish(c);
        }
    });
    start.store(true, std::memory_order_release);
    for (int i = 0; i < 200000; ++i) {
        const Coefficients c = biquad.coefficients.snapshot();
        if (!IsKnown(c)) ++mixed;
    }
    writer.join();
    if (mixed != 0) {
        std::fprintf(stderr, "FAIL: %s published %d mixed coefficient snapshots\n",
                     name, mixed.load());
        return 1;
    }
    std::printf("%s coefficient snapshots: all coherent\n", name);
    return 0;
}

} // namespace

int main() {
    if (CheckInitialIdentity() != 0) return 1;
    auto handle = std::make_unique<auradsp_handle_s>();
    return Run(handle->shelf, "shelf") + Run(handle->filter, "filter");
}
