/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"

#include <cmath>

/* ---- 全参数动态EQ（3 段：Low shelf / Mid bell / High shelf）----
 * 位置：vendor 链前（shelf 之后），pre-vendor 音色修整。
 * 架构（与 dsp_gate.c 的 Deesser 同构：谱减法）：
 *   每段 = 静态 RBJ（base gain，常时）+ 动态谱减（超阈后按 range 衰减该频段成分）。
 *   检波：双声道侧链 bell @ freq/Q + 峰值包络取最大（attack/release 全局共用，
 *   立体声联动，防声像漂移）；施加：静态 RBJ + 谱减（out = static - band + dg*band）。
 * RT 安全：每块现算系数（~90 flops，可跟踪参数滑动；bassmono 同模式），
 * 逐采样纯乘加，无分配无锁；状态 RT 独占。探针不支持（包络动态，gate 同理）。 */

namespace {

constexpr double kDyneqPi = 3.14159265358979;

/* RBJ bell 系数（归一化，a0=1）。 */
inline void rbj_bell(double f0, double fs, double q, double gdb,
                     double& b0, double& b1, double& b2, double& a1, double& a2) {    const double A = pow(10.0, gdb / 40.0);
    const double w0 = 2.0 * kDyneqPi * f0 / fs;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / (2.0 * q);
    const double a0 = 1.0 + alpha / A;
    b0 = (1.0 + alpha * A) / a0;
    b1 = (-2.0 * cw) / a0;
    b2 = (1.0 - alpha * A) / a0;
    a1 = (-2.0 * cw) / a0;
    a2 = (1.0 - alpha / A) / a0;
}

/* RBJ bandpass 系数（constant 0dB peak gain；检波专用，真带外抑制）。
 * 注意不能用 0dB bell 做检波——bell 全频皆通，带外照样触发（wrong-band 实测抓回）。 */
inline void rbj_bpf(double f0, double fs, double q,
                    double& b0, double& b1, double& b2, double& a1, double& a2) {
    const double w0 = 2.0 * kDyneqPi * f0 / fs;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / (2.0 * q);
    const double a0 = 1.0 + alpha;
    b0 = alpha / a0;
    b1 = 0.0;
    b2 = -alpha / a0;
    a1 = (-2.0 * cw) / a0;
    a2 = (1.0 - alpha) / a0;
}

/* RBJ low-shelf 系数（S = 斜率，用 Q 代入并钳位）。 */
inline void rbj_lshelf(double f0, double fs, double s, double gdb,
                       double& b0, double& b1, double& b2, double& a1, double& a2) {
    const double A = pow(10.0, gdb / 40.0);
    const double w0 = 2.0 * kDyneqPi * f0 / fs;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / 2.0 * sqrt((A + 1.0 / A) * (1.0 / s - 1.0) + 2.0);
    const double sq = 2.0 * sqrt(A) * alpha;
    const double a0 = (A + 1.0) + (A - 1.0) * cw + sq;
    b0 = (A * ((A + 1.0) - (A - 1.0) * cw + sq)) / a0;
    b1 = (2.0 * A * ((A - 1.0) - (A + 1.0) * cw)) / a0;
    b2 = (A * ((A + 1.0) - (A - 1.0) * cw - sq)) / a0;
    a1 = (-2.0 * ((A - 1.0) + (A + 1.0) * cw)) / a0;
    a2 = ((A + 1.0) + (A - 1.0) * cw - sq) / a0;
}

/* RBJ high-shelf 系数。 */
inline void rbj_hshelf(double f0, double fs, double s, double gdb,
                       double& b0, double& b1, double& b2, double& a1, double& a2) {
    const double A = pow(10.0, gdb / 40.0);
    const double w0 = 2.0 * kDyneqPi * f0 / fs;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / 2.0 * sqrt((A + 1.0 / A) * (1.0 / s - 1.0) + 2.0);
    const double sq = 2.0 * sqrt(A) * alpha;
    const double a0 = (A + 1.0) - (A - 1.0) * cw + sq;
    b0 = (A * ((A + 1.0) + (A - 1.0) * cw + sq)) / a0;
    b1 = (-2.0 * A * ((A - 1.0) + (A + 1.0) * cw)) / a0;
    b2 = (A * ((A + 1.0) + (A - 1.0) * cw - sq)) / a0;
    a1 = (2.0 * ((A - 1.0) - (A + 1.0) * cw)) / a0;
    a2 = ((A + 1.0) - (A - 1.0) * cw - sq) / a0;
}

}  // namespace

void dyneq_process(auradsp_handle h, float* io, int frames) {
    const double fs = h->jdsp.fs;
    if (fs <= 0.0) return;
    double att = h->p.dyneq_attack.load(std::memory_order_relaxed);
    if (att < 0.1) att = 0.1; if (att > 100.0) att = 100.0;
    double rel = h->p.dyneq_release.load(std::memory_order_relaxed);
    if (rel < 10.0) rel = 10.0; if (rel > 1000.0) rel = 1000.0;
    const double attCoef = exp(-1.0 / (att * 0.001 * fs));
    const double relCoef = exp(-1.0 / (rel * 0.001 * fs));

    /* 每段参数快照（band 0=Low shelf / 1=Mid bell / 2=High shelf）。 */
    struct BandCfg { bool en; double f, q, g, range, thr; };
    BandCfg cfg[3] = {
        {h->p.dyneq_l_enable.load(std::memory_order_relaxed) != 0,
         h->p.dyneq_l_freq.load(std::memory_order_relaxed),
         h->p.dyneq_l_q.load(std::memory_order_relaxed),
         h->p.dyneq_l_gain.load(std::memory_order_relaxed),
         h->p.dyneq_l_range.load(std::memory_order_relaxed),
         h->p.dyneq_l_threshold.load(std::memory_order_relaxed)},
        {h->p.dyneq_m_enable.load(std::memory_order_relaxed) != 0,
         h->p.dyneq_m_freq.load(std::memory_order_relaxed),
         h->p.dyneq_m_q.load(std::memory_order_relaxed),
         h->p.dyneq_m_gain.load(std::memory_order_relaxed),
         h->p.dyneq_m_range.load(std::memory_order_relaxed),
         h->p.dyneq_m_threshold.load(std::memory_order_relaxed)},
        {h->p.dyneq_h_enable.load(std::memory_order_relaxed) != 0,
         h->p.dyneq_h_freq.load(std::memory_order_relaxed),
         h->p.dyneq_h_q.load(std::memory_order_relaxed),
         h->p.dyneq_h_gain.load(std::memory_order_relaxed),
         h->p.dyneq_h_range.load(std::memory_order_relaxed),
         h->p.dyneq_h_threshold.load(std::memory_order_relaxed)},
    };
    const double fMin[3] = {20.0, 200.0, 2000.0};
    const double fMax[3] = {500.0, 8000.0, 20000.0};
    bool anyOn = false;
    for (int b = 0; b < 3; ++b) {
        if (cfg[b].en) anyOn = true;
        if (cfg[b].f < fMin[b]) cfg[b].f = fMin[b];
        if (cfg[b].f > fMax[b]) cfg[b].f = fMax[b];
        if (b == 1) { if (cfg[b].q < 0.3) cfg[b].q = 0.3; if (cfg[b].q > 10.0) cfg[b].q = 10.0; }
        else { if (cfg[b].q < 0.5) cfg[b].q = 0.5; if (cfg[b].q > 2.0) cfg[b].q = 2.0; }
        if (cfg[b].g < -12.0) cfg[b].g = -12.0; if (cfg[b].g > 12.0) cfg[b].g = 12.0;
        if (cfg[b].range < 0.0) cfg[b].range = 0.0; if (cfg[b].range > 24.0) cfg[b].range = 24.0;
        if (cfg[b].thr < -60.0) cfg[b].thr = -60.0; if (cfg[b].thr > 0.0) cfg[b].thr = 0.0;
    }
    if (!anyOn) return;
    /* 静态 + 检波 bell 系数（每块现算，跟踪参数滑动）。 */
    double sb0[3], sb1[3], sb2[3], sa1[3], sa2[3];
    double db0[3], db1[3], db2[3], da1[3], da2[3];
    double thrLin[3], attMax[3];
    for (int b = 0; b < 3; ++b) {
        if (b == 0)
            rbj_lshelf(cfg[b].f, fs, cfg[b].q, cfg[b].g, sb0[b], sb1[b], sb2[b], sa1[b], sa2[b]);
        else if (b == 1)
            rbj_bell(cfg[b].f, fs, cfg[b].q, cfg[b].g, sb0[b], sb1[b], sb2[b], sa1[b], sa2[b]);
        else
            rbj_hshelf(cfg[b].f, fs, cfg[b].q, cfg[b].g, sb0[b], sb1[b], sb2[b], sa1[b], sa2[b]);
        rbj_bpf(cfg[b].f, fs, cfg[b].q, db0[b], db1[b], db2[b], da1[b], da2[b]);
        thrLin[b] = pow(10.0, cfg[b].thr / 20.0);
        attMax[b] = 1.0 - pow(10.0, -cfg[b].range / 20.0); /* range=满偏时频段残留比 */
    }

    for (int i = 0; i < frames; ++i) {
        double xl = io[i * 2], xr = io[i * 2 + 1];
        for (int b = 0; b < 3; ++b) {
            if (!cfg[b].en) continue;
            auto& st = h->dyneq_b[b];
            /* 1. 检波：双声道 bell 取频段分量，包络取最大（立体声联动）。 */
            const double bL = db0[b] * xl + st.det_z1L;
            st.det_z1L = db1[b] * xl - da1[b] * bL + st.det_z2L;
            st.det_z2L = db2[b] * xl - da2[b] * bL;
            const double bR = db0[b] * xr + st.det_z1R;
            st.det_z1R = db1[b] * xr - da1[b] * bR + st.det_z2R;
            st.det_z2R = db2[b] * xr - da2[b] * bR;
            const double pk = fabs(bL) > fabs(bR) ? fabs(bL) : fabs(bR);
            const double coef = (pk > st.env) ? attCoef : relCoef;
            st.env = pk + (st.env - pk) * coef;
            /* 2. 动态量：超阈比例 → 频段衰减（只衰减该频段成分，带外不动）。 */
            double over = (st.env > thrLin[b]) ? (st.env - thrLin[b]) / (st.env + 1e-9) : 0.0;
            if (over > 1.0) over = 1.0;
            const double dg = 1.0 - attMax[b] * over;
            /* 3. 静态 RBJ + 谱减（out = static - band + dg*band）。 */
            const double yl = sb0[b] * xl + st.z1L;
            st.z1L = sb1[b] * xl - sa1[b] * yl + st.z2L;
            st.z2L = sb2[b] * xl - sa2[b] * yl;
            const double yr = sb0[b] * xr + st.z1R;
            st.z1R = sb1[b] * xr - sa1[b] * yr + st.z2R;
            st.z2R = sb2[b] * xr - sa2[b] * yr;
            xl = yl - bL + dg * bL;
            xr = yr - bR + dg * bR;
        }
        io[i * 2] = (float)xl;
        io[i * 2 + 1] = (float)xr;
    }
    /* 截断次正常数。 */
    for (int b = 0; b < 3; ++b) {
        auto& st = h->dyneq_b[b];
        if (fabs(st.det_z1L) < 1e-15) st.det_z1L = 0.0;
        if (fabs(st.det_z2L) < 1e-15) st.det_z2L = 0.0;
        if (fabs(st.det_z1R) < 1e-15) st.det_z1R = 0.0;
        if (fabs(st.det_z2R) < 1e-15) st.det_z2R = 0.0;
        if (fabs(st.env) < 1e-18) st.env = 0.0;
        if (fabs(st.z1L) < 1e-15) st.z1L = 0.0;
        if (fabs(st.z2L) < 1e-15) st.z2L = 0.0;
        if (fabs(st.z1R) < 1e-15) st.z1R = 0.0;
        if (fabs(st.z2R) < 1e-15) st.z2R = 0.0;
    }
}
