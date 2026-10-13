/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* BassMono：分频点以下 L/R 取平均（就地改 src；one-pole，零延迟）。
 * RT 安全：每块一次 expf 求系数，无分配无锁；状态每块做 denormal 归零，
 * 静音时不烧 CPU。 */
void bassmono_process(auradsp_handle h, float* io, int frames) {
    float f = h->p.bassmono_freq.load(std::memory_order_relaxed);
    if (f < 20.0f) f = 20.0f; if (f > 300.0f) f = 300.0f;
    const float fs = (float)h->jdsp.fs;
    if (fs <= 0.0f) return;
    const float a = 1.0f - expf(-2.0f * 3.14159265358979f * f / fs);
    float lpL = h->bm_lp_l, lpR = h->bm_lp_r;
    for (int i = 0; i < frames; ++i) {
        lpL += a * (io[i * 2] - lpL);
        lpR += a * (io[i * 2 + 1] - lpR);
        const float lo = 0.5f * (lpL + lpR);
        io[i * 2]     += lo - lpL;
        io[i * 2 + 1] += lo - lpR;
    }
    h->bm_lp_l = (fabsf(lpL) < 1e-18f) ? 0.0f : lpL;
    h->bm_lp_r = (fabsf(lpR) < 1e-18f) ? 0.0f : lpR;
}
