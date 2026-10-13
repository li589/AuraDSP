/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* ---- M5-b 低频搁架（RBJ cookbook low-shelf，Q=0.707）----
 * RT 路径：DF2T 双声道，系数原子读；控制线程重算系数。 */
void shelf_recalc(auradsp_handle h) {
    const double f0 = h->p.shelf_freq.load(std::memory_order_relaxed);
    const double gdb = h->p.shelf_gain.load(std::memory_order_relaxed);
    const double A = pow(10.0, gdb / 40.0);
    const double w0 = 2.0 * 3.14159265358979 * f0 / h->jdsp.fs;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / (2.0 * 0.7071067811865476);
    const double sqA2a = 2.0 * sqrt(A) * alpha;
    const double b0 = A * ((A + 1) - (A - 1) * cw + sqA2a);
    const double b1 = 2.0 * A * ((A - 1) - (A + 1) * cw);
    const double b2 = A * ((A + 1) - (A - 1) * cw - sqA2a);
    const double a0 = (A + 1) + (A - 1) * cw + sqA2a;
    const double a1 = -2.0 * ((A - 1) + (A + 1) * cw);
    const double a2 = (A + 1) + (A - 1) * cw - sqA2a;
    h->shelf.b0.store(b0 / a0, std::memory_order_release);
    h->shelf.b1.store(b1 / a0, std::memory_order_release);
    h->shelf.b2.store(b2 / a0, std::memory_order_release);
    h->shelf.a1.store(a1 / a0, std::memory_order_release);
    h->shelf.a2.store(a2 / a0, std::memory_order_release);
}


void shelf_process(auradsp_handle h, float* io, int frames) {
    const double b0 = h->shelf.b0.load(std::memory_order_acquire);
    const double b1 = h->shelf.b1.load(std::memory_order_acquire);
    const double b2 = h->shelf.b2.load(std::memory_order_acquire);
    const double a1 = h->shelf.a1.load(std::memory_order_acquire);
    const double a2 = h->shelf.a2.load(std::memory_order_acquire);
    double z1L = h->shelf.z1L, z2L = h->shelf.z2L;
    double z1R = h->shelf.z1R, z2R = h->shelf.z2R;
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
    /* 截断次正常数 (subnormal float)，防止静音时 CPU 陷入微码陷阱 */
    if (fabs(z1L) < 1e-15) z1L = 0.0;
    if (fabs(z2L) < 1e-15) z2L = 0.0;
    if (fabs(z1R) < 1e-15) z1R = 0.0;
    if (fabs(z2R) < 1e-15) z2R = 0.0;
    h->shelf.z1L = z1L; h->shelf.z2L = z2L;
    h->shelf.z1R = z1R; h->shelf.z2R = z2R;
}
