/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* rateScale = fs / 44.1kHz；调用方保证 fs 合理（否则退化为 48k 比例） */
void fv_alloc(FvVoice& v, double sampleRate, int spread = 0) {
    double scale = (sampleRate > 8000.0) ? (sampleRate / kFvTuningRefRate)
                                         : (48000.0 / kFvTuningRefRate);
    // 按 room 上限预分配（kFvRoomMax×），运行时只改 Len。+4 守卫 + spread。
    for (int i = 0; i < kFvCombs; ++i) {
        v.combSize[i] = (int)ceil((kFvCombTuning[i] + spread) * scale * kFvRoomMax) + 4;
        v.combBuf[i] = (float*)calloc(v.combSize[i], sizeof(float));
        v.combLen[i] = (int)ceil((kFvCombTuning[i] + spread) * scale) + 4;
        if (v.combLen[i] > v.combSize[i]) v.combLen[i] = v.combSize[i];
        v.combIdx[i] = 0;
        v.filterstore[i] = 0.0f;
    }
    for (int i = 0; i < kFvAllpasses; ++i) {
        v.apSize[i] = (int)ceil((kFvAllpTuning[i] + spread) * scale * kFvRoomMax) + 4;
        v.apBuf[i] = (float*)calloc(v.apSize[i], sizeof(float));
        v.apLen[i] = (int)ceil((kFvAllpTuning[i] + spread) * scale) + 4;
        if (v.apLen[i] > v.apSize[i]) v.apLen[i] = v.apSize[i];
        v.apIdx[i] = 0;
    }
    v.damp1 = 0; v.damp2 = 1;
}

// 控制线程专用（set_param 路径，持 ctrl_mutex，不在 RT 调用）。
// 按 room 缩放两 voice 的有效长度并清缓冲，idx 若超出新长度就地归零。
static void fv_retune_voice(FvVoice& v, double rateScale, int spread, double room) {
    for (int i = 0; i < kFvCombs; ++i) {
        int len = (int)ceil((kFvCombTuning[i] + spread) * rateScale * room) + 4;
        if (len < 8) len = 8;
        if (len > v.combSize[i]) len = v.combSize[i];
        v.combLen[i] = len;
        if (v.combIdx[i] >= len) v.combIdx[i] = 0;
        memset(v.combBuf[i], 0, sizeof(float) * (size_t)v.combSize[i]);
    }
    for (int i = 0; i < kFvAllpasses; ++i) {
        int len = (int)ceil((kFvAllpTuning[i] + spread) * rateScale * room) + 4;
        if (len < 8) len = 8;
        if (len > v.apSize[i]) len = v.apSize[i];
        v.apLen[i] = len;
        if (v.apIdx[i] >= len) v.apIdx[i] = 0;
        memset(v.apBuf[i], 0, sizeof(float) * (size_t)v.apSize[i]);
    }
}

void fv_retune(struct auradsp_handle_s* h, double room) {
    const double sr = (h->sample_rate > 8000.0f) ? (double)h->sample_rate : 48000.0;
    const double rateScale = sr / kFvTuningRefRate;
    fv_retune_voice(h->fvL, rateScale, 0, room);
    fv_retune_voice(h->fvR, rateScale, kFvStereoSpread, room);
}


void fv_free(FvVoice& v) {
    for (int i = 0; i < kFvCombs; ++i) { free(v.combBuf[i]); v.combBuf[i] = nullptr; }
    for (int i = 0; i < kFvAllpasses; ++i) { free(v.apBuf[i]); v.apBuf[i] = nullptr; }
}

/* M5-c Freeverb (extracted verbatim from process_stereo_chain). */
void freeverb_process(auradsp_handle h, float* dst, int frames) {
    if (h->p.fv_enable.load(std::memory_order_relaxed)) {
        const bool ag = h->p.reverb_autogain.load(std::memory_order_relaxed) != 0;
        double rin = 0.0;
        if (ag) rin = stereo_block_rms(dst, frames);
        const float feedback =
            0.7f + h->p.fv_decay.load(std::memory_order_relaxed) * 0.28f;
        const float damp = h->p.fv_damp.load(std::memory_order_relaxed) * 0.4f;
        float wetG = h->p.fv_wet.load(std::memory_order_relaxed) * 0.7f;
        float dryG = h->p.fv_dry.load(std::memory_order_relaxed);
        // 等能量归一化：确保干声+混响声总声能恒定，拉动干湿比不产生额外音量暴涨
        const float fv_norm = 1.0f / sqrtf(fmaxf(0.01f, dryG * dryG + wetG * wetG));
        dryG *= fv_norm;
        wetG *= fv_norm;
        h->fvL.damp1 = damp; h->fvL.damp2 = 1.0f - damp;
        h->fvR.damp1 = damp; h->fvR.damp2 = 1.0f - damp;
        const float wdt = h->p.fv_width.load(std::memory_order_relaxed);
        for (int i = 0; i < frames; ++i) {
            float wetL = fv_voice_process(h->fvL, dst[i * 2], feedback);
            float wetR = fv_voice_process(h->fvR, dst[i * 2 + 1], feedback);
            if (wdt != 1.0f) {
                // width：只加宽 wet 声（M/S：mid 直通，side × width）。
                // 1.0 恒等；干声不受影响。RT 纯数学，拖滑块的 zipper
                // 藏在混响尾里。
                const float mid = (wetL + wetR) * 0.5f;
                const float side = (wetL - wetR) * 0.5f * wdt;
                wetL = mid + side;
                wetR = mid - side;
            }
            dst[i * 2]     = dst[i * 2] * dryG + wetL * wetG;
            dst[i * 2 + 1] = dst[i * 2 + 1] * dryG + wetR * wetG;
        }
        float g_target = powf(10.0f, h->p.reverb_outgain.load(std::memory_order_relaxed) * 0.05f);
        if (ag) {
            const double rout = stereo_block_rms(dst, frames);
            h->rev_ag_in  += (rin - h->rev_ag_in)  * 0.05;
            h->rev_ag_out += (rout - h->rev_ag_out) * 0.05;
            double desired = 1.0;
            if (h->rev_ag_in > 1e-6 && h->rev_ag_out > 1e-6)
                desired = h->rev_ag_in / h->rev_ag_out;
            if (desired < 0.25) desired = 0.25;
            if (desired > 4.0)  desired = 4.0;
            h->rev_ag_comp += (desired - h->rev_ag_comp) * 0.1;
            g_target *= (float)h->rev_ag_comp;
        }
        float g_sm = h->fv_g_sm;
        if (g_target != 1.0f || fabsf(g_sm - 1.0f) >= 1e-6f) {
            const double sr = (h->sample_rate > 8000.0f) ? (double)h->sample_rate : 48000.0;
            const float alpha = (float)exp(-1.0 / (0.002 * sr));
            const float beta = 1.0f - alpha;
            for (int i = 0; i < frames; ++i) {
                g_sm = alpha * g_sm + beta * g_target;
                dst[i * 2] *= g_sm;
                dst[i * 2 + 1] *= g_sm;
            }
            h->fv_g_sm = (fabsf(g_sm) < 1e-15f) ? 0.0f : g_sm;
        } else {
            h->fv_g_sm = 1.0f;
        }
    }
}