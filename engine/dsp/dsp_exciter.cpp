/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 激励器（XHiFi 式高频修复）：HPF 取高频成分 → tanh 生成谐波 → 按量混回。
 * 位置：Haas 后 / Freeverb 前——vendor 内部 EQ/tube 拆不出来，谐波不进
 * tube 保暖声不糊；进 room 前加，房间带一点 shimmer。
 * tanh 整形本想复用 tube 链路，但 tube 的 waveshaper 在 vendor 内部
 * （VacuumTube*），引擎侧无原生共用函数——此处用标准 tanhf，drive 固
 * 定 2.0 不暴露；输出天然限幅 ±0.5×amount，amount=1 也不刺耳。
 * RT 安全：one-pole + tanhf 逐采样，无分配无锁；状态每块 denormal 归零。 */
void exciter_process(auradsp_handle h, float* io, int frames) {
    float fc = h->p.exciter_hifreq.load(std::memory_order_relaxed);
    if (fc < 3000.0f) fc = 3000.0f; if (fc > 10000.0f) fc = 10000.0f;
    float amount = h->p.exciter_amount.load(std::memory_order_relaxed);
    if (amount < 0.0f) amount = 0.0f; if (amount > 1.0f) amount = 1.0f;
    const float fs = (float)h->jdsp.fs;
    if (fs <= 0.0f) return;
    const float a = expf(-2.0f * 3.14159265358979f * fc / fs);
    const bool os = h->p.exciter_oversample.load(std::memory_order_relaxed) != 0;
    float lpL = h->exc_lp[0], lpR = h->exc_lp[1];
    for (int i = 0; i < frames; ++i) {
        const float xL = io[i * 2], xR = io[i * 2 + 1];
        lpL += (1.0f - a) * (xL - lpL);
        lpR += (1.0f - a) * (xR - lpR);
        const float hiL = xL - lpL;
        const float hiR = xR - lpR;
        float harmL, harmR;
        if (os) {
            harmL = h->exc_os[0].process_sample(hiL, [](float v) { return tanhf(v * 2.0f) * 0.5f; });
            harmR = h->exc_os[1].process_sample(hiR, [](float v) { return tanhf(v * 2.0f) * 0.5f; });
        } else {
            harmL = tanhf(hiL * 2.0f) * 0.5f;
            harmR = tanhf(hiR * 2.0f) * 0.5f;
        }
        io[i * 2]     = xL + amount * harmL;
        io[i * 2 + 1] = xR + amount * harmR;
    }
    h->exc_lp[0] = (fabsf(lpL) < 1e-18f) ? 0.0f : lpL;
    h->exc_lp[1] = (fabsf(lpR) < 1e-18f) ? 0.0f : lpR;
}


void exciter_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || ch <= 0 || frames <= 0) return;
    const uint32_t mask = (uint32_t)h->p.exciter_channels.load(std::memory_order_relaxed);
    if ((mask & ((1u << ch) - 1u)) == 0) return;

    float fc = h->p.exciter_hifreq.load(std::memory_order_relaxed);
    if (fc < 3000.0f) fc = 3000.0f; if (fc > 10000.0f) fc = 10000.0f;
    float amount = h->p.exciter_amount.load(std::memory_order_relaxed);
    if (amount < 0.0f) amount = 0.0f; if (amount > 1.0f) amount = 1.0f;
    const float fs = (float)h->jdsp.fs;
    if (fs <= 0.0f) return;
    const float a = expf(-2.0f * 3.14159265358979f * fc / fs);
    const bool os = h->p.exciter_oversample.load(std::memory_order_relaxed) != 0;

    const int max_c = ch > kMxMaxChannels ? kMxMaxChannels : ch;
    for (int c = 0; c < max_c; ++c) {
        if (!(mask & (1u << c))) continue;
        float lp = h->exc_lp[c];
        for (int i = 0; i < frames; ++i) {
            const float x = io[i * ch + c];
            lp += (1.0f - a) * (x - lp);
            const float hi = x - lp;
            float harm;
            if (os) {
                harm = h->exc_os[c].process_sample(hi, [](float v) { return tanhf(v * 2.0f) * 0.5f; });
            } else {
                harm = tanhf(hi * 2.0f) * 0.5f;
            }
            io[i * ch + c] = x + amount * harm;
        }
        h->exc_lp[c] = (fabsf(lp) < 1e-18f) ? 0.0f : lp;
    }
}

