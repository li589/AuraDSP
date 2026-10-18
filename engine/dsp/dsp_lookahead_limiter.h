#pragma once
#include <cmath>
#include <algorithm>
#include <cstdint>

namespace auradsp {

/**
 * 4-point Cubic Hermite 4x ISP (Inter-Sample Peak) 真峰检测
 * 采用三次埃尔米特插值在 [y_prev1, y_curr] 区间内评估 t = 0.25, 0.5, 0.75 处的真实模拟峰值
 * 遵循 ITU-R BS.1770-4 真峰检测原则，捕获采样点间潜在的跨界削波。
 */
inline float cubic_hermite_true_peak(float y_prev2, float y_prev1, float y_curr, float y_next) {
    float peak = (std::max)(std::fabs(y_prev1), std::fabs(y_curr));

    const float d = y_prev1;
    const float c = 0.5f * (y_curr - y_prev2);
    const float b = y_prev2 - 2.5f * y_prev1 + 2.0f * y_curr - 0.5f * y_next;
    const float a = 0.5f * (y_next - y_prev2) + 1.5f * (y_prev1 - y_curr);

    auto eval_poly = [a, b, c, d](float t) {
        return ((a * t + b) * t + c) * t + d;
    };

    float p1 = std::fabs(eval_poly(0.25f));
    float p2 = std::fabs(eval_poly(0.50f));
    float p3 = std::fabs(eval_poly(0.75f));

    peak = (std::max)(peak, (std::max)(p1, (std::max)(p2, p3)));
    return peak;
}

} // namespace auradsp
