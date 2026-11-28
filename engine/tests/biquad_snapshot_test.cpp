#include "engine_internal.h"

#include <atomic>
#include <cstdio>
#include <memory>
#include <thread>

namespace {

using Coefficients = BiquadCoefficients;

constexpr Coefficients kA{1.0, 0.5, 0.25, -0.75, 0.5};
constexpr Coefficients kB{0.5, 0.25, 0.125, -0.5, 0.75};

bool IsKnown(const Coefficients& c) {
    return (c.b0 == kA.b0 && c.b1 == kA.b1 && c.b2 == kA.b2 &&
            c.a1 == kA.a1 && c.a2 == kA.a2) ||
           (c.b0 == kB.b0 && c.b1 == kB.b1 && c.b2 == kB.b2 &&
            c.a1 == kB.a1 && c.a2 == kB.a2);
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
    auto handle = std::make_unique<auradsp_handle_s>();
    return Run(handle->shelf, "shelf") + Run(handle->filter, "filter");
}
