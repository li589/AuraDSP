/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 响度补偿（信号自适应等响度）：慢速电平跟随（~0.5s）估计回放响度，
 * 信号越静，低频（LP 200Hz）与高频（HP 6kHz）补得越多（简化 ISO226）。
 * 上限：低频 +10dB、高频 +6dB，再乘 amount。响亮信号恒等直通。
 * 位置：Stage 3 插件后、安全钳位前——最后一道音色工序。
 * RT 安全：3×one-pole 逐采样，无分配无锁；状态 denormal 归零。 */
void loudness_process(auradsp_handle h, float* io, int frames) {
    float amount = h->p.loudness_amount.load(std::memory_order_relaxed);
    if (amount < 0.0f) amount = 0.0f; if (amount > 1.0f) amount = 1.0f;
    /* [PATCHED-AuraDSP P-029] 自研链在 ASRC 之外、处理设备率样本，系数须用 h->sample_rate（旧用工作率 jdsp.fs，96k 下 2 倍错位） */
    const float fs = (float)h->sample_rate;
    if (fs <= 0.0f) return;
    const double lvl = stereo_block_rms(io, frames);
    h->loud_level += (lvl - h->loud_level) * 0.02;
    /* 安静度 q：-20dBFS 为基准，每低 30dB 加满（amount 再缩放） */
    double levelDb = 20.0 * log10(h->loud_level + 1e-12);
    double q = (-20.0 - levelDb) / 30.0;
    if (q < 0.0) q = 0.0; if (q > 1.0) q = 1.0;
    q *= amount;
    const float lowG = (q <= 0.0) ? 0.0f : (float)(pow(10.0, 10.0 * q / 20.0) - 1.0);
    const float hiG = (q <= 0.0) ? 0.0f : (float)(pow(10.0, 6.0 * q / 20.0) - 1.0);
    if (lowG <= 0.0f && hiG <= 0.0f) return;
    const float aL = 1.0f - expf(-2.0f * 3.14159265358979f * 200.0f / fs);
    const float aH = expf(-2.0f * 3.14159265358979f * 6000.0f / fs);
    float lpL = h->loud_lp[0], lpR = h->loud_lp[1];
    float hpL = h->loud_hp[0], hpR = h->loud_hp[1];
    for (int i = 0; i < frames; ++i) {
        const float xL = io[i * 2], xR = io[i * 2 + 1];
        lpL += aL * (xL - lpL);
        lpR += aL * (xR - lpR);
        hpL += (1.0f - aH) * (xL - hpL);
        hpR += (1.0f - aH) * (xR - hpR);
        const float hiL = xL - hpL, hiR = xR - hpR;
        io[i * 2]     = xL + lowG * lpL + hiG * hiL;
        io[i * 2 + 1] = xR + lowG * lpR + hiG * hiR;
    }
    h->loud_lp[0] = (fabsf(lpL) < 1e-18f) ? 0.0f : lpL;
    h->loud_lp[1] = (fabsf(lpR) < 1e-18f) ? 0.0f : lpR;
    h->loud_hp[0] = (fabsf(hpL) < 1e-18f) ? 0.0f : hpL;
    h->loud_hp[1] = (fabsf(hpR) < 1e-18f) ? 0.0f : hpR;
}


void loudness_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || ch <= 0 || frames <= 0) return;
    const uint32_t mask = (uint32_t)h->p.loudness_channels.load(std::memory_order_relaxed);
    if ((mask & ((1u << ch) - 1u)) == 0) return;

    float amount = h->p.loudness_amount.load(std::memory_order_relaxed);
    if (amount < 0.0f) amount = 0.0f; if (amount > 1.0f) amount = 1.0f;
    const float fs = (float)h->sample_rate;
    if (fs <= 0.0f) return;

    /* 多声道 RMS 评估（基于前两声道或全局估算回放响度） */
    double acc = 0.0;
    for (int i = 0; i < frames; ++i) {
        const double l = io[i * ch], r = (ch > 1) ? io[i * ch + 1] : l;
        acc += l * l + r * r;
    }
    const double lvl = sqrt(acc / (2.0 * (double)frames));
    h->loud_level += (lvl - h->loud_level) * 0.02;

    double levelDb = 20.0 * log10(h->loud_level + 1e-12);
    double q = (-20.0 - levelDb) / 30.0;
    if (q < 0.0) q = 0.0; if (q > 1.0) q = 1.0;
    q *= amount;
    const float lowG = (q <= 0.0) ? 0.0f : (float)(pow(10.0, 10.0 * q / 20.0) - 1.0);
    const float hiG = (q <= 0.0) ? 0.0f : (float)(pow(10.0, 6.0 * q / 20.0) - 1.0);
    if (lowG <= 0.0f && hiG <= 0.0f) return;

    const float aL = 1.0f - expf(-2.0f * 3.14159265358979f * 200.0f / fs);
    const float aH = expf(-2.0f * 3.14159265358979f * 6000.0f / fs);

    const int max_c = ch > kMxMaxChannels ? kMxMaxChannels : ch;
    for (int c = 0; c < max_c; ++c) {
        if (!(mask & (1u << c))) continue;
        float lp = h->loud_lp[c];
        float hp = h->loud_hp[c];
        for (int i = 0; i < frames; ++i) {
            const float x = io[i * ch + c];
            lp += aL * (x - lp);
            hp += (1.0f - aH) * (x - hp);
            const float hi = x - hp;
            io[i * ch + c] = x + lowG * lp + hiG * hi;
        }
        h->loud_lp[c] = (fabsf(lp) < 1e-18f) ? 0.0f : lp;
        h->loud_hp[c] = (fabsf(hp) < 1e-18f) ? 0.0f : hp;
    }
}

