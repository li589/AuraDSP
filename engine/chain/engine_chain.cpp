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
        double freqs[7];
        double gains[7];
        for (int i = 0; i < 7; ++i) {
            freqs[i] = (double)h->p.comp_freq[i].load(std::memory_order_relaxed);
            gains[i] = (double)h->p.comp_gain[i].load(std::memory_order_relaxed);
        }
        CompressorSetGain(&h->jdsp, freqs, gains, 1);
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

/* 各声道的标准 -3dB 下混/上混系数 (1 / sqrt(2) ≈ 0.70710678) */
constexpr float kMxSqrtHalf = 0.70710678f;


/* M→2 下混 + 旁路声道留存。返回 false 表示 scratch 不可用（应直通）。
 * 彻底修复原实现中左右环绕串扰混入 L/R 的严重 Bug。 */
bool mx_downmix(auradsp_handle h, const float* in, float* stereo,
                              int frames, int ch) {
    float* keep = h->mx_scratch;                 /* frames*ch，用于存 LFE 等直通声道 */
    if (!keep || !stereo || !in) return false;

    for (int i = 0; i < frames; ++i) {
        const float* sp = in + (size_t)i * ch;
        float* kp = keep + (size_t)i * ch;
        float l = 0.0f, r = 0.0f;

        // 全量完整留存源输入至 keep
        for (int k = 0; k < ch; ++k) {
            kp[k] = sp[k];
        }

        if (ch == 2) {
            stereo[i * 2]     = sp[0];
            stereo[i * 2 + 1] = sp[1];
            continue;
        }

        if (ch == 4) {
            // Quad 4.0: FL(0), FR(1), BL(2), BR(3)
            l = sp[0] + sp[2] * kMxSqrtHalf;
            r = sp[1] + sp[3] * kMxSqrtHalf;
        } else {
            // 5.1 / 7.1 标准声道序:
            // 0: FL (左前) -> L
            // 1: FR (右前) -> R
            // 2: C  (中置) -> L+R 各 -3dB
            // 3: LFE (低音) -> 绝不进 L/R，保留在 scratch 中原样直通
            // 4: SL (左环绕) / 6: BL (左后) -> 仅进 L (-3dB)，绝不进 R
            // 5: SR (右环绕) / 7: BR (右后) -> 仅进 R (-3dB)，绝不进 L
            l = sp[0];
            r = sp[1];
            if (ch > 2) {
                const float c = sp[2] * kMxSqrtHalf;
                l += c;
                r += c;
            }
            if (ch >= 6) {
                l += sp[4] * kMxSqrtHalf;
                r += sp[5] * kMxSqrtHalf;
            }
            if (ch >= 8) {
                l += sp[6] * kMxSqrtHalf;
                r += sp[7] * kMxSqrtHalf;
            }
        }
        stereo[i * 2]     = l;
        stereo[i * 2 + 1] = r;
    }
    return true;
}


/* 2→M 上混：前置写处理后 L/R，环绕对号入座，中置取和，LFE 原样还原
 * 彻底修复原实现中环绕声道全部取右声道导致左右颠倒的严重 Bug。 */
void mx_upmix(auradsp_handle h, float* out, const float* stereo,
                            int frames, int ch) {
    const float* keep = h->mx_scratch;
    if (!keep || !out || !stereo) return;

    for (int i = 0; i < frames; ++i) {
        const float* sp = keep + (size_t)i * ch;
        float* dp = out + (size_t)i * ch;
        const float l = stereo[i * 2];
        const float r = stereo[i * 2 + 1];

        if (ch == 2) {
            dp[0] = l;
            dp[1] = r;
            continue;
        }

        if (ch == 4) {
            // Quad 4.0
            dp[0] = l;
            dp[1] = r;
            dp[2] = l * kMxSqrtHalf; // BL 严格回填 L
            dp[3] = r * kMxSqrtHalf; // BR 严格回填 R
        } else {
            // 5.1 / 7.1
            dp[0] = l;
            dp[1] = r;
            if (ch > 2) {
                dp[2] = (l + r) * 0.5f * kMxSqrtHalf; // Center: 居中单声道和
            }
            if (ch > 3) {
                dp[3] = sp[3];                        // LFE: 逐样本 100% bit-exact 直通还原
            }
            if (ch >= 6) {
                dp[4] = l * kMxSqrtHalf;              // SL: 严格取 L
                dp[5] = r * kMxSqrtHalf;              // SR: 严格取 R
            }
            if (ch >= 8) {
                dp[6] = l * kMxSqrtHalf;              // BL: 严格取 L
                dp[7] = r * kMxSqrtHalf;              // BR: 严格取 R
            }
        }
    }
}


/* 多声道电子管模拟 (Category A: 按 tube_channels 独立 waveshaper) */
void tube_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || ch <= 0 || frames <= 0) return;
    if (!h->p.tube_enable.load(std::memory_order_relaxed)) return;
    const uint32_t mask = (uint32_t)h->p.tube_channels.load(std::memory_order_relaxed);
    if ((mask & ((1u << ch) - 1u)) == 0) return;

    const float gain_db = h->p.tube_gain.load(std::memory_order_relaxed);
    const float pregain = powf(10.0f, gain_db * 0.05f);
    const float postgain = 1.0f / (pregain > 1e-4f ? pregain : 1.0f);
    const float mix = h->p.tube_mix.load(std::memory_order_relaxed);
    const float comp_db = h->p.tube_compensation.load(std::memory_order_relaxed);
    const float comp = powf(10.0f, comp_db * 0.05f);
    const int style = (int)h->p.tube_style.load(std::memory_order_relaxed);
    const bool os = h->p.tube_oversample.load(std::memory_order_relaxed) != 0;

    const int max_c = ch > kMxMaxChannels ? kMxMaxChannels : ch;
    for (int c = 0; c < max_c; ++c) {
        if (!(mask & (1u << c))) continue;
        for (int i = 0; i < frames; ++i) {
            const float x = io[i * ch + c];
            float drive = x * pregain;
            float sat;
            if (os) {
                sat = h->tube_os[c].process_sample(drive, [style](float d) {
                    if (style == 0) {
                        return d > 0.0f ? tanhf(d) : (d / (1.0f - d * 0.5f));
                    } else if (style == 1) {
                        return tanhf(d * 1.2f) * 0.833f;
                    } else {
                        float s = d - (d * d * d) / 3.0f;
                        if (s > 1.0f) return 1.0f;
                        if (s < -1.0f) return -1.0f;
                        return s;
                    }
                });
            } else {
                if (style == 0) {
                    sat = drive > 0.0f ? tanhf(drive) : (drive / (1.0f - drive * 0.5f));
                } else if (style == 1) {
                    sat = tanhf(drive * 1.2f) * 0.833f;
                } else {
                    sat = drive - (drive * drive * drive) / 3.0f;
                    if (sat > 1.0f) sat = 1.0f;
                    else if (sat < -1.0f) sat = -1.0f;
                }
            }
            float wet = sat * postgain * comp;
            io[i * ch + c] = x * (1.0f - mix) + wet * mix;
        }
    }
}


/* Modern Lookahead Limiter (P2.3 / P2.4)
 * - 1.5ms 前瞻环形延迟队列
 * - 4x ISP (Inter-Sample Peak) 三次埃尔米特插值真峰检测
 * - 前瞻增益窗口最小检波与平滑起音/单极点释放跟踪
 * - 声道独立 / 立体声增益联动支持 (limiter.link)
 * - GR (Gain Reduction) 实时分贝计量写入原子变量
 * - 绝对安全硬防护 (NaN/Inf 拦截与 10.0f 钳位)
 */
void limiter_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || ch <= 0 || frames <= 0) return;
    if (!h->p.limiter_enable.load(std::memory_order_relaxed)) return;

    const uint32_t mask = (uint32_t)h->p.limiter_channels.load(std::memory_order_relaxed);
    const int max_c = ch > kMxMaxChannels ? kMxMaxChannels : ch;

    const float thresh_db = h->p.limiter_threshold.load(std::memory_order_relaxed);
    const float threshold = std::pow(10.0f, (std::min)(0.0f, (std::max)(-24.0f, thresh_db)) / 20.0f);

    const float rel_ms = (std::min)(500.0f, (std::max)(10.0f, h->p.limiter_release_ms.load(std::memory_order_relaxed)));
    const float relCoef = (float)std::exp(-1.0 / ((double)rel_ms * 0.001 * (double)h->sample_rate));
    const float attCoef = (float)(1.0 - std::exp(-1.0 / (0.00035 * (double)h->sample_rate)));

    const int la_len = (h->mc_limiter_la_len > 0) ? (std::min)(h->mc_limiter_la_len, (int)auradsp_handle_s::kLimLookaheadMax) : 72;
    const bool link_mode = (h->p.limiter_link.load(std::memory_order_relaxed) != 0);

    float min_block_gain = 1.0f;

    const bool use_la = (h->p.limiter_lookahead.load(std::memory_order_relaxed) != 0);

    for (int i = 0; i < frames; ++i) {
        float step_targets[kMxMaxChannels];
        float linked_target = 1.0f;

        // 第一遍：选定声道真峰检波 (4x ISP)
        for (int c = 0; c < max_c; ++c) {
            if (!(mask & (1u << c))) continue;
            float s = io[i * ch + c];
            float s_next = (i + 1 < frames) ? io[(i + 1) * ch + c] : s;
            float p = auradsp::cubic_hermite_true_peak(
                h->mc_limiter_prev[c][0],
                h->mc_limiter_prev[c][1],
                s,
                s_next
            );
            h->mc_limiter_prev[c][0] = h->mc_limiter_prev[c][1];
            h->mc_limiter_prev[c][1] = s;

            float g = (p > threshold && p > 1e-9f) ? (threshold / p) : 1.0f;
            step_targets[c] = g;
            if (g < linked_target) linked_target = g;
        }

        // 第二遍：增益施加 (分支：1.5ms 高精母带前瞻模式 vs 0ms 零延迟实时模式)
        for (int c = 0; c < max_c; ++c) {
            if (!(mask & (1u << c))) continue;

            float g_target = link_mode ? linked_target : step_targets[c];
            float final_s = 0.0f;
            float current_gain = 1.0f;

            if (use_la) {
                // 1.5ms 高精母带前瞻模式：环形延迟线 + 前向最小增益淡入
                int pos = h->mc_limiter_la_pos[c];
                h->mc_limiter_la_buf[c][pos] = io[i * ch + c];
                h->mc_limiter_gain_buf[c][pos] = g_target;

                int read_pos = (pos + 1) % la_len;
                float delayed_s = h->mc_limiter_la_buf[c][read_pos];

                float win_min_g = 1.0f;
                for (int k = 0; k < la_len; ++k) {
                    float gb = h->mc_limiter_gain_buf[c][k];
                    if (gb < win_min_g) win_min_g = gb;
                }

                float env_rel = h->mc_limiter_env[c];
                if (win_min_g < env_rel) {
                    env_rel = win_min_g;
                } else {
                    env_rel += (1.0f - relCoef) * (win_min_g - env_rel);
                }
                h->mc_limiter_env[c] = env_rel;

                float env_la = h->mc_limiter_la_env[c];
                if (env_rel < env_la) {
                    env_la += attCoef * (env_rel - env_la);
                } else {
                    env_la = env_rel;
                }
                h->mc_limiter_la_env[c] = env_la;
                current_gain = env_la;
                final_s = delayed_s * current_gain;

                h->mc_limiter_la_pos[c] = read_pos;
            } else {
                // 0ms 实时零延迟模式：瞬时检波 + 平滑释放跟踪，输入未超载时 100% 逐样本零相移直通
                float env = h->mc_limiter_env[c];
                if (g_target < env) {
                    env = g_target;
                } else {
                    env += (1.0f - relCoef) * (g_target - env);
                }
                h->mc_limiter_env[c] = env;
                current_gain = env;
                final_s = io[i * ch + c] * current_gain;
            }

            // 门限硬防护
            if (std::fabs(final_s) > threshold) {
                final_s = (final_s > 0.0f) ? threshold : -threshold;
            }

            // 安全防护
            if (std::isnan(final_s) || std::isinf(final_s)) {
                final_s = 0.0f;
            } else if (final_s > 10.0f) {
                final_s = 10.0f;
            } else if (final_s < -10.0f) {
                final_s = -10.0f;
            }

            io[i * ch + c] = final_s;

            if (current_gain < min_block_gain) {
                min_block_gain = current_gain;
            }
        }
    }

    // 块末原子写入增益衰减分贝 (GR >= 0 dB)
    float gr_db = 0.0f;
    if (min_block_gain < 0.9999f && min_block_gain > 1e-6f) {
        gr_db = -20.0f * (float)std::log10((double)min_block_gain);
    }
    h->gr_limiter.store(gr_db, std::memory_order_relaxed);
}


/* 离散多声道处理链本体 (Phase B: Category A 独立单声道滤波 + Category B 声场保持) */
void process_multichannel_chain(auradsp_handle h, const float* src, float* dst, int frames, int ch) {
    if (!h || !src || !dst || frames <= 0 || ch <= 0) return;

    // 1. 全量拷贝至目标工作区，就地推进
    memcpy(dst, src, (size_t)frames * ch * sizeof(float));

    // 2. 前级 Category A 效果器（支持 8 声道独立按掩码处理）
    if (h->p.gate_enable.load(std::memory_order_relaxed)) {
        gate_process_mc(h, dst, frames, ch);
    }
    if (h->p.filter_enable.load(std::memory_order_relaxed)) {
        filter_process_mc(h, dst, frames, ch);
    }
    if (h->p.shelf_enable.load(std::memory_order_relaxed) &&
        h->p.shelf_gain.load(std::memory_order_relaxed) != 0.0f) {
        shelf_process_mc(h, dst, frames, ch);
    }
    if (h->p.dyneq_enable.load(std::memory_order_relaxed)) {
        dyneq_process_mc(h, dst, frames, ch);
    }
    if (h->p.tube_enable.load(std::memory_order_relaxed)) {
        tube_process_mc(h, dst, frames, ch);
    }

    // 3. Category B 跨声道/声场效果器与前置 FL/FR vendor 核心（仅作用于前置立体声对，保持环绕声场完整性）
    if (h->shelf_scratch && h->mx_stereo) {
        for (int i = 0; i < frames; ++i) {
            h->shelf_scratch[i * 2]     = dst[i * ch + 0];
            h->shelf_scratch[i * 2 + 1] = dst[i * ch + 1];
        }

        if (h->p.bassmono_enable.load(std::memory_order_relaxed)) {
            bassmono_process(h, h->shelf_scratch, frames);
        }
        if (h->p.bass_enable.load(std::memory_order_relaxed)) {
            basspsycho_process(h, h->shelf_scratch, frames);
        }

        process_plugin_slots_stage(h, 0, h->shelf_scratch, frames);
        process_plugin_slots_stage(h, 1, h->shelf_scratch, frames);

        const int tube_saved = h->jdsp.tubeEnabled;
        const int limiter_saved = h->jdsp.limiterEnabled;
        h->jdsp.tubeEnabled = 0;
        h->jdsp.limiterEnabled = 0;
        h->jdsp.processFloatMultiplexd(&h->jdsp, h->shelf_scratch, h->mx_stereo, (size_t)frames);
        h->jdsp.tubeEnabled = tube_saved;
        h->jdsp.limiterEnabled = limiter_saved;

        process_plugin_slots_stage(h, 2, h->mx_stereo, frames);

        if (h->p.haas_enable.load(std::memory_order_relaxed)) {
            haas_process(h, h->mx_stereo, frames);
        }
        if (h->p.spatial_enable.load(std::memory_order_relaxed)) {
            spatial_process(h, h->mx_stereo, frames);
        }
        freeverb_process(h, h->mx_stereo, frames);

        process_plugin_slots_stage(h, 3, h->mx_stereo, frames);

        for (int i = 0; i < frames; ++i) {
            dst[i * ch + 0] = h->mx_stereo[i * 2];
            dst[i * ch + 1] = h->mx_stereo[i * 2 + 1];
        }
    }

    // 4. 后级 Category A 效果器（支持 8 声道独立按掩码处理）
    if (h->p.exciter_enable.load(std::memory_order_relaxed)) {
        exciter_process_mc(h, dst, frames, ch);
    }
    if (h->p.loudness_enable.load(std::memory_order_relaxed)) {
        loudness_process_mc(h, dst, frames, ch);
    }
    limiter_process_mc(h, dst, frames, ch);

    // 5. 全局多声道输出样本安全卫士：过滤 NaN / Inf 异常浮点并实施 [-10.0, +10.0] 极限钳位
    const int total_samples = frames * ch;
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
    /* P2.4: 提取 Compressor GR 实时计量 */
    h->gr_comp.store(h->p.comp_enable.load(std::memory_order_relaxed) ? h->jdsp.comp_gr : 0.0f,
                     std::memory_order_relaxed);

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

    /* Modern Lookahead Limiter (P2.3 立体声母带限幅) */
    limiter_process_mc(h, dst, frames, 2);

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
