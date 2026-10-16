/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 计算当前启用组合的附加延迟（ms）——纯测量。
 * ADR-006：延迟档硬约束已撤销，此函数只累加并上报，
 * 永远不返回「超档」，也不再导致任何使能请求被拒绝。 */
void compute_latency(auradsp_handle h, double* out_ms) {
    double ms = 0.0;
    if (h->p.limiter_enable.load(std::memory_order_relaxed)) ms += kLatLimiter.ms;
    if (h->p.reverb_preset.load(std::memory_order_relaxed) >= 0) {
        ms += kLatReverb.ms;
    }
    /* 卷积：IR 已加载且使能时计入 */
    if (h->p.conv_enable.load(std::memory_order_relaxed) &&
        h->ir_ready.load(std::memory_order_relaxed)) {
        ms += kLatConvolver.ms;
    }
    if (h->p.xfeed_enable.load(std::memory_order_relaxed)) ms += kLatCrossfeed.ms;
    /* VDC = 动态范围均衡器，延迟极低。此前 kLatDdc 定义了却从未计入，
     * 导致 VDC 开启时总延迟被低估。 */
    if (h->p.ddc_enable.load(std::memory_order_relaxed) &&
        h->p.ddc_ready.load(std::memory_order_relaxed)) {
        ms += kLatDdc.ms;
    }
    if (h->p.comp_enable.load(std::memory_order_relaxed)) {
        ms += kLatComp.ms;
    }
    if (h->p.arbmag_enable.load(std::memory_order_relaxed) &&
        h->p.arbmag_ready.load(std::memory_order_relaxed)) {
        ms += kLatArbMag.ms;
    }
    /* Haas = 纯延迟线，按当前设定值动态上报（0..25ms，Viper 差分环绕同量级）。 */
    if (h->p.haas_enable.load(std::memory_order_relaxed)) {
        float dms = h->p.haas_delay_ms.load(std::memory_order_relaxed);
        if (dms < 0.0f) dms = 0.0f; if (dms > 25.0f) dms = 25.0f;
        ms += dms;
    }
    /* 空间音效：直达径 ITD 名义 1ms（早期反射/混响尾是并行能量，不计入；
     * 与 reverb 30ms 名义口径一致）。 */
    if (h->p.spatial_enable.load(std::memory_order_relaxed)) {
        ms += kLatSpatial.ms;
    }
    *out_ms = ms;
}


/* ---- 精准应用：只动被改的那条链 ----
 *
 * 教训：旧实现把 5 条链全量重放（ReverbDisable→Reverb_SetParam→ReverbEnable…）。
 * 其中 Reverb_SetParam = sf_presetreverb() 会重建整套混响状态，EQ 的
 * equalizerForceRefresh 会重算最小相位 IR 并重载 FFT 卷积器。
 * 由于 set_param 与 process 跑在同一音频 isolate 线程，全量重放会让音频泵
 * 停摆数十~数百毫秒 → 表现为"点任何开关都要等一会儿才生效"。
 * 因此每条参数只碰自己那一条链；全量重放仅在 create 时做一次。
 */
void apply_bass(auradsp_handle h) {
    JamesDSPLib* j = &h->jdsp;
    if (h->p.bass_enable.load(std::memory_order_relaxed)) {
        BassBoostSetParam(j, h->p.bass_gain.load(std::memory_order_relaxed));
        BassBoostEnable(j);
    } else {
        BassBoostDisable(j);
    }
}


void apply_reverb(auradsp_handle h) {
    JamesDSPLib* j = &h->jdsp;
    const int rv = h->p.reverb_preset.load(std::memory_order_relaxed);
    if (rv >= 0) {
        Reverb_SetParam(j, rv);   /* 重建混响（仅预设真正变化时调用） */
        ReverbEnable(j);
    } else {
        ReverbDisable(j);
    }
}


void apply_stereo(auradsp_handle h) {
    JamesDSPLib* j = &h->jdsp;
    const float sm = h->p.stereo_mix.load(std::memory_order_relaxed);
    const bool en = h->p.stereo_enable.load(std::memory_order_relaxed) != 0;
    if (en && sm > 0.0f) {
        StereoEnhancementSetParam(j, sm);
        StereoEnhancementEnable(j);
        /* P-002：分带状态在 Refresh 时被清，apply 后重放宿主值 */
        if (h->p.stereo_band_used.load(std::memory_order_relaxed)) {
            for (int i = 0; i < 5; ++i)
                StereoEnhancementSetBandMix(j, i,
                    h->p.stereo_band[i].load(std::memory_order_relaxed));
        }
    } else {
        StereoEnhancementDisable(j);
    }
}


void apply_eq(auradsp_handle h) {
    MultimodalEqualizerEnable(
        &h->jdsp, h->p.eq_enable.load(std::memory_order_relaxed) ? 1 : 0);
}


void apply_post(auradsp_handle h) {
    JamesDSPSetPostGain(&h->jdsp, h->p.post_gain.load(std::memory_order_relaxed));
}


/* P-010：bass/eq/tube/comp 输出增益门 + 自动补偿落地 vendor stage。
 * 每项独立下推，无 vendor 锁（对齐 float 写，x86 原子；切态重置在 vendor 内）。 */
void apply_fx_gains(auradsp_handle h) {
    static constexpr struct { std::atomic<float> Params::*db;
                              std::atomic<int32_t> Params::*on; int fx; } kFx[] = {
        { &Params::tube_outgain, &Params::tube_autogain, 0 },
        { &Params::comp_outgain, &Params::comp_autogain, 1 },
        { &Params::bass_outgain, &Params::bass_autogain, 2 },
        { &Params::eq_outgain,     &Params::eq_autogain,     3 },
        { &Params::arbmag_outgain, &Params::arbmag_autogain, 4 },
    };
    for (const auto& f : kFx) {
        const float db = (h->p.*(f.db)).load(std::memory_order_relaxed);
        JamesDSPSetFxOutGain(&h->jdsp, f.fx, powf(10.0f, db * 0.05f));
        JamesDSPSetFxAutoGain(&h->jdsp, f.fx,
            (h->p.*(f.on)).load(std::memory_order_relaxed) ? 1 : 0);
    }
}


void apply_liveprog(auradsp_handle h) {
    if (h->p.lp_enable.load(std::memory_order_relaxed))
        LiveProgEnable(&h->jdsp);
    else
        LiveProgDisable(&h->jdsp);
}


void apply_tube(auradsp_handle h) {
    if (h->p.tube_enable.load(std::memory_order_relaxed)) {
        VacuumTubeSetGain(&h->jdsp, (double)h->p.tube_gain.load(std::memory_order_relaxed));
        /* P-011：音色/混合/补偿每次推送（create 即默认全湿 0dB；VTInit 不重置这三个值） */
        VacuumTubeSetCharacter(&h->jdsp, (int)h->p.tube_style.load(std::memory_order_relaxed));
        VacuumTubeSetDryWet(&h->jdsp, h->p.tube_mix.load(std::memory_order_relaxed));
        VacuumTubeSetOutComp(&h->jdsp, (double)h->p.tube_compensation.load(std::memory_order_relaxed));
        VacuumTubeEnable(&h->jdsp);
    } else {
        VacuumTubeDisable(&h->jdsp);
    }
}


void apply_crossfeed(auradsp_handle h) {
    const int en = h->p.xfeed_enable.load(std::memory_order_relaxed) ? 1 : 0;
    if (en) {
        CrossfeedEnable(&h->jdsp, 1);
        const int mode = h->p.xfeed_mode.load(std::memory_order_relaxed);
        const unsigned int fs = (unsigned int)h->jdsp.fs;
        if (mode == 1) {
            /* Chu Moy: 700 Hz, 6.0 dB */
            h->jdsp.advXF.mode = 0;
            BS2BInit(&h->jdsp.advXF.bs2b[0], fs, BS2B_CMOY_CLEVEL);
        } else if (mode == 2) {
            /* Jan Meier: 650 Hz, 9.5 dB */
            h->jdsp.advXF.mode = 1;
            BS2BInit(&h->jdsp.advXF.bs2b[1], fs, BS2B_JMEIER_CLEVEL);
        } else if (mode == 3) {
            /* Custom: fcut & feed */
            float fcut = h->p.xfeed_fcut.load(std::memory_order_relaxed);
            if (fcut < 300.0f) fcut = 300.0f;
            if (fcut > 2000.0f) fcut = 2000.0f;
            float feed = h->p.xfeed_feed.load(std::memory_order_relaxed);
            if (feed < 1.0f) feed = 1.0f;
            if (feed > 15.0f) feed = 15.0f;
            int flevel = BS2BCalculateflevel((unsigned int)fcut, (unsigned int)(feed * 10.0f));
            h->jdsp.advXF.mode = 0;
            BS2BInit(&h->jdsp.advXF.bs2b[0], fs, flevel);
        } else {
            /* Mode 0: Default (BS2B standard / EasyEffects default: 700 Hz, 4.5 dB) */
            h->jdsp.advXF.mode = 0;
            BS2BInit(&h->jdsp.advXF.bs2b[0], fs, BS2B_DEFAULT_CLEVEL);
        }
    } else {
        CrossfeedDisable(&h->jdsp);
    }
}


void apply_convolver(auradsp_handle h) {
    if (h->p.conv_enable.load(std::memory_order_relaxed) &&
        h->ir_ready.load(std::memory_order_relaxed))
        Convolver1DEnable(&h->jdsp);
    else
        Convolver1DDisable(&h->jdsp);
}


void apply_comp(auradsp_handle h) {
    if (h->p.comp_enable.load(std::memory_order_relaxed)) {
        CompressorSetParam(&h->jdsp,
                           h->p.comp_timeconstant.load(std::memory_order_relaxed),
                           h->p.comp_granularity.load(std::memory_order_relaxed),
                           h->p.comp_tfresolution.load(std::memory_order_relaxed),
                           1);
        CompressorSetGain(&h->jdsp, 0, 0, 0);
        CompressorEnable(&h->jdsp, 1);
    } else {
        CompressorDisable(&h->jdsp);
    }
}


void apply_arbmag(auradsp_handle h) {
    if (h->p.arbmag_enable.load(std::memory_order_relaxed) &&
        h->p.arbmag_ready.load(std::memory_order_relaxed)) {
        ArbitraryResponseEqualizerEnable(&h->jdsp, 1);
    } else {
        ArbitraryResponseEqualizerDisable(&h->jdsp);
    }
}


/* 仅 create / 需要整体重建时使用 */
void apply_params_locked(auradsp_handle h) {
    apply_bass(h);
    apply_reverb(h);
    apply_stereo(h);
    apply_eq(h);
    apply_post(h);
    apply_liveprog(h);
    apply_convolver(h);
    apply_tube(h);
    apply_crossfeed(h);
    apply_comp(h);
    apply_arbmag(h);
    apply_fx_gains(h);
}


/* Liveprog 代码加载成功后刷新滑块指针并写回宿主存储值。
 * 注意：NSEEL_VM_regvar 对同名变量幂等返回同一指针（P-001 已在编译前注册）。 */
void lp_refresh_sliders(auradsp_handle h) {
    for (int i = 0; i < 8; ++i) {
        char nm[16];
        snprintf(nm, sizeof(nm), "slider%d", i + 1);
        h->lp_slider_ptr[i] = NSEEL_VM_regvar(h->jdsp.eel.vm, nm);
        if (h->lp_slider_ptr[i])
            *h->lp_slider_ptr[i] = h->p.lp_param[i].load(std::memory_order_relaxed);
    }
}


static inline void process_plugin_slots_stage(auradsp_handle h, int stage, float* buffer, int frames) {
    if (!h || !h->plugin_host) return;
    for (size_t s = 0; s < auradsp::PluginHostManager::kMaxPluginSlots; ++s) {
        if (h->plugin_host->hasActivePluginSlot(s) &&
            !h->plugin_host->isBypassedSlot(s) &&
            h->plugin_host->getInsertStageSlot(s) == stage) {

            for (int i = 0; i < frames; ++i) {
                h->plugin_buf_l[i] = buffer[i * 2];
                h->plugin_buf_r[i] = buffer[i * 2 + 1];
            }
            float* planarBuffers[2] = { h->plugin_buf_l, h->plugin_buf_r };
            h->plugin_host->processSlot(s, planarBuffers, planarBuffers, static_cast<uint32_t>(frames));
            for (int i = 0; i < frames; ++i) {
                buffer[i * 2]     = h->plugin_buf_l[i];
                buffer[i * 2 + 1] = h->plugin_buf_r[i];
            }
        }
    }
}

/* ---------------------------------------------------------------------------
 * 多声道矩阵混音（ADR-003 Phase A）
 *
 * Phase A 不逐声道实例化 DSP，而是在引擎外层做 M→2 下混 / 2→M 上混：
 *   下混：L = FL + k·C + k·SL[+k·BL]，R = FR + k·C + k·SR[+k·BR]
 *   LFE **直通**，完全不进 DSP（保护低频主干与超低音相位）
 *   上混：FL/FR 写处理后的 L/R，其余环绕声道按同系数回填处理后的 L/R
 *
 * 已知局限（ADR-003 已载明）：Phase A 下"立体声增强/Crossfeed"对 C/SL/SR
 * 的作用是间接的（经并入矩阵），UI 效果说明中如实标注。
 * 声道序遵循 WAVEFORMATEX 的标准顺序：FL FR C LFE SL SR [BL BR]。
 * ------------------------------------------------------------------------- */

/* 各声道的下混系数（0 = 该声道不并入 L/R）。索引即声道号。 */
constexpr float kMx51[6] = { 1.0f, 0.0f, 0.7f, 0.0f, 0.7f, 0.7f }; /* FL FR C LFE SL SR */
constexpr float kMx71[8] = { 1.0f, 0.0f, 0.7f, 0.0f, 0.7f, 0.7f, 0.7f, 0.7f };
/* 上混回填增益：环绕声道写入处理后 L/R 的比例（1.0 = 与前置同相） */
constexpr float kMxUpmixSurround = 0.7f;



static const float* mx_coeff_for(int ch) {
    if (ch >= 8) return kMx71;
    if (ch >= 6) return kMx71;   /* 7 声道按 7.1 前 6 个处理 */
    return kMx51;
}


/* M→2 下混 + 旁路声道留存。返回 false 表示 scratch 不可用（应直通）。 */
bool mx_downmix(auradsp_handle h, const float* in, float* stereo,
                              int frames, int ch) {
    const float* c = mx_coeff_for(ch);
    float* keep = h->mx_scratch;                 /* frames*ch，用于存 LFE 等直通声道 */
    if (!keep) return false;
    for (int i = 0; i < frames; ++i) {
        const float* sp = in + (size_t)i * ch;
        float* kp = keep + (size_t)i * ch;
        float l = 0.0f, r = 0.0f;
        for (int k = 0; k < ch; ++k) {
            const float v = sp[k];
            kp[k] = v;                            /* 全量留存，上混时按需取用 */
            const float g = c[k];
            l += v * g;
            /* 右声道增益：FL 不进右，FR 全额 */
            r += v * ((k == 0) ? 0.0f : ((k == 1) ? 1.0f : g));
        }
        stereo[i * 2]     = l;
        stereo[i * 2 + 1] = r;
    }
    return true;
}


/* 2→M 上混：前置写处理后 L/R，环绕按系数回填，LFE 原样还原 */
void mx_upmix(auradsp_handle h, float* out, const float* stereo,
                            int frames, int ch) {
    const float* keep = h->mx_scratch;
    if (!keep) return;
    for (int i = 0; i < frames; ++i) {
        const float* sp = keep + (size_t)i * ch;
        float* dp = out + (size_t)i * ch;
        const float l = stereo[i * 2];
        const float r = stereo[i * 2 + 1];
        for (int k = 0; k < ch; ++k) {
            if (k == 0)      dp[k] = l;
            else if (k == 1) dp[k] = r;
            else if (k == 3) dp[k] = sp[3];               /* LFE 直通还原 */
            else             dp[k] = (k == 2 ? l : r) * kMxUpmixSurround;
        }
    }
}

void process_stereo_chain(auradsp_handle h, const float* src, float* dst,
                                 int frames);


static inline void sample_stage_peak(auradsp_handle h, int stage_idx, const float* interleaved, int frames) {
    float ml = 0.0f, mr = 0.0f;
    for (int i = 0; i < frames; ++i) {
        const float al = fabsf(interleaved[i * 2]);
        const float ar = fabsf(interleaved[i * 2 + 1]);
        if (al > ml) ml = al;
        if (ar > mr) mr = ar;
    }
    h->stage_peak_l[stage_idx] = ml;
    h->stage_peak_r[stage_idx] = mr;
}

/* 立体声处理链本体（RT 线程；src != dst 恒成立）。
 *
 * 抽成独立函数是为了让多声道路径复用同一条链：多声道场景先把 M 声道下混成
 * src，再走这条链得到 dst，最后上混回 M —— 保证"多声道 = 立体声 + 矩阵"
 * 这一不变式，不会出现两套效果逻辑各自漂移。
 * src 为只读输入，dst 为就地处理的工作区与输出。
 */
void process_stereo_chain(auradsp_handle h, const float* src, float* dst,
                                 int frames) {
    /* 低音参数：系数重算必须在本线程做。
     * 旧实现在 auradsp_set_param("bass.gain") 里直接调 BassBoostSetParam，
     * 与此处的 processFloatMultiplexd 并发访问同一个 JamesDSPLib —— 与
     * EQ 卷积器同型的数据竞争。且拖动时目标值每秒跳数十次，每次都是阶跃，
     * 连成「叫叫叫」。此处改为每块按 kBassSlewPerBlock 向目标渐变，
     * 变化足够小时才真正下发，兼顾连续性与 vendor 调用频率。*/
    /* Gate/Deesser：链头第一道（input 增益之后、bassmono 之前）——
     * 先降噪再单声道化，避免低频打架放大被门控的噪声。 */
    if (h->p.gate_enable.load(std::memory_order_relaxed)) {
        gate_process(h, const_cast<float*>(src), frames);
    }
    sample_stage_peak(h, 13, src, frames);   /* Stage 13: Gate stage output */

    /* 独立滤波器（gate 之后 / bassmono 之前）：HP 去隆隆声，
     * 避免次声误开噪声门；LP/BP 按需。 */
    if (h->p.filter_enable.load(std::memory_order_relaxed)) {
        filter_process(h, const_cast<float*>(src), frames);
    }
    sample_stage_peak(h, 15, src, frames);   /* Stage 15: Filter output */

    /* BassMono：在一切之前（Stage 0 插件/搁架/vendor 之前）——
     * 单声道化后再做后续处理，否则低频相位差会被后级放大。
     * 随 shelf precedent 就地改 src（调用方传的本就是可写 scratch）。 */
    if (h->p.bassmono_enable.load(std::memory_order_relaxed)) {
        bassmono_process(h, const_cast<float*>(src), frames);
    }
    sample_stage_peak(h, 16, src, frames);   /* Stage 16: BassMono output */

    /* 心理声学低音：跟 bass 卡开关走；amount=0 时恒等直通，
     * 状态持续跟踪以免开量瞬间抽吸。 */
    if (h->p.bass_enable.load(std::memory_order_relaxed)) {
        basspsycho_process(h, const_cast<float*>(src), frames);
    }
    /* Stage 0: Pre-DSP（链头，最前置） */
    process_plugin_slots_stage(h, 0, const_cast<float*>(src), frames);

    /* M5-b：低频搁架在 vendor 链前（就地改 src） */
    if (h->p.shelf_enable.load(std::memory_order_relaxed) &&
        h->p.shelf_gain.load(std::memory_order_relaxed) != 0.0f) {
        shelf_process(h, const_cast<float*>(src), frames);
    }

    /* 全参数动态EQ：shelf 之后、vendor 之前（pre-vendor 音色修整成组）。 */
    if (h->p.dyneq_enable.load(std::memory_order_relaxed)) {
        dyneq_process(h, const_cast<float*>(src), frames);
    }
    sample_stage_peak(h, 14, src, frames);   /* Stage 14: Dynamic EQ output */

    /* Stage 1: Pre-Vendor（主效果前） */
    process_plugin_slots_stage(h, 1, const_cast<float*>(src), frames);

    /* [EQ tap] EQ 输入 = vendor 链入口。EQ 在库的单体链内部，拆不出后级，
     * 只能取前级；此处已过 pre-DSP / 前置插件 / 低架，尚未进 EQ。 */
    viz_write_eq_in(h, src, frames);
    /* libjamesdsp 稳态无分配；块超限时内部自动重分配（pfloat32Multiplexed） */
    h->jdsp.processFloatMultiplexd(&h->jdsp, const_cast<float*>(src), dst,
                                   (size_t)frames);

    /* Stage 2: Post-Vendor（主效果后 / 混响前） */
    process_plugin_slots_stage(h, 2, dst, frames);

    /* Haas 差分环绕（Stage 2 后 / Freeverb 前） */
    if (h->p.haas_enable.load(std::memory_order_relaxed)) {
        haas_process(h, dst, frames);
    }
    sample_stage_peak(h, 17, dst, frames);   /* Stage 17: Haas output */

    /* 空间音效 L1（haas 后 / exciter 前：空间族抱团，最后一道音色工序之前） */
    if (h->p.spatial_enable.load(std::memory_order_relaxed)) {
        spatial_process(h, dst, frames);
    }
    sample_stage_peak(h, 20, dst, frames);   /* Stage 20: Spatial output */

    /* 激励器（Haas 后 / Freeverb 前：最后一道音色工序，再进房间） */
    if (h->p.exciter_enable.load(std::memory_order_relaxed)) {
        exciter_process(h, dst, frames);
    }
    sample_stage_peak(h, 18, dst, frames);   /* Stage 18: Exciter output */

    /* M5-c：Freeverb 在 vendor 链后（含输出限幅），wet/dry 原位混合。
     * P-010：混响输出增益门 + 自动增益补偿（全引擎侧，reverb 不占 vendor 槽） */
    freeverb_process(h, dst, frames);

    /* Stage 3: Post-Reverb（混响后，默认阶段） */
    process_plugin_slots_stage(h, 3, dst, frames);

    /* 响度补偿（Stage 3 后 / 安全钳位前：最后一道音色工序） */
    if (h->p.loudness_enable.load(std::memory_order_relaxed)) {
        loudness_process(h, dst, frames);
    }
    sample_stage_peak(h, 19, dst, frames);   /* Stage 19: Loudness output */

    /* 全局输出样本安全卫士：过滤 NaN / Inf 异常浮点并实施 [-10.0, +10.0] 极限钳位 */
    const int total_samples = frames * 2;
    for (int i = 0; i < total_samples; ++i) {
        float s = dst[i];
        if (std::isnan(s) || std::isinf(s)) {
            dst[i] = 0.0f;
        } else if (s > 10.0f) {
            dst[i] = 10.0f;
        } else if (s < -10.0f) {
            dst[i] = -10.0f;
        }
    }

    /* Stage 4: Post-Limiter（链尾，最终安全输出后） */
    process_plugin_slots_stage(h, 4, dst, frames);
}
