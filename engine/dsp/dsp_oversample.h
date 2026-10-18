#pragma once

#include <cmath>
#include <cstdint>

namespace auradsp {

/**
 * 2x 多相半带 FIR 抗混叠过采样器 (Polyphase Halfband FIR Oversampler)
 *
 * 算法原理与设计参数：
 * - 阶数：43 抽头 (42阶) 严格线性相位半带滤波器。
 * - 阻带衰减：> 75 dB，过渡带对称于 0.25*Fs。
 * - 多相分解：因偶对称半带特性，所有奇数距离抽头严格为 0 (除中心抽头 0.5 外)；
 *   上采样偶数点零乘法直通延迟；下采样抽取点单相计算，运算量天然减半。
 * - 实时安全性：固定环形缓冲，按位与快速寻址，音频线程绝对零内存分配、零锁。
 */
class HalfbandOversampler2x {
public:
    static constexpr int kNumTaps = 43;
    static constexpr int kMidTap = 21;
    static constexpr int kHalfCoeffs = 11;

    // 11 个唯一的非零对称系数 h[2*j], j = 0..10
    static inline const float kCoeffs[kHalfCoeffs] = {
        +0.0003546027f, // j= 0 (taps  0, 42)
        -0.0009695069f, // j= 1 (taps  2, 40)
        +0.0021894906f, // j= 2 (taps  4, 38)
        -0.0042951668f, // j= 3 (taps  6, 36)
        +0.0076788714f, // j= 4 (taps  8, 34)
        -0.0128919906f, // j= 5 (taps 10, 32)
        +0.0208108603f, // j= 6 (taps 12, 30)
        -0.0331560839f, // j= 7 (taps 14, 28)
        +0.0542818111f, // j= 8 (taps 16, 26)
        -0.1002275641f, // j= 9 (taps 18, 24)
        +0.3163081531f  // j=10 (taps 20, 22)
    };

    // 上采样状态历史 (32 长度环形缓冲，按位与 & 31)
    float up_buf[32] = {};
    int   up_pos = 0;

    // 下采样状态历史 (64 长度环形缓冲，按位与 & 63)
    float down_buf[64] = {};
    int   down_pos = 0;

    void reset() noexcept {
        for (int i = 0; i < 32; ++i) up_buf[i] = 0.0f;
        up_pos = 0;
        for (int i = 0; i < 64; ++i) down_buf[i] = 0.0f;
        down_pos = 0;
    }

    /**
     * 逐样本过采样流水线：
     * 1. 2x 多相上采样：生成 w_even, w_odd
     * 2. 调用非线性函数 nonlin 对 2x 采样点进行变换：v_even = nonlin(w_even), v_odd = nonlin(w_odd)
     * 3. 2x 多相抗混叠下采样抽取，返回 1x 采样率输出
     */
    template <typename Func>
    inline float process_sample(float in, Func&& nonlin) noexcept {
        // 1. 上采样插值 (1:2)
        up_pos = (up_pos + 1) & 31;
        up_buf[up_pos] = in;

        // 奇数输出点 (m = 2n+1)：中心直通延迟抽头，延迟 10 样本
        const float w_odd = up_buf[(up_pos - 10) & 31];

        // 偶数输出点 (m = 2n)：11 对多相对称卷积
        float s_up = 0.0f;
        for (int j = 0; j < kHalfCoeffs; ++j) {
            const float p0 = up_buf[(up_pos - j) & 31];
            const float p1 = up_buf[(up_pos - (21 - j)) & 31];
            s_up += (2.0f * kCoeffs[j]) * (p0 + p1);
        }
        const float w_even = s_up;

        // 2. 非线性变换 (At 2x Rate)
        const float v_even = nonlin(w_even);
        const float v_odd  = nonlin(w_odd);

        // 3. 抗混叠下采样抽取 (2:1)
        // 偶数点 v_even 先写入
        down_pos = (down_pos + 1) & 63;
        down_buf[down_pos] = v_even;

        // 偶数时间点即为抽取点：中心抽头 (k=21) 贡献 + 11 对偶数抽头卷积
        float s_down = 0.5f * down_buf[(down_pos - 21) & 63];
        for (int j = 0; j < kHalfCoeffs; ++j) {
            const float p0 = down_buf[(down_pos - 2 * j) & 63];
            const float p1 = down_buf[(down_pos - (42 - 2 * j)) & 63];
            s_down += kCoeffs[j] * (p0 + p1);
        }

        // 奇数点 v_odd 后写入，供后续卷积抽头使用
        down_pos = (down_pos + 1) & 63;
        down_buf[down_pos] = v_odd;

        // 次正常数清洗
        return (std::fabs(s_down) < 1e-15f) ? 0.0f : s_down;
    }
};

} // namespace auradsp
