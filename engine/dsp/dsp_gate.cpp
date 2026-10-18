/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 噪声门 + Deesser + 自动增益补偿（链头第一道，input 增益之后）。
 * gate：逐采样峰值包络，支持 Hysteresis 双门限迟滞防抖、Range 衰减底线、Hold 保持时长；
 * deesser：one-pole HP（deesser.freq）取 s 音高频，包络平滑后超阈值
 * 只对高频成分动态衰减（低频不动）；
 * autogain：P-010 leveler 模式（块前后 RMS 平滑，±12dB 限幅）。
 * RT 安全：纯乘加/expf 每块一次，无分配无锁；状态 RT 独占。 */
void gate_process(auradsp_handle h, float* io, int frames) {
    const float fs = (float)h->jdsp.fs;
    if (fs <= 0.0f) return;
    const double fs_d = (double)fs;
    float thr = h->p.gate_threshold.load(std::memory_order_relaxed);
    if (thr < -60.0f) thr = -60.0f; if (thr > 0.0f) thr = 0.0f;
    float att = h->p.gate_attack.load(std::memory_order_relaxed);
    if (att < 1.0f) att = 1.0f; if (att > 100.0f) att = 100.0f;
    float rel = h->p.gate_release.load(std::memory_order_relaxed);
    if (rel < 10.0f) rel = 10.0f; if (rel > 500.0f) rel = 500.0f;
    const float attCoef = (float)exp(-1.0 / ((double)att * 0.001 * fs_d));
    const float relCoef = (float)exp(-1.0 / ((double)rel * 0.001 * fs_d));

    float hyst = h->p.gate_hysteresis.load(std::memory_order_relaxed);
    if (hyst < 0.0f) hyst = 0.0f; if (hyst > 12.0f) hyst = 12.0f;
    const float t_open = thr;
    const float t_close = thr - hyst;

    float range_db = h->p.gate_range.load(std::memory_order_relaxed);
    if (range_db < -80.0f) range_db = -80.0f; if (range_db > 0.0f) range_db = 0.0f;
    const float g_floor = std::pow(10.0f, range_db / 20.0f);

    float hold_ms = h->p.gate_hold_ms.load(std::memory_order_relaxed);
    if (hold_ms < 0.0f) hold_ms = 0.0f; if (hold_ms > 500.0f) hold_ms = 500.0f;
    const int hold_samples = (int)(hold_ms * 0.001f * fs + 0.5f);

    const int de = h->p.deesser_enable.load(std::memory_order_relaxed);
    float df = h->p.deesser_freq.load(std::memory_order_relaxed);
    if (df < 2000.0f) df = 2000.0f; if (df > 10000.0f) df = 10000.0f;
    float da = h->p.deesser_amount.load(std::memory_order_relaxed);
    if (da < 0.0f) da = 0.0f; if (da > 1.0f) da = 1.0f;
    const bool ag = h->p.gate_autogain.load(std::memory_order_relaxed) != 0;

    double rin = 0.0;
    if (ag) rin = stereo_block_rms(io, frames);

    const float bpa = (float)exp(-2.0 * 3.14159265358979323846 * (double)df / fs_d);
    const float dsCoef = (float)exp(-1.0 / (0.002 * fs_d));   /* 侧链包络 ~2ms */
    const float dsThr = 0.05f;                            /* 归一化阈值（≈-26dBFS 齿音触发） */
    const float det_rel_coef = (float)exp(-1.0 / (0.010 * fs_d)); /* 门控侧链检波 ~10ms 释放 */
    float g = h->gate_gain[0];
    float state = h->gate_state[0];
    int hold_cnt = h->gate_hold_cnt[0];
    float env = h->gate_env[0];
    float hpL = h->gate_ds_lp[0], hpR = h->gate_ds_lp[1], dsE = h->gate_ds_env[0];
    float min_ga = 1.0f;

    for (int i = 0; i < frames; ++i) {
        const float xL = io[i * 2], xR = io[i * 2 + 1];
        /* 1. 噪声门：侧链峰值包络与 Hysteresis 迟滞/Hold 保持 */
        const float pk = fabsf(xL) > fabsf(xR) ? fabsf(xL) : fabsf(xR);
        if (pk > env) {
            env = pk;
        } else {
            env += (pk - env) * (1.0f - det_rel_coef);
        }
        const float db = 20.0f * log10f(env + 1e-12f);
        if (db >= t_open) {
            state = 1.0f;
            hold_cnt = hold_samples;
        } else if (hold_cnt > 0) {
            --hold_cnt;
            state = 1.0f;
        } else if (db < t_close) {
            state = 0.0f;
        }

        const float target = state;
        const float coef = (target > g) ? attCoef : relCoef;
        g = target + (g - target) * coef;
        const float ga = g_floor + (1.0f - g_floor) * g;
        if (ga < min_ga) min_ga = ga;

        /* 2. Deesser（只衰减高频成分，低频直通） */
        float outL = xL, outR = xR;
        if (de) {
            hpL += (1.0f - bpa) * (xL - hpL);
            hpR += (1.0f - bpa) * (xR - hpR);
            const float hiL = xL - hpL, hiR = xR - hpR;
            const float ds_in = 0.5f * (fabsf(hiL) + fabsf(hiR));
            dsE += (ds_in - dsE) * dsCoef;
            float over = (dsE > dsThr) ? (dsE - dsThr) / (dsE + 1e-6f) : 0.0f;
            if (over > 1.0f) over = 1.0f;
            const float dg = 1.0f - da * over;
            outL = (xL - hiL) + dg * hiL;
            outR = (xR - hiR) + dg * hiR;
        }
        io[i * 2] = outL * ga;
        io[i * 2 + 1] = outR * ga;
    }
    h->gate_gain[0] = (fabsf(g) < 1e-15f) ? 0.0f : g;
    h->gate_gain[1] = h->gate_gain[0];
    h->gate_state[0] = state;
    h->gate_state[1] = state;
    h->gate_hold_cnt[0] = hold_cnt;
    h->gate_hold_cnt[1] = hold_cnt;
    h->gate_env[0] = (fabsf(env) < 1e-15f) ? 0.0f : env;
    h->gate_env[1] = h->gate_env[0];
    h->gate_ds_lp[0] = (fabsf(hpL) < 1e-18f) ? 0.0f : hpL;
    h->gate_ds_lp[1] = (fabsf(hpR) < 1e-18f) ? 0.0f : hpR;
    h->gate_ds_env[0] = (fabsf(dsE) < 1e-18f) ? 0.0f : dsE;

    float gr_db = 0.0f;
    if (min_ga < 0.999f && min_ga > 1e-6f) {
        gr_db = -20.0f * log10f(min_ga);
    }
    h->gr_gate.store(gr_db, std::memory_order_relaxed);

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
        const float cg_target = (float)h->gate_ag_comp;
        float g_sm = h->gate_ag_g_sm;
        if (cg_target != 1.0f || fabsf(g_sm - 1.0f) >= 1e-6f) {
            const float alpha = (float)exp(-1.0 / (0.002 * fs_d));
            const float beta = 1.0f - alpha;
            for (int i = 0; i < frames; ++i) {
                g_sm = alpha * g_sm + beta * cg_target;
                io[i * 2] *= g_sm;
                io[i * 2 + 1] *= g_sm;
            }
            h->gate_ag_g_sm = (fabsf(g_sm) < 1e-15f) ? 0.0f : g_sm;
        } else {
            h->gate_ag_g_sm = 1.0f;
        }
    }
}


void gate_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || ch <= 0 || frames <= 0) return;
    const uint32_t mask = (uint32_t)h->p.gate_channels.load(std::memory_order_relaxed);
    if ((mask & ((1u << ch) - 1u)) == 0) return;

    const float fs = (float)h->jdsp.fs;
    if (fs <= 0.0f) return;
    const double fs_d = (double)fs;
    float thr = h->p.gate_threshold.load(std::memory_order_relaxed);
    if (thr < -60.0f) thr = -60.0f; if (thr > 0.0f) thr = 0.0f;
    float att = h->p.gate_attack.load(std::memory_order_relaxed);
    if (att < 1.0f) att = 1.0f; if (att > 100.0f) att = 100.0f;
    float rel = h->p.gate_release.load(std::memory_order_relaxed);
    if (rel < 10.0f) rel = 10.0f; if (rel > 500.0f) rel = 500.0f;
    const float attCoef = (float)exp(-1.0 / ((double)att * 0.001 * fs_d));
    const float relCoef = (float)exp(-1.0 / ((double)rel * 0.001 * fs_d));

    float hyst = h->p.gate_hysteresis.load(std::memory_order_relaxed);
    if (hyst < 0.0f) hyst = 0.0f; if (hyst > 12.0f) hyst = 12.0f;
    const float t_open = thr;
    const float t_close = thr - hyst;

    float range_db = h->p.gate_range.load(std::memory_order_relaxed);
    if (range_db < -80.0f) range_db = -80.0f; if (range_db > 0.0f) range_db = 0.0f;
    const float g_floor = std::pow(10.0f, range_db / 20.0f);

    float hold_ms = h->p.gate_hold_ms.load(std::memory_order_relaxed);
    if (hold_ms < 0.0f) hold_ms = 0.0f; if (hold_ms > 500.0f) hold_ms = 500.0f;
    const int hold_samples = (int)(hold_ms * 0.001f * fs + 0.5f);

    const int de = h->p.deesser_enable.load(std::memory_order_relaxed);
    float df = h->p.deesser_freq.load(std::memory_order_relaxed);
    if (df < 2000.0f) df = 2000.0f; if (df > 10000.0f) df = 10000.0f;
    float da = h->p.deesser_amount.load(std::memory_order_relaxed);
    if (da < 0.0f) da = 0.0f; if (da > 1.0f) da = 1.0f;

    const float bpa = (float)exp(-2.0 * 3.14159265358979323846 * (double)df / fs_d);
    const float dsCoef = (float)exp(-1.0 / (0.002 * fs_d));
    const float dsThr = 0.05f;
    const float det_rel_coef = (float)exp(-1.0 / (0.010 * fs_d));

    float min_ga = 1.0f;
    const int max_c = ch > kMxMaxChannels ? kMxMaxChannels : ch;
    for (int c = 0; c < max_c; ++c) {
        if (!(mask & (1u << c))) continue;
        float g = h->gate_gain[c];
        float state = h->gate_state[c];
        int hold_cnt = h->gate_hold_cnt[c];
        float env = h->gate_env[c];
        float hp = h->gate_ds_lp[c];
        float dsE = h->gate_ds_env[c];

        for (int i = 0; i < frames; ++i) {
            const float x = io[i * ch + c];
            const float pk = fabsf(x);
            if (pk > env) {
                env = pk;
            } else {
                env += (pk - env) * (1.0f - det_rel_coef);
            }
            const float db = 20.0f * log10f(env + 1e-12f);
            if (db >= t_open) {
                state = 1.0f;
                hold_cnt = hold_samples;
            } else if (hold_cnt > 0) {
                --hold_cnt;
                state = 1.0f;
            } else if (db < t_close) {
                state = 0.0f;
            }

            const float target = state;
            const float coef = (target > g) ? attCoef : relCoef;
            g = target + (g - target) * coef;
            const float ga = g_floor + (1.0f - g_floor) * g;
            if (ga < min_ga) min_ga = ga;

            float out = x;
            if (de) {
                hp += (1.0f - bpa) * (x - hp);
                const float hi = x - hp;
                const float ds_in = fabsf(hi);
                dsE += (ds_in - dsE) * dsCoef;
                float over = (dsE > dsThr) ? (dsE - dsThr) / (dsE + 1e-6f) : 0.0f;
                if (over > 1.0f) over = 1.0f;
                const float dg = 1.0f - da * over;
                out = (x - hi) + dg * hi;
            }
            io[i * ch + c] = out * ga;
        }
        h->gate_gain[c] = (fabsf(g) < 1e-15f) ? 0.0f : g;
        h->gate_state[c] = state;
        h->gate_hold_cnt[c] = hold_cnt;
        h->gate_env[c] = (fabsf(env) < 1e-15f) ? 0.0f : env;
        h->gate_ds_lp[c] = (fabsf(hp) < 1e-18f) ? 0.0f : hp;
        h->gate_ds_env[c] = (fabsf(dsE) < 1e-18f) ? 0.0f : dsE;
    }

    float gr_db = 0.0f;
    if (min_ga < 0.999f && min_ga > 1e-6f) {
        gr_db = -20.0f * log10f(min_ga);
    }
    h->gr_gate.store(gr_db, std::memory_order_relaxed);
}

