/* P2 split: moved verbatim from auradsp_engine.cpp.
 * WP4 (2026-10-25): 支持标准四对选择 (FL/FR, C/LFE, SL/SR, BL/BR) 与 per-pair / global 模式。 */
#include "engine_internal.h"
#include <cmath>

/* BassMono：分频点以下按对或全局取平均（one-pole，零延迟）。
 * RT 安全：每块一次 expf 求系数，无分配无锁；状态每块末做 denormal 归零。 */
void bassmono_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || !io || frames <= 0 || ch < 2) return;

    const int pairs_mask = h->p.bassmono_pairs.load(std::memory_order_relaxed) & 0x0F;
    if (pairs_mask == 0) return; /* 未选任何声道对：逐样本直通 */

    const SpeakerLayout l = layout_for(ch);

    struct PairIndices { int a, b; };
    PairIndices active_pairs[4];
    int num_pairs = 0;
    int channels_in_s[8];
    int num_s = 0;

    auto check_add_pair = [&](int bit, int ch_a, int ch_b) {
        if ((pairs_mask & (1 << bit)) && ch_a >= 0 && ch_b >= 0 && ch_a < ch && ch_b < ch) {
            active_pairs[num_pairs++] = {ch_a, ch_b};
            channels_in_s[num_s++] = ch_a;
            channels_in_s[num_s++] = ch_b;
        }
    };

    check_add_pair(0, l.fl, l.fr);
    check_add_pair(1, l.c, l.lfe);
    check_add_pair(2, l.sl, l.sr);
    check_add_pair(3, l.bl, l.br);

    if (num_pairs == 0 || num_s < 2) return; /* 无可用或不足2个声道：直通 */

    float f = h->p.bassmono_freq.load(std::memory_order_relaxed);
    if (f < 20.0f) f = 20.0f;
    if (f > 300.0f) f = 300.0f;

    const float fs = (float)h->sample_rate;
    if (fs <= 0.0f) return;
    const float a = 1.0f - expf(-2.0f * 3.14159265358979323846f * f / fs);

    /* 掩码/合并方式切换的瞬态平滑：首块用首样本初始化 lp[c] = io[c] */
    if (h->bm_reinit.exchange(0, std::memory_order_relaxed) != 0) {
        for (int k = 0; k < num_s; ++k) {
            const int c = channels_in_s[k];
            h->bm_lp[c] = io[0 * ch + c];
        }
    }

    const int merge = h->p.bassmono_merge.load(std::memory_order_relaxed);

    if (merge == 0) {
        /* per-pair: 每对独立平均 */
        for (int i = 0; i < frames; ++i) {
            const int base = i * ch;
            for (int p = 0; p < num_pairs; ++p) {
                const int ca = active_pairs[p].a;
                const int cb = active_pairs[p].b;
                h->bm_lp[ca] += a * (io[base + ca] - h->bm_lp[ca]);
                h->bm_lp[cb] += a * (io[base + cb] - h->bm_lp[cb]);
                const float avg = 0.5f * (h->bm_lp[ca] + h->bm_lp[cb]);
                io[base + ca] += avg - h->bm_lp[ca];
                io[base + cb] += avg - h->bm_lp[cb];
            }
        }
    } else {
        /* global: 全部选中且存在的声道合并平均 */
        const float inv_s = 1.0f / (float)num_s;
        for (int i = 0; i < frames; ++i) {
            const int base = i * ch;
            float sum_lp = 0.0f;
            for (int k = 0; k < num_s; ++k) {
                const int c = channels_in_s[k];
                h->bm_lp[c] += a * (io[base + c] - h->bm_lp[c]);
                sum_lp += h->bm_lp[c];
            }
            const float avg = sum_lp * inv_s;
            for (int k = 0; k < num_s; ++k) {
                const int c = channels_in_s[k];
                io[base + c] += avg - h->bm_lp[c];
            }
        }
    }

    /* 块末对选中声道做 denormal 归零 */
    for (int k = 0; k < num_s; ++k) {
        const int c = channels_in_s[k];
        if (fabsf(h->bm_lp[c]) < 1e-18f) h->bm_lp[c] = 0.0f;
    }
}

/* 2ch 包装：立体声链调用，只处理 bit 0 (FL/FR) */
void bassmono_process(auradsp_handle h, float* io, int frames) {
    if (!h || !io || frames <= 0) return;
    const int pairs_mask = h->p.bassmono_pairs.load(std::memory_order_relaxed);
    if (!(pairs_mask & 0x01)) return; /* bit 0 未选：L/R 直通 */

    float f = h->p.bassmono_freq.load(std::memory_order_relaxed);
    if (f < 20.0f) f = 20.0f;
    if (f > 300.0f) f = 300.0f;
    const float fs = (float)h->sample_rate;
    if (fs <= 0.0f) return;
    const float a = 1.0f - expf(-2.0f * 3.14159265358979323846f * f / fs);

    if (h->bm_reinit.exchange(0, std::memory_order_relaxed) != 0) {
        h->bm_lp[0] = io[0];
        h->bm_lp[1] = io[1];
    }

    float lpL = h->bm_lp[0], lpR = h->bm_lp[1];
    for (int i = 0; i < frames; ++i) {
        lpL += a * (io[i * 2] - lpL);
        lpR += a * (io[i * 2 + 1] - lpR);
        const float lo = 0.5f * (lpL + lpR);
        io[i * 2]     += lo - lpL;
        io[i * 2 + 1] += lo - lpR;
    }
    h->bm_lp[0] = (fabsf(lpL) < 1e-18f) ? 0.0f : lpL;
    h->bm_lp[1] = (fabsf(lpR) < 1e-18f) ? 0.0f : lpR;
}
