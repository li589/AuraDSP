/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 噪声门 + Deesser + 自动增益补偿（链头第一道，input 增益之后）。
 * gate：逐采样峰值包络，attack/release 一阶平滑门增益，下限 -60dB 防咔哒；
 * deesser：one-pole HP（deesser.freq）取 s 音高频，包络平滑后超阈值
 * 只对高频成分动态衰减（低频不动）；
 * autogain：P-010 leveler 模式（块前后 RMS 平滑，±12dB 限幅）。
 * RT 安全：纯乘加/expf 每块一次，无分配无锁；状态 RT 独占。 */
void gate_process(auradsp_handle h, float* io, int frames) {
    const float fs = (float)h->jdsp.fs;
    if (fs <= 0.0f) return;
    float thr = h->p.gate_threshold.load(std::memory_order_relaxed);
    if (thr < -60.0f) thr = -60.0f; if (thr > 0.0f) thr = 0.0f;
    float att = h->p.gate_attack.load(std::memory_order_relaxed);
    if (att < 1.0f) att = 1.0f; if (att > 100.0f) att = 100.0f;
    float rel = h->p.gate_release.load(std::memory_order_relaxed);
    if (rel < 10.0f) rel = 10.0f; if (rel > 500.0f) rel = 500.0f;
    const float attCoef = expf(-1.0f / (att * 0.001f * fs));
    const float relCoef = expf(-1.0f / (rel * 0.001f * fs));
    const int de = h->p.deesser_enable.load(std::memory_order_relaxed);
    float df = h->p.deesser_freq.load(std::memory_order_relaxed);
    if (df < 2000.0f) df = 2000.0f; if (df > 10000.0f) df = 10000.0f;
    float da = h->p.deesser_amount.load(std::memory_order_relaxed);
    if (da < 0.0f) da = 0.0f; if (da > 1.0f) da = 1.0f;
    const bool ag = h->p.gate_autogain.load(std::memory_order_relaxed) != 0;

    double rin = 0.0;
    if (ag) rin = stereo_block_rms(io, frames);

    const float bpa = expf(-2.0f * 3.14159265358979f * df / fs);
    const float dsCoef = expf(-1.0f / (0.002f * fs));   /* 侧链包络 ~2ms */
    const float dsThr = 0.05f;                            /* 归一化阈值（≈-26dBFS 齿音触发） */
    float g = h->gate_gain;
    float hpL = h->gate_ds_lp_l, hpR = h->gate_ds_lp_r, dsE = h->gate_ds_env;
    for (int i = 0; i < frames; ++i) {
        const float xL = io[i * 2], xR = io[i * 2 + 1];
        /* 1. 噪声门 */
        const float pk = fabsf(xL) > fabsf(xR) ? fabsf(xL) : fabsf(xR);
        const float db = 20.0f * log10f(pk + 1e-12f);
        const float target = (db < thr) ? 0.0f : 1.0f;
        const float coef = (target > g) ? attCoef : relCoef;
        g = target + (g - target) * coef;
        const float ga = 0.001f + 0.999f * g;   /* 下限 -60dB 防完全静默 */

        /* 2. Deesser（只衰减高频成分，低频直通） */
        float outL = xL, outR = xR;
        if (de) {
            hpL += (1.0f - bpa) * (xL - hpL);
            hpR += (1.0f - bpa) * (xR - hpR);
            const float hiL = xL - hpL, hiR = xR - hpR;
            const float env = 0.5f * (fabsf(hiL) + fabsf(hiR));
            dsE += (env - dsE) * dsCoef;
            float over = (dsE > dsThr) ? (dsE - dsThr) / (dsE + 1e-6f) : 0.0f;
            if (over > 1.0f) over = 1.0f;
            const float dg = 1.0f - da * over;
            outL = (xL - hiL) + dg * hiL;
            outR = (xR - hiR) + dg * hiR;
        }
        io[i * 2] = outL * ga;
        io[i * 2 + 1] = outR * ga;
    }
    h->gate_gain = g;
    h->gate_ds_lp_l = (fabsf(hpL) < 1e-18f) ? 0.0f : hpL;
    h->gate_ds_lp_r = (fabsf(hpR) < 1e-18f) ? 0.0f : hpR;
    h->gate_ds_env = (fabsf(dsE) < 1e-18f) ? 0.0f : dsE;

    if (ag) {
        const double rout = stereo_block_rms(io, frames);
        h->gate_ag_in  += (rin - h->gate_ag_in)  * 0.05;
        h->gate_ag_out += (rout - h->gate_ag_out) * 0.05;
        double desired = 1.0;
        if (h->gate_ag_in > 1e-6 && h->gate_ag_out > 1e-6)
            desired = h->gate_ag_in / h->gate_ag_out;
        if (desired < 0.25) desired = 0.25;
        if (desired > 4.0)  desired = 4.0;
        h->gate_ag_comp += (desired - h->gate_ag_comp) * 0.1;
        const float cg = (float)h->gate_ag_comp;
        if (cg != 1.0f)
            for (int i = 0; i < frames; ++i) {
                io[i * 2] *= cg;
                io[i * 2 + 1] *= cg;
            }
    }
}
