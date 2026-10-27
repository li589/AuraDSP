/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 独立滤波器（RBJ cookbook HP/LP/BP）：shelf 同款系数原子 + TDF2 直型。
 * 控制线程 filter_recalc() 重算，RT 只读系数。默认全通（b0=1）。 */
void filter_recalc(auradsp_handle h) {
    const int type = h->p.filter_type.load(std::memory_order_relaxed);
    double f0 = h->p.filter_freq.load(std::memory_order_relaxed);
    double q = h->p.filter_q.load(std::memory_order_relaxed);
    if (f0 < 20.0) f0 = 20.0; if (f0 > 20000.0) f0 = 20000.0;
    if (q < 0.3) q = 0.3; if (q > 10.0) q = 10.0;
    /* [PATCHED-AuraDSP P-029] 自研链在 ASRC 之外、处理设备率样本，系数须用 h->sample_rate（旧用工作率 jdsp.fs，96k 下 2 倍错位） */
    const double fs = h->sample_rate > 0.0 ? h->sample_rate : 48000.0;
    double w0 = 2.0 * 3.14159265358979 * f0 / fs;
    if (w0 > 3.14159265358979 * 0.99) w0 = 3.14159265358979 * 0.99;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / (2.0 * q);
    double b0, b1, b2, a0, a1, a2;
    if (type == 1) {          /* LP */
        b0 = (1.0 - cw) / 2.0; b1 = 1.0 - cw; b2 = (1.0 - cw) / 2.0;
        a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
    } else if (type == 2) {   /* BP（恒定 0dB 峰值增益） */
        b0 = alpha; b1 = 0.0; b2 = -alpha;
        a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
    } else {                  /* HP（默认） */
        b0 = (1.0 + cw) / 2.0; b1 = -(1.0 + cw); b2 = (1.0 + cw) / 2.0;
        a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
    }
    h->filter.b0.store(b0 / a0, std::memory_order_release);
    h->filter.b1.store(b1 / a0, std::memory_order_release);
    h->filter.b2.store(b2 / a0, std::memory_order_release);
    h->filter.a1.store(a1 / a0, std::memory_order_release);
    h->filter.a2.store(a2 / a0, std::memory_order_release);
}


void filter_process(auradsp_handle h, float* io, int frames) {
    const double b0 = h->filter.b0.load(std::memory_order_acquire);
    const double b1 = h->filter.b1.load(std::memory_order_acquire);
    const double b2 = h->filter.b2.load(std::memory_order_acquire);
    const double a1 = h->filter.a1.load(std::memory_order_acquire);
    const double a2 = h->filter.a2.load(std::memory_order_acquire);
    double z1L = h->filter.z1[0], z2L = h->filter.z2[0];
    double z1R = h->filter.z1[1], z2R = h->filter.z2[1];
    for (int i = 0; i < frames; ++i) {
        const double xl = io[i * 2], xr = io[i * 2 + 1];
        const double yl = b0 * xl + z1L;
        z1L = b1 * xl - a1 * yl + z2L;
        z2L = b2 * xl - a2 * yl;
        const double yr = b0 * xr + z1R;
        z1R = b1 * xr - a1 * yr + z2R;
        z2R = b2 * xr - a2 * yr;
        io[i * 2] = (float)yl;
        io[i * 2 + 1] = (float)yr;
    }
    if (fabs(z1L) < 1e-15) z1L = 0.0;
    if (fabs(z2L) < 1e-15) z2L = 0.0;
    if (fabs(z1R) < 1e-15) z1R = 0.0;
    if (fabs(z2R) < 1e-15) z2R = 0.0;
    h->filter.z1[0] = z1L; h->filter.z2[0] = z2L;
    h->filter.z1[1] = z1R; h->filter.z2[1] = z2R;
}


void filter_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || ch <= 0 || frames <= 0) return;
    const uint32_t mask = (uint32_t)h->p.filter_channels.load(std::memory_order_relaxed);
    if ((mask & ((1u << ch) - 1u)) == 0) return;

    const double b0 = h->filter.b0.load(std::memory_order_acquire);
    const double b1 = h->filter.b1.load(std::memory_order_acquire);
    const double b2 = h->filter.b2.load(std::memory_order_acquire);
    const double a1 = h->filter.a1.load(std::memory_order_acquire);
    const double a2 = h->filter.a2.load(std::memory_order_acquire);

    const int max_c = ch > kMxMaxChannels ? kMxMaxChannels : ch;
    for (int c = 0; c < max_c; ++c) {
        if (!(mask & (1u << c))) continue;
        double z1 = h->filter.z1[c], z2 = h->filter.z2[c];
        for (int i = 0; i < frames; ++i) {
            const double x = io[i * ch + c];
            const double y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            io[i * ch + c] = (float)y;
        }
        if (fabs(z1) < 1e-15) z1 = 0.0;
        if (fabs(z2) < 1e-15) z2 = 0.0;
        h->filter.z1[c] = z1;
        h->filter.z2[c] = z2;
    }
}

