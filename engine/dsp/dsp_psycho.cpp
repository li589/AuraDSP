/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 心理声学低音（MaxxBass 路线）：谐波带 = LP(cutoff) − LP(subfreq)，
 * 对该频带做 tanh 谐波合成后按量混回。小单元放不出 40Hz 基频，
 * 但 80/120Hz 谐波让大脑"听见"低音。位置：bassmono 后（单声道低频
 * 上直接合成，相位一致）、vendor 之前（谐波随后被 vendor bass 一起
 * 提升，心理效应更强）。
 * RT 安全：2×one-pole + tanhf 逐采样，无分配无锁；状态 denormal 归零。 */
void basspsycho_process(auradsp_handle h, float* io, int frames) {
    float amount = h->p.bass_harmonics.load(std::memory_order_relaxed);
    if (amount < 0.0f) amount = 0.0f; if (amount > 1.0f) amount = 1.0f;
    float blend = h->p.bass_harmonicblend.load(std::memory_order_relaxed);
    if (blend < 0.0f) blend = 0.0f; if (blend > 1.0f) blend = 1.0f;
    float sub = h->p.bass_subfreq.load(std::memory_order_relaxed);
    if (sub < 10.0f) sub = 10.0f; if (sub > 40.0f) sub = 40.0f;
    float fc = h->p.bass_cutoff_f.load(std::memory_order_relaxed);
    if (fc < 30.0f) fc = 30.0f; if (fc > 300.0f) fc = 300.0f;
    if (sub >= fc) sub = fc * 0.5f;
    /* [PATCHED-AuraDSP P-029] 自研链在 ASRC 之外、处理设备率样本，系数须用 h->sample_rate（旧用工作率 jdsp.fs，96k 下 2 倍错位） */
    const float fs = (float)h->sample_rate;
    if (fs <= 0.0f) return;
    const float aC = 1.0f - expf(-2.0f * 3.14159265358979f * fc / fs);
    const float aS = 1.0f - expf(-2.0f * 3.14159265358979f * sub / fs);
    const float k = amount * blend;
    const bool os = h->p.bass_oversample.load(std::memory_order_relaxed) != 0;
    float cutL = h->psy_lp_l, cutR = h->psy_lp_r;
    float subL = h->psy_sub_l, subR = h->psy_sub_r;
    for (int i = 0; i < frames; ++i) {
        const float xL = io[i * 2], xR = io[i * 2 + 1];
        cutL += aC * (xL - cutL);
        cutR += aC * (xR - cutR);
        subL += aS * (xL - subL);
        subR += aS * (xR - subR);
        const float bandL = cutL - subL, bandR = cutR - subR;
        float harmL, harmR;
        if (os) {
            harmL = h->psycho_os[0].process_sample(bandL, [](float v) { return tanhf(v * 2.5f) * 0.6f; });
            harmR = h->psycho_os[1].process_sample(bandR, [](float v) { return tanhf(v * 2.5f) * 0.6f; });
        } else {
            harmL = tanhf(bandL * 2.5f) * 0.6f;
            harmR = tanhf(bandR * 2.5f) * 0.6f;
        }
        io[i * 2]     = xL + k * harmL;
        io[i * 2 + 1] = xR + k * harmR;
    }
    h->psy_lp_l = (fabsf(cutL) < 1e-18f) ? 0.0f : cutL;
    h->psy_lp_r = (fabsf(cutR) < 1e-18f) ? 0.0f : cutR;
    h->psy_sub_l = (fabsf(subL) < 1e-18f) ? 0.0f : subL;
    h->psy_sub_r = (fabsf(subR) < 1e-18f) ? 0.0f : subR;
}
