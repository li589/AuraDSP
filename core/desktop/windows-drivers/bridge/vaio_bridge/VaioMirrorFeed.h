#pragma once
// VaioMirrorFeed.h — 监听镜像喂流规划（纯逻辑，无 COM/平台依赖）。
//
// 背景（ASIO-2 补全，2026-11-14）：监听镜像是 VAIO 桥的第二路
// WASAPI 渲染——把处理后音频分路一份到系统默认物理端点供本地
// 耳机监听。主路端点的时钟驱动泵线程，镜像端点有自己独立的
// 时钟与采样率，本规划器在泵的每块节奏上决定向镜像写多少帧：
//
//   · 采样率归一：want = phase + inFrames × (镜像率/主路率)，
//     取整为本块应写帧数，小数部分跨块携带——长时间运行不积累
//     漂移（与环→输出 ResampleLinear 的相位口径同理）；
//   · 缓冲钳制：应写帧数超过镜像缓冲当前可写量（容量 − 填充）
//     时截断到可写量，差额计入 drops——镜像时钟偏慢时丢帧而非
//     阻塞主路；镜像是尽力而为的监听路，绝不反压 DSP 主链；
//   · 返回 0 表示本块不写（帧数太小凑不满一帧，或缓冲已满）。
//
// 泵线程独占使用（无锁）；status 读 fed/drops 时与 totalPumpedFrames
// 同口径容忍撕裂读。本头被 vaio_mirror_feed_test.cpp 宿主编译实跑
// （同 vaio_pump_wait.h 的先例：测真实代码，不测复刻品）。

#include <cstdint>

struct VaioMirrorFeed {
    double phase = 0.0;   // 跨块分数相位（镜像帧域，恒在 [0,1)）
    uint64_t fed = 0;     // 已规划写出的镜像帧累计
    uint64_t drops = 0;   // 因镜像缓冲不足被丢弃的镜像帧累计

    // inFrames：本块主路帧数；ratio：镜像采样率 / 主路采样率；
    // availFrames：镜像缓冲当前可写帧数（容量 − padding）。
    // 返回本块应向镜像写入的帧数。
    uint32_t Plan(uint32_t inFrames, double ratio, uint32_t availFrames) {
        if (inFrames == 0 || ratio <= 0.0) return 0;
        const double want = phase + (double)inFrames * ratio;
        uint32_t out = (uint32_t)want;
        phase = want - (double)out;
        if (out > availFrames) {
            drops += (uint64_t)(out - availFrames);
            out = availFrames;
        }
        fed += out;
        return out;
    }
};
