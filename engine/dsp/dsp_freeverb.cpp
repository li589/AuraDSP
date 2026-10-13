/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* rateScale = fs / 44.1kHz；调用方保证 fs 合理（否则退化为 48k 比例） */
void fv_alloc(FvVoice& v, double sampleRate, int spread = 0) {
    double scale = (sampleRate > 8000.0) ? (sampleRate / kFvTuningRefRate)
                                         : (48000.0 / kFvTuningRefRate);
    for (int i = 0; i < kFvCombs; ++i) {
        v.combSize[i] = (int)ceil((kFvCombTuning[i] + spread) * scale) + 4;
        v.combBuf[i] = (float*)calloc(v.combSize[i], sizeof(float));
        v.combIdx[i] = 0;
        v.filterstore[i] = 0.0f;
    }
    for (int i = 0; i < kFvAllpasses; ++i) {
        v.apSize[i] = (int)ceil((kFvAllpTuning[i] + spread) * scale) + 4;
        v.apBuf[i] = (float*)calloc(v.apSize[i], sizeof(float));
        v.apIdx[i] = 0;
    }
    v.damp1 = 0; v.damp2 = 1;
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
        const float wetG = h->p.fv_wet.load(std::memory_order_relaxed) * 0.5f;
        const float dryG = h->p.fv_dry.load(std::memory_order_relaxed);
        h->fvL.damp1 = damp; h->fvL.damp2 = 1.0f - damp;
        h->fvR.damp1 = damp; h->fvR.damp2 = 1.0f - damp;
        for (int i = 0; i < frames; ++i) {
            const float wetL = fv_voice_process(h->fvL, dst[i * 2], feedback);
            const float wetR = fv_voice_process(h->fvR, dst[i * 2 + 1], feedback);
            dst[i * 2]     = dst[i * 2] * dryG + wetL * wetG;
            dst[i * 2 + 1] = dst[i * 2 + 1] * dryG + wetR * wetG;
        }
        float g = powf(10.0f, h->p.reverb_outgain.load(std::memory_order_relaxed) * 0.05f);
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
            g *= (float)h->rev_ag_comp;
        }
        if (g != 1.0f) {
            for (int i = 0; i < frames; ++i) {
                dst[i * 2] *= g;
                dst[i * 2 + 1] *= g;
            }
        }
    }
}