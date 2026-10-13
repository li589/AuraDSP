/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* Haas 差分环绕（延迟 D 的那一侧由 haas.side 决定 + 干湿混合，另一侧恒直通
 * 保单声道兼容）。位置：Stage 2 后 / Freeverb 前——vendor 内部展宽拆不出来，
 * vendor 出口是能挂的最晚空间点（spec 链序 stereo→haas→reverb 的可实现形态）。
 * RT 安全：纯延迟线，无分配无锁；mix=0 时仍持续录制延迟环，
 * 避免开轮瞬间爆出陈旧音频。 */
void haas_process(auradsp_handle h, float* io, int frames) {
    const int ringLen = h->haas_ring_len;
    if (!h->haas_ring || ringLen <= 0) return;
    float dms = h->p.haas_delay_ms.load(std::memory_order_relaxed);
    if (dms < 0.0f) dms = 0.0f; if (dms > 25.0f) dms = 25.0f;
    float mix = h->p.haas_mix.load(std::memory_order_relaxed);
    if (mix < 0.0f) mix = 0.0f; if (mix > 1.0f) mix = 1.0f;
    /* 延迟侧：0=右 1=左（Viper 差分环绕同款偏好开关） */
    const int dc = (h->p.haas_side.load(std::memory_order_relaxed) == 1) ? 0 : 1;
    const float fs = (float)h->jdsp.fs;
    int d = (fs > 0.0f) ? (int)(dms * 0.001f * fs + 0.5f) : 0;
    if (d >= ringLen) d = ringLen - 1;
    const float dry = 1.0f - mix;
    int pos = h->haas_pos;
    for (int i = 0; i < frames; ++i) {
        const float din = io[i * 2 + dc];
        h->haas_ring[pos] = din;
        int rp = pos - d;
        if (rp < 0) rp += ringLen;
        io[i * 2 + dc] = din * dry + h->haas_ring[rp] * mix;
        if (++pos >= ringLen) pos = 0;
    }
    h->haas_pos = pos;
}
