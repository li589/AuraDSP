/* P2 split from auradsp_engine.cpp; Phase 3 routes plugin stages through PluginChainComponent. */
#include "engine_internal.h"
#include "plugins/integration/plugin_chain_adapter.h"



/* 计算当前启用组合的附加延迟（ms）——纯测量。
 * ADR-006：延迟档硬约束已撤销，此函数只累加并上报，
 * 永远不返回「超档」，也不再导致任何使能请求被拒绝。
 *
 * D1：所有项走 LatencyMs()，不再直接累加 `.ms`。
 * D7：结构性帧数一律按**工作采样率**（jdsp.fs）换算——ASRC 启用时 DSP 跑在
 * 48k/44.1k 域，帧数属于那个域；拿设备率（h->sample_rate）换算会低估
 * inFs/fs 倍（96k 下 2 倍）。名义值（frames==0）本就与采样率无关，照旧。 */
void compute_latency(auradsp_handle h, double* out_ms) {
    double ms = 0.0;
    const double sr = (double)h->sample_rate;          /* 设备/流采样率 */
    const double wsr = (double)h->jdsp.fs;             /* 工作采样率（=sr 除非 ASRC） */
    const double lat_sr = (wsr > 0.0) ? wsr : sr;      /* 结构性帧数的换算基准 */
    if (h->p.limiter_enable.load(std::memory_order_relaxed)) {
        /* D7：limiter 的延迟取决于模式，且默认模式是 0ms（原表写死 2.0ms
         * 名义值，默认配置下平白高估 2ms）。见 engine_internal.h kLatDdc 后注释。 */
        if (h->p.limiter_lookahead.load(std::memory_order_relaxed) != 0) {
            /* 前瞻环形缓冲：写入 pos 后从 (pos+1)%la_len 读 → 实占 la_len-1 帧。
             * la_len 按 fs 缩放，故时间恒定 ~1.5ms；延迟线在 wrapper 层（ASRC
             * 之外），用设备采样率换算。上限与 limiter_process_mc 一致。 */
            int la_len = (int)(0.0015 * sr + 0.5);
            if (la_len < 1) la_len = 1;
            if (la_len > auradsp_handle_s::kLimLookaheadMax)
                la_len = auradsp_handle_s::kLimLookaheadMax;
            ms += FramesToMs((double)(la_len - 1), sr);
        }
    }
    if (h->p.reverb_preset.load(std::memory_order_relaxed) != -1 &&
        reverb_path_kind(h) == 0) {
        /* 只有 vendor Progenitor2 路径有 30ms 结构延迟；MC FDN 在链内
         * 直接处理，报告 0ms。 */
        ms += LatencyMs(kLatReverb, lat_sr);
    }
    /* 卷积：IR 已加载且使能时计入 */
    if (h->p.conv_enable.load(std::memory_order_relaxed) &&
        h->ir_ready.load(std::memory_order_relaxed)) {
        ms += LatencyMs(kLatConvolver, lat_sr);
    }
    if (h->p.xfeed_enable.load(std::memory_order_relaxed)) ms += LatencyMs(kLatCrossfeed, lat_sr);
    /* VDC = 动态范围均衡器，延迟极低。此前 kLatDdc 定义了却从未计入，
     * 导致 VDC 开启时总延迟被低估。 */
    if (h->p.ddc_enable.load(std::memory_order_relaxed) &&
        h->p.ddc_ready.load(std::memory_order_relaxed)) {
        ms += LatencyMs(kLatDdc, lat_sr);
    }
    if (h->p.comp_enable.load(std::memory_order_relaxed)) {
        /* D7 + B1-d：comp 的延迟 = (fftLen - ovpLen) 帧（随 tfresolution 变）+ 启动
         * 缺额 D。D 与「块长是否整除 hop」有关，不是 0/全有 的二值门槛：
         *   · 块长 >= ovpLen 或整除 ovpLen → D = 0，延迟 = fftLen-ovpLen；
         *   · 否则 D = ovpLen - gcd(ovpLen, 完整工作块长)，最多 ovpLen-1 帧。
         * 详见 engine_internal.h 的 kCompLatProfile 注释与 B1-d 实测数据。 */
        const int tf = h->p.comp_tfresolution.load(std::memory_order_relaxed);
        const CompLatencyProfile& cp = kCompLatProfile[(tf >= 0 && tf <= 3) ? tf : 1];
        if (cp.frames > 0 && cp.ovpLen > 0) {
            /* jdsp.blockSize 是**设备域**块长（pint16 等入口写入 n），
             * 换算成工作域帧数后才能和 ovpLen 比。首次处理前为 0 时回落
             * 创建时的 max_block（一块的上界）。 */
            size_t devBlk = h->jdsp.blockSize;
            if (devBlk == 0) devBlk = (size_t)(h->max_block > 0 ? h->max_block : 0);
            const double ratio = (sr > 0.0) ? (lat_sr / sr) : 1.0;
            const size_t workBlk = (size_t)((double)devBlk * ratio + 0.5);
            const unsigned int deficit = CompressorStartupDeficit(
                (unsigned int)cp.ovpLen, (unsigned int)workBlk);
            ms += FramesToMs((double)(cp.frames + (int)deficit), lat_sr);
        }
    }
    if (h->p.arbmag_enable.load(std::memory_order_relaxed) &&
        h->p.arbmag_ready.load(std::memory_order_relaxed)) {
        /* D1/D7：arbmag 用分块 FFT 卷积，附加延迟就是**单块帧数**（卷积器按
         * jdsp->blockSize 加载 IR）。块长存的是设备域帧数，先折到工作域，
         * 再按工作域采样率换算——两者相除即真实时长。为 0（尚未处理过任何
         * 块）时回落引擎创建时给的 max_block，它正是一块的上界。 */
        size_t devBlk = h->jdsp.blockSize;
        if (devBlk == 0) devBlk = (size_t)(h->max_block > 0 ? h->max_block : 0);
        const double ratio = (sr > 0.0) ? (lat_sr / sr) : 1.0;
        const size_t workBlk = (size_t)((double)devBlk * ratio + 0.5);
        ms += FramesToMs((double)workBlk, lat_sr);
    }
    /* Haas = 纯延迟线，按当前设定值动态上报（0..25ms，Viper 差分环绕同量级）。
     * 这是**用户设的毫秒值**（延迟线内部按 ms*sr 折算样本），不做采样率换算。 */
    if (h->p.haas_enable.load(std::memory_order_relaxed)) {
        float dms = h->p.haas_delay_ms.load(std::memory_order_relaxed);
        if (dms < 0.0f) dms = 0.0f; if (dms > 25.0f) dms = 25.0f;
        ms += (double)dms;
    }
    /* 空间音效：直达径 ITD 名义 1ms（早期反射/混响尾是并行能量，不计入；
     * 与 reverb 30ms 名义口径一致）。 */
    if (h->p.spatial_enable.load(std::memory_order_relaxed)) {
        ms += LatencyMs(kLatSpatial, lat_sr);
    }
    /* D7：ASRC 中转环形缓冲的结构延迟（实测其它部分落在噪声内，见头注释）。
     * 只在 ASRC 真正启用时计入，否则 inFs==fs、该式为 0 也无意义。 */
    if (h->jdsp.enableASRC) {
        ms += AsrcRingLatencyMs(sr, lat_sr);
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
    /* WP1 混响边界（工程文档 §3.2）：同一时刻只允许一套混响运行。
     *   立体声/矩阵/双耳路径 → vendor Progenitor2；
     *   离散多声道路径       → MC FDN（dsp_mc_reverb.cpp）。
     * -1 关；-2 自定义（WP2：立体声路径走 vendor 原生参数；MC 路径走 FDN 自定义映射）。 */
    if (reverb_path_kind(h) == 0 && rv != -1) {
        if (rv >= 0) {
            Reverb_SetParam(j, rv);   /* 重建混响（仅预设真正变化时调用） */
        } else if (rv == -2) {
            /* [PATCHED-AuraDSP P-033] 立体声自定义混响：将 freeverb.* 与 reverb.predelay
             * 映射为 vendor Progenitor2 原生参数（文档 §3.4）。 */
            auto clamp_f = [](float v, float lo, float hi) -> float {
                return v < lo ? lo : (v > hi ? hi : v);
            };
            AuraReverbNativeParams np;
            const float decay = clamp_f(h->p.fv_decay.load(std::memory_order_relaxed), 0.0f, 1.0f);
            const float damp = clamp_f(h->p.fv_damp.load(std::memory_order_relaxed), 0.0f, 1.0f);
            const float wet = clamp_f(h->p.fv_wet.load(std::memory_order_relaxed), 0.0f, 1.0f);
            const float dry = clamp_f(h->p.fv_dry.load(std::memory_order_relaxed), 0.0f, 1.0f);
            const float room = clamp_f(h->p.fv_roomsize.load(std::memory_order_relaxed), 0.5f, 2.5f);
            const float width = clamp_f(h->p.fv_width.load(std::memory_order_relaxed), 0.0f, 1.0f);
            const float predelay = clamp_f(h->p.reverb_predelay.load(std::memory_order_relaxed), 0.0f, 100.0f);

            np.oversamplefactor = 1;
            np.ertolate = (wet < 0.001f) ? 0.0f : 0.3f;
            np.dry_db = (dry < 0.001f) ? -100.0f : clamp_f(20.0f * log10f(dry), -100.0f, 0.0f);
            np.wet_db = (wet < 0.001f) ? -100.0f : clamp_f(20.0f * log10f(wet), -100.0f, 0.0f);
            np.erefwet_db = (wet < 0.001f) ? -100.0f : clamp_f(np.wet_db - 9.0f, -100.0f, 0.0f);
            np.ereffactor = room;
            np.erefwidth = 0.7f;
            np.width = width;
            np.wander = 0.2f;
            np.bassb = 0.15f;
            np.spin = 0.7f;
            np.inputlpf_hz = 18000.0f;
            np.basslpf_hz = 500.0f;
            np.damplpf_hz = 18000.0f * powf(1000.0f / 18000.0f, damp);
            np.outputlpf_hz = 12000.0f;
            np.rt60_s = 0.5f + 9.5f * decay;
            np.delay_s = predelay / 1000.0f;

            Reverb_SetNative(j, &np);
        }
        ReverbEnable(j);
    } else {
        ReverbDisable(j);
    }
}

/* WP0 脚手架：混响路径判定（工程文档 §2）。
 *   0 = vendor Progenitor2 立体声路径：矩阵模式（channels.mode==0），
 *       或双耳路径（spatial.binaural && spatial.enable && count>=4）。
 *   1 = 离散多声道 MC FDN 路径：其余情况（含 mode=1 + count=2）。
 * 注意与 UI 的 stereoPath 不同：mode=1 + count=2 仍按 MC FDN 处理。
 * reverb.engine 只读参数与 WP1 的 apply_reverb 必须共用本判定。 */
int reverb_path_kind(auradsp_handle h) {
    if (!h) return 1;
    if (h->p.channels_mode.load(std::memory_order_relaxed) == 0) return 0;
    const bool binaural =
        h->p.spatial_binaural.load(std::memory_order_relaxed) != 0 &&
        h->p.spatial_enable.load(std::memory_order_relaxed) != 0 &&
        h->channel_count.load(std::memory_order_relaxed) >= 4;
    return binaural ? 0 : 1;
}

/* WP0 脚手架：拓扑变化（channels.mode/count、binaural、spatial.enable）
 * 的统一状态清理入口。当前为空实现，WP6 落地；届时逐模块清理：
 *   gate            gate_gain/state/hold/env/ds_lp/ds_env
 *   filter / shelf  z1/z2[8]
 *   dyneq           3 段 det_z1/det_z2/env/z1/z2
 *   tube            tube_process_mc 内部逐声道状态
 *   exciter/loudness 逐声道 one-pole / 包络
 *   limiter         mc_limiter_* 环/包络/deque
 *   bassmono/basspsycho  bm_lp[8] / psy_*
 *   haas            haas_ring
 *   spatial         spatial_reset(h)
 *   MC reverb       mc_reverb_reset(h)（WP1 新增）
 *   comp/eq/arbmag 池  逐声道实例 reset（卷积 FIFO 清零）
 *   vendor 段       apply_reverb(h) + 必要的 vendor refresh（P-036 预留）
 * 调用点（WP6）：set_channels_mode/count、hook_spatial_binaural、
 * hook_spatial_enable；set_reverb_preset 只重置混响状态，不全量 reset。
 * 控制线程调用；不得在音频线程执行。 */
void reset_channel_state(auradsp_handle h) {
    if (!h) return;

    /* 1. gate */
    for (int c = 0; c < kMxMaxChannels; ++c) {
        h->gate_gain[c] = 1.0f;
        h->gate_state[c] = 1.0f;
        h->gate_hold_cnt[c] = 0;
        h->gate_env[c] = 0.0f;
        h->gate_ds_lp[c] = 0.0f;
        h->gate_ds_env[c] = 0.0f;
    }
    h->gate_ag_in = 0.0;
    h->gate_ag_out = 0.0;
    h->gate_ag_comp = 1.0;
    h->gate_ag_g_sm = 1.0f;

    /* 2. filter / shelf */
    for (int c = 0; c < kMxMaxChannels; ++c) {
        h->shelf.z1[c] = 0.0;
        h->shelf.z2[c] = 0.0;
        h->filter.z1[c] = 0.0;
        h->filter.z2[c] = 0.0;
    }

    /* 3. dyneq */
    for (int b = 0; b < 3; ++b) {
        for (int c = 0; c < kMxMaxChannels; ++c) {
            h->dyneq_b[b].det_z1[c] = 0.0;
            h->dyneq_b[b].det_z2[c] = 0.0;
            h->dyneq_b[b].env[c] = 0.0;
            h->dyneq_b[b].z1[c] = 0.0;
            h->dyneq_b[b].z2[c] = 0.0;
        }
    }

    /* 4. tube */
    for (int c = 0; c < kMxMaxChannels; ++c) {
        h->tube_os[c].reset();
    }

    /* 5. exciter / loudness */
    for (int c = 0; c < kMxMaxChannels; ++c) {
        h->exc_lp[c] = 0.0f;
        h->exc_os[c].reset();
        h->loud_lp[c] = 0.0f;
        h->loud_hp[c] = 0.0f;
    }
    h->loud_level = 0.0;

    /* 6. limiter */
    for (int c = 0; c < kMxMaxChannels; ++c) {
        h->mc_limiter_env[c] = 1.0f;
        h->mc_limiter_la_env[c] = 1.0f;
        h->mc_limiter_la_pos[c] = 0;
        h->mc_limiter_dq_head[c] = 0;
        h->mc_limiter_dq_count[c] = 0;
        h->mc_limiter_prev[c][0] = 0.0f;
        h->mc_limiter_prev[c][1] = 0.0f;
        for (int k = 0; k < auradsp_handle_s::kLimLookaheadMax; ++k) {
            h->mc_limiter_la_buf[c][k] = 0.0f;
            h->mc_limiter_gain_buf[c][k] = 1.0f;
        }
    }
    h->mc_limiter_dq_len = 0;

    /* 7. bassmono / basspsycho */
    for (int c = 0; c < 8; ++c) {
        h->bm_lp[c] = 0.0f;
    }
    h->bm_reinit.store(0, std::memory_order_relaxed);
    h->psy_lp_l = 0.0f;
    h->psy_lp_r = 0.0f;
    h->psy_sub_l = 0.0f;
    h->psy_sub_r = 0.0f;
    h->psycho_os[0].reset();
    h->psycho_os[1].reset();

    /* 8. haas */
    if (h->haas_ring && h->haas_ring_len > 0) {
        memset(h->haas_ring, 0, sizeof(float) * h->haas_ring_len);
        h->haas_pos = 0;
    }

    /* 9. spatial */
    spatial_reset(h);

    /* 10. MC reverb */
    mc_reverb_reset(h);
    h->rev_ag_in = 0.0;
    h->rev_ag_out = 0.0;
    h->rev_ag_comp = 1.0;
    h->rev_g_sm = 1.0f;

    /* 11. arbmag_pool */
    if (h->arbmag_pool.loaded) {
        arbmag_pool_reload(h);
    }
    if (h->eq_pool.loaded) {
        eq_pool_reload(h);
    }

    /* 12. vendor 段 */
    if (h->open.load()) {
        apply_reverb(h);
    }

    /* 13. post_gain 平滑状态 (WP5) */
    for (int c = 0; c < 8; ++c) {
        h->post_gain_sm[c] = 1.0f;
    }

    /* 14. liveprog 环境感知 [PATCHED-AuraDSP P-038] */
    const int cur_ch = h->channel_count.load(std::memory_order_relaxed);
    LiveProgSetChannels(&h->jdsp, cur_ch > 0 ? cur_ch : 2);
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
    /* [PATCHED-AuraDSP P-030] eq.enable=0 必须真的关掉 vendor EQ。
     * 上游 MultimodalEqualizerEnable 只有 `if (enable) equalizerEnabled = 1;`
     * ——**没有 else 分支**，标志位一旦置 1 就永不归零；上游另有一个
     * MultimodalEqualizerDisable 才做归零，但宿主从不调它。结果：用户把
     * eq.enable 关掉后 EQ 仍在处理音频（实测 96k：enable=1 → -6.01dB，
     * enable=0 → -6.01dB，完全不变）。
     * 修法（改宿主而非上游，降低同步冲突风险）：关态显式调 Disable。
     * equalizerForceRefresh 的消费留在 Enable 分支内——关态不消费，
     * 下次打开时会重建一次 IR（这正是想要的语义）。 */
    if (h->p.eq_enable.load(std::memory_order_relaxed)) {
        MultimodalEqualizerEnable(&h->jdsp, 1);
        eq_pool_reload(h);
    } else {
        MultimodalEqualizerDisable(&h->jdsp);
    }
}


void apply_post(auradsp_handle h) {
    JamesDSPSetPostGain(&h->jdsp, h->p.post_gain.load(std::memory_order_relaxed));
    JamesDSPSetPostGainCh(&h->jdsp, 0, h->p.post_gain_ch[0].load(std::memory_order_relaxed));
    JamesDSPSetPostGainCh(&h->jdsp, 1, h->p.post_gain_ch[1].load(std::memory_order_relaxed));
}

/* 多声道输出增益与逐声道 trim (Category A, Step 15) */
void post_gain_process_mc(auradsp_handle h, float* io, int frames, int ch) {
    if (!h || !io || frames <= 0 || ch <= 0) return;

    const float master_db = h->p.post_gain.load(std::memory_order_relaxed);
    const float fs = (h->sample_rate > 0.0f) ? (float)h->sample_rate : 48000.0f;
    const float alpha = expf(-(float)frames / (0.010f * fs));

    bool all_unity = (fabsf(master_db) < 1e-5f);
    float target_g[8];
    const int max_c = (ch > 8) ? 8 : ch;
    for (int c = 0; c < max_c; ++c) {
        const float ch_db = h->p.post_gain_ch[c].load(std::memory_order_relaxed);
        if (fabsf(ch_db) >= 1e-5f) all_unity = false;
        target_g[c] = powf(10.0f, (master_db + ch_db) * 0.05f);
    }

    if (all_unity) {
        bool fully_settled = true;
        for (int c = 0; c < max_c; ++c) {
            if (fabsf(h->post_gain_sm[c] - 1.0f) >= 1e-5f) {
                fully_settled = false;
                break;
            }
        }
        if (fully_settled) return; /* 全 0dB 时逐样本 bit-exact 直通 */
    }

    float g[8];
    for (int c = 0; c < max_c; ++c) {
        h->post_gain_sm[c] = alpha * h->post_gain_sm[c] + (1.0f - alpha) * target_g[c];
        if (fabsf(h->post_gain_sm[c] - target_g[c]) < 1e-5f) {
            h->post_gain_sm[c] = target_g[c];
        }
        g[c] = h->post_gain_sm[c];
    }

    for (int i = 0; i < frames; ++i) {
        for (int c = 0; c < max_c; ++c) {
            io[i * ch + c] *= g[c];
        }
    }
}


/* P-010：bass/eq/tube/comp 输出增益门 + 自动补偿落地 vendor stage。
 * P-033（WP1）：reverb 扩展为 fx 槽 5，Freeverb 退役后 vendor 路径不丢功能。
 * 每项独立下推，无 vendor 锁（对齐 float 写，x86 原子；切态重置在 vendor 内）。 */
void apply_fx_gains(auradsp_handle h) {
    static constexpr struct { std::atomic<float> Params::*db;
                              std::atomic<int32_t> Params::*on; int fx; } kFx[] = {
        { &Params::tube_outgain, &Params::tube_autogain, 0 },
        { &Params::comp_outgain, &Params::comp_autogain, 1 },
        { &Params::bass_outgain, &Params::bass_autogain, 2 },
        { &Params::eq_outgain,     &Params::eq_autogain,     3 },
        { &Params::arbmag_outgain, &Params::arbmag_autogain, 4 },
        { &Params::reverb_outgain, &Params::reverb_autogain, 5 },
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
        /* [PATCHED-AuraDSP P-018 B1-c] compander 控制侧重置改影子构建 + 原子换
         * 指针（CompressorCommit，同 B1-a liveprog / B1-b ddc 范式），
         * 替代 Z13 的「RT stage_comp 持 jdsp_lock + 此处同锁」全程互斥。
         * 背景：CompressorSetParam(forceRefresh=1) 做 FFTCompanderInit
         * 全量重算（2026-10-23 minidump：拖 comp.gain 滑块即崩，根因是
         * 重置与 RT 消耗无互斥致 mOutputBufferCount 减成 -1 越界空写）；
         * Z13 用互斥关闭了竞争，但持锁时长即重建时长——参数频调时 RT
         * 反复卡死。影子方案下 RT 块首只读一次 compActive 快照，控制
         * 线程在非活动槽重建后原子换指针，两侧零交集。
         * -4（引擎忙：RT 卡在 comp 内 >500ms 的极端场景）时旧快照继续
         * 生效，p-struct 已存新值，下一次任意 comp.* 变更会补上——
         * 不静音、不退化到活动槽原地重建（UAF）。 */
        double freqs[7];
        double gains[7];
        for (int i = 0; i < 7; ++i) {
            freqs[i] = (double)h->p.comp_freq[i].load(std::memory_order_relaxed);
            gains[i] = (double)h->p.comp_gain[i].load(std::memory_order_relaxed);
        }
        CompressorCommit(&h->jdsp,
                         h->p.comp_timeconstant.load(std::memory_order_relaxed),
                         h->p.comp_granularity.load(std::memory_order_relaxed),
                         h->p.comp_tfresolution.load(std::memory_order_relaxed),
                         1, freqs, gains, 1, 1);
        /* 本次提交自带 forceRefresh=1（全量 Init），已覆盖挂起的刷新语义
         * （JamesDSPSetSampleRate 置位的 compForceRefresh），顺手消费避免
         * 下一次 CompressorEnable 重复全量重建。 */
        h->jdsp.compForceRefresh = 0;
        h->jdsp.compEnabled = 1;
    } else {
        /* 关闭只写 enabled 标志（x86 对齐 int 原子；RT 最多少停用一块），
         * 无结构变更，无需任何互斥。 */
        CompressorDisable(&h->jdsp);
    }
}


void apply_arbmag(auradsp_handle h) {
    if (h->p.arbmag_enable.load(std::memory_order_relaxed) &&
        h->p.arbmag_ready.load(std::memory_order_relaxed)) {
        ArbitraryResponseEqualizerEnable(&h->jdsp, 1);
        /* B5 后续：主 conv 就绪的同时把逐声道池同步到同一 IR（控制线程）。 */
        arbmag_pool_reload(h);
    } else {
        ArbitraryResponseEqualizerDisable(&h->jdsp);
    }
}


/* B5 后续：arbmag 逐声道池（8×FFTConvolver1x1，IR 与主 arbMag.conv 同源）。
 * 线程契约：alloc/free/reload 全部控制线程；RT 线程只读池指针与 loaded 标志。
 * 内容等价性：同一 eqFil、同一 blockSize 下，1x1 输出 == 2x2 对应声道输出
 * （独立 inputBuffer/segments，无跨声道状态）。 */
void arbmag_pool_alloc(auradsp_handle h) {
    if (!h) return;
    for (int c = 0; c < kMxMaxChannels; ++c) {
        if (!h->arbmag_pool.conv[c]) {
            auto* conv = new (std::nothrow) FFTConvolver1x1();
            if (!conv) return; /* OOM：保持空位，process 侧直通 */
            FFTConvolver1x1Init(conv);
            h->arbmag_pool.conv[c] = conv;
        }
    }
}

void arbmag_pool_free(auradsp_handle h) {
    if (!h) return;
    for (int c = 0; c < kMxMaxChannels; ++c) {
        if (h->arbmag_pool.conv[c]) {
            FFTConvolver1x1Free(h->arbmag_pool.conv[c]);
            delete h->arbmag_pool.conv[c];
            h->arbmag_pool.conv[c] = nullptr;
        }
    }
    h->arbmag_pool.loaded = 0;
}

/* 控制线程：用当前 GetFilter(eqFil) 同步重载全池。IR 源与主 conv 完全相同
 * （同一 coeffGen.GetFilter(fs) 调用——注意主链 StringParser/Enable 的
 * ForceRefresh 路径也会重算 eqFil；池与主 conv 共用同一份，不存在漂移）。 */
void arbmag_pool_reload(auradsp_handle h) {
    if (!h) return;
    const unsigned block = (unsigned)h->jdsp.blockSize;
    if (block == 0) { h->arbmag_pool.loaded = 0; return; }
    float* eqFil = h->jdsp.arbMag.instance.coeffGen.GetFilter(
        &h->jdsp.arbMag.instance.coeffGen, (float)h->sample_rate);
    if (!eqFil) { h->arbmag_pool.loaded = 0; return; }
    const unsigned irLen = h->jdsp.arbMag.instance.filterLen;
    for (int c = 0; c < kMxMaxChannels; ++c) {
        auto* conv = h->arbmag_pool.conv[c];
        if (!conv) { h->arbmag_pool.loaded = 0; return; }
        if (!FFTConvolver1x1LoadImpulseResponse(conv, block, eqFil, irLen)) {
            h->arbmag_pool.loaded = 0;
            return;
        }
    }
    h->arbmag_pool.loaded = 1;
}

/* RT 线程：交织缓冲单声道处理（无分配、无锁）。
 * 选中（mask 位 && enable && ready && 池已装载）→ 抽 mono 进 shelf_scratch、
 * 1x1 卷积、应用输出增益门 fxOutGain[4]（静态线性增益；autogain 为逐块平滑，
 * 多声道逐声道路径不重复应用共享平滑状态——保持与单声道场景一致的确定性），
 * 写回交织缓冲。未选中 → 原样直通。 */
static inline float* arbmag_pool_get_scratch(auradsp_handle h) {
    return h && h->shelf_scratch ? h->shelf_scratch : nullptr;
}
void arbmag_pool_process_strided(auradsp_handle h, float* io, int frames,
                                 int nch, int ch_idx) {
    if (!h || !io || frames <= 0 || nch <= 0 || ch_idx < 0 || ch_idx >= nch)
        return;
    if (!(h->p.arbmag_channels.load(std::memory_order_relaxed) & (1u << ch_idx)))
        return;
    if (!h->p.arbmag_enable.load(std::memory_order_relaxed) ||
        !h->p.arbmag_ready.load(std::memory_order_relaxed))
        return;
    auto* conv = h->arbmag_pool.conv[ch_idx];
    if (!conv || !h->arbmag_pool.loaded) return;
    float* scratch = arbmag_pool_get_scratch(h);
    if (!scratch) return;
    float* in = io + ch_idx;
    for (int i = 0; i < frames; ++i) scratch[i] = in[(size_t)i * nch];

    FFTConvolver1x1Process(conv, scratch, scratch, (unsigned)frames);

    const float g = h->jdsp.fxOutGain[4]; /* 线性输出增益门（apply_fx_gains 下推） */
    if (g == 1.0f) {
        for (int i = 0; i < frames; ++i) in[(size_t)i * nch] = scratch[i];
    } else {
        for (int i = 0; i < frames; ++i) in[(size_t)i * nch] = scratch[i] * g;
    }
}


/* [Phase B 多声道电平] MC 版 stage 峰值采样：按 stride ch 逐声道扫描，
 * 同写 stage_peak_ch[stage][0..ch-1] 与 stage_peak_l/r（取 ch0/ch1）。
 *
 * l/r 列同步写是为了修复 MC 模式下 stage_levels_* 遥测 stale：MC 链不走
 * process_stereo_chain，旧实现里这些槽位停留在上次 stereo 块的值。
 * stereo 路径不调本函数（继续走 sample_stage_peak，逐位不变）。
 * [ch..7] 置 0：emit_viz 对 0 峰值转 -120，诚实表达「该声道不过此效果」。
 * 定义置于 MC 链之前：调用点在定义前，static inline 亦须先声明后使用。 */
static inline void sample_stage_peak_mc(auradsp_handle h, int stage_idx,
                                        const float* interleaved, int frames, int ch) {
    float pk[AURADSP_CH_MAX] = {};
    for (int i = 0; i < frames; ++i) {
        const float* row = interleaved + (size_t)i * ch;
        for (int c = 0; c < ch; ++c) {
            const float a = fabsf(row[c]);
            if (a > pk[c]) pk[c] = a;
        }
    }
    for (int c = 0; c < ch; ++c) h->stage_peak_ch[stage_idx][c] = pk[c];
    for (int c = ch; c < AURADSP_CH_MAX; ++c) h->stage_peak_ch[stage_idx][c] = 0.0f;
    h->stage_peak_l[stage_idx] = pk[0];
    h->stage_peak_r[stage_idx] = ch > 1 ? pk[1] : pk[0];
}


/* [PATCHED-AuraDSP P-035] eq 逐声道池（8×FFTConvolver1x1，IR 与主 mEQ.instance.coeffGen 同源但按设备采样率生成）。
 * 线程契约：alloc/free/reload 全部控制线程；RT 线程只读池指针与 loaded 标志。 */
void eq_pool_alloc(auradsp_handle h) {
    if (!h) return;
    for (int c = 0; c < kMxMaxChannels; ++c) {
        if (!h->eq_pool.conv[c]) {
            auto* conv = new (std::nothrow) FFTConvolver1x1();
            if (!conv) return;
            FFTConvolver1x1Init(conv);
            h->eq_pool.conv[c] = conv;
        }
    }
}

void eq_pool_free(auradsp_handle h) {
    if (!h) return;
    for (int c = 0; c < kMxMaxChannels; ++c) {
        if (h->eq_pool.conv[c]) {
            FFTConvolver1x1Free(h->eq_pool.conv[c]);
            delete h->eq_pool.conv[c];
            h->eq_pool.conv[c] = nullptr;
        }
    }
    h->eq_pool.loaded = 0;
    h->eq_pool.ir_rate = 0.0f;
}

void eq_pool_reload(auradsp_handle h) {
    if (!h) return;
    const unsigned block = (unsigned)h->jdsp.blockSize;
    if (block == 0) { h->eq_pool.loaded = 0; return; }
    const float dev_sr = (h->sample_rate > 0.0) ? (float)h->sample_rate : 48000.0f;
    const unsigned irLen = h->jdsp.mEQ.instance.filterLen ? h->jdsp.mEQ.instance.filterLen : 8192;

    double dev_freq[NUMPTS + 2];
    double dev_gain[NUMPTS + 2];
    memcpy(dev_freq, h->jdsp.mEQ.freq, sizeof(dev_freq));
    memcpy(dev_gain, h->jdsp.mEQ.gain, sizeof(dev_gain));
    const double nyq = (double)dev_sr * 0.5;
    for (int i = 1; i <= NUMPTS; ++i) {
        if (dev_freq[i] >= nyq) {
            dev_freq[i] = nyq * (1.0 - 1e-4 * (NUMPTS + 1 - i));
        }
    }
    dev_freq[NUMPTS + 1] = nyq;
    dev_gain[NUMPTS + 1] = dev_gain[NUMPTS];

    ierper pch;
    initIerper(&pch, NUMPTS + 2);
    if (!h->jdsp.mEQ.currentInterpolationMode) {
        pchip(&pch, dev_freq, dev_gain, NUMPTS + 2, 1, 1);
    } else {
        makima(&pch, dev_freq, dev_gain, NUMPTS + 2, 1, 1);
    }
    float* eqFil = InterpolatingEqMinimumPhase(&h->jdsp.mEQ.instance.coeffGen, dev_sr, (void*)(&pch));
    freeIerper(&pch);

    if (!eqFil) { h->eq_pool.loaded = 0; return; }

    for (int c = 0; c < kMxMaxChannels; ++c) {
        auto* conv = h->eq_pool.conv[c];
        if (!conv) { h->eq_pool.loaded = 0; return; }
        if (!FFTConvolver1x1LoadImpulseResponse(conv, block, eqFil, irLen)) {
            h->eq_pool.loaded = 0;
            return;
        }
    }
    h->eq_pool.loaded = 1;
    h->eq_pool.ir_rate = dev_sr;
}

void eq_pool_process_strided(auradsp_handle h, float* io, int frames,
                             int nch, int ch_idx) {
    if (!h || !io || frames <= 0 || nch <= 0 || ch_idx < 0 || ch_idx >= nch)
        return;
    if (!(h->p.eq_channels.load(std::memory_order_relaxed) & (1u << ch_idx)))
        return;
    if (!h->p.eq_enable.load(std::memory_order_relaxed))
        return;
    auto* conv = h->eq_pool.conv[ch_idx];
    if (!conv || !h->eq_pool.loaded) return;
    float* scratch = arbmag_pool_get_scratch(h);
    if (!scratch) return;
    float* in = io + ch_idx;
    for (int i = 0; i < frames; ++i) scratch[i] = in[(size_t)i * nch];

    FFTConvolver1x1Process(conv, scratch, scratch, (unsigned)frames);

    const float g = h->jdsp.fxOutGain[3]; /* 线性输出增益门（eq） */
    if (g == 1.0f) {
        for (int i = 0; i < frames; ++i) in[(size_t)i * nch] = scratch[i];
    } else {
        for (int i = 0; i < frames; ++i) in[(size_t)i * nch] = scratch[i] * g;
    }
}

void eq_process_mc(auradsp_handle h, float* dst, int frames, int ch) {
    if (!h || !dst || frames <= 0 || ch <= 0) return;
    if (h->p.eq_enable.load(std::memory_order_relaxed) && h->eq_pool.loaded) {
        for (int c = 0; c < ch; ++c) {
            eq_pool_process_strided(h, dst, frames, ch, c);
        }
    }
    sample_stage_peak_mc(h, 3, dst, frames, ch);
}

/* [PATCHED-AuraDSP P-034] 动态范围压缩器离散多声道处理（支持 8 声道独立与成对模式） */
void comp_process_mc(auradsp_handle h, float* dst, int frames, int ch) {
    if (!h || !dst || frames <= 0 || ch <= 0) return;
    CompressorProcessBlockStart(&h->jdsp);
    if (h->p.comp_enable.load(std::memory_order_relaxed)) {
        const int mode = h->p.comp_mode.load(std::memory_order_relaxed);
        const uint32_t mask = (uint32_t)h->p.comp_channels.load(std::memory_order_relaxed);
        float* scratch = h->shelf_scratch;
        const float g = h->jdsp.fxOutGain[1];
        if (mode == 0) {
            for (int c = 0; c < ch; ++c) {
                if (mask & (1u << c)) {
                    for (int i = 0; i < frames; ++i) scratch[i] = dst[i * ch + c];
                    CompressorProcessChannel(&h->jdsp, c, scratch, scratch, (size_t)frames, 1);
                    if (g != 1.0f) {
                        for (int i = 0; i < frames; ++i) dst[i * ch + c] = scratch[i] * g;
                    } else {
                        for (int i = 0; i < frames; ++i) dst[i * ch + c] = scratch[i];
                    }
                }
            }
        } else {
            for (int p = 0; p < 4; ++p) {
                const int p0 = kChPairFirst[p];
                if (p0 + 1 >= ch) break;
                const uint32_t bits = kChMaskPair[p];
                if ((mask & bits) == bits) {
                    for (int c = p0; c <= p0 + 1; ++c) {
                        for (int i = 0; i < frames; ++i) scratch[i] = dst[i * ch + c];
                        CompressorProcessChannel(&h->jdsp, c, scratch, scratch, (size_t)frames, 1);
                        if (g != 1.0f) {
                            for (int i = 0; i < frames; ++i) dst[i * ch + c] = scratch[i] * g;
                        } else {
                            for (int i = 0; i < frames; ++i) dst[i * ch + c] = scratch[i];
                        }
                    }
                }
            }
        }
    }
    CompressorProcessBlockEnd(&h->jdsp);
    sample_stage_peak_mc(h, 1, dst, frames, ch);
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
 * 注意：NSEEL_VM_regvar 对同名变量幂等返回同一指针（P-001 已在编译前注册）。
 * B1：eel 为活动快照指针——编译成功后已被 LiveProgCompileAndSwap 换到
 * 新槽，此处自然取到新 VM 的 slider 寄存器。 */
void lp_refresh_sliders(auradsp_handle h) {
    LiveProg* eel = h->jdsp.eel;
    if (!eel || !eel->vm) return;
    for (int i = 0; i < 8; ++i) {
        char nm[16];
        snprintf(nm, sizeof(nm), "slider%d", i + 1);
        h->lp_slider_ptr[i] = NSEEL_VM_regvar(eel->vm, nm);
        if (h->lp_slider_ptr[i])
            *h->lp_slider_ptr[i] = h->p.lp_param[i].load(std::memory_order_relaxed);
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

    const SpeakerLayout ly = layout_for(ch);

    for (int i = 0; i < frames; ++i) {
        const float* sp = in + (size_t)i * ch;
        float* kp = keep + (size_t)i * ch;

        // 全量完整留存源输入至 keep
        for (int k = 0; k < ch; ++k) {
            kp[k] = sp[k];
        }

        if (ch == 2) {
            stereo[i * 2]     = sp[0];
            stereo[i * 2 + 1] = sp[1];
            continue;
        }

        float l = sp[ly.fl];
        float r = sp[ly.fr];
        if (ly.c >= 0) {
            const float c = sp[ly.c] * kMxSqrtHalf;
            l += c;
            r += c;
        }
        if (ly.sl >= 0) l += sp[ly.sl] * kMxSqrtHalf;
        if (ly.sr >= 0) r += sp[ly.sr] * kMxSqrtHalf;
        if (ly.bl >= 0) l += sp[ly.bl] * kMxSqrtHalf;
        if (ly.br >= 0) r += sp[ly.br] * kMxSqrtHalf;

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

    const SpeakerLayout ly = layout_for(ch);

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

        dp[ly.fl] = l;
        dp[ly.fr] = r;
        if (ly.c >= 0) {
            dp[ly.c] = (l + r) * 0.5f * kMxSqrtHalf; // Center: 居中单声道和
        }
        if (ly.lfe >= 0) {
            dp[ly.lfe] = std::isfinite(sp[ly.lfe]) ? sp[ly.lfe] : 0.0f;
        }
        if (ly.sl >= 0) dp[ly.sl] = l * kMxSqrtHalf; // SL: 严格取 L
        if (ly.sr >= 0) dp[ly.sr] = r * kMxSqrtHalf; // SR: 严格取 R
        if (ly.bl >= 0) dp[ly.bl] = l * kMxSqrtHalf; // BL: 严格取 L
        if (ly.br >= 0) dp[ly.br] = r * kMxSqrtHalf; // BR: 严格取 R
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

                /* PF-2：滑动窗口最小值（单调 deque）替代每样本 O(la_len)
                 * 全窗扫描（8ch LA 模式 576 iters/帧，≈0ms 模式 10× 成本）。
                 * deque 存 gain_buf 的环形位置，所指引值从头到尾单调非降，
                 * 队首即窗口最小 —— 与原"扫全部 la_len 个 slot"逐样本等价
                 * （环形缓冲写满后全部 slot 恰好就是窗口）。la_len 变化时
                 * 整体失效重建（la_len 仅 create 时按 fs 定，运行期不变）。 */
                const int dqCap = (int)auradsp_handle_s::kLimLookaheadMax;
                int* dq = h->mc_limiter_dq[c];
                int& dq_head = h->mc_limiter_dq_head[c];
                int& dq_count = h->mc_limiter_dq_count[c];
                const float* gb = h->mc_limiter_gain_buf[c];
                if (h->mc_limiter_dq_len != la_len) {
                    dq_head = 0;
                    dq_count = 0;
                    h->mc_limiter_dq_len = la_len;
                } else if (dq_count > 0 && dq[dq_head] == pos) {
                    /* 队首是最老样本，本次写入即将覆盖它 → 已滑出窗口 */
                    dq_head = (dq_head + 1 >= dqCap) ? 0 : dq_head + 1;
                    --dq_count;
                }
                /* 入队：从队尾弹出所有不劣于新值的旧位（它们永不再成为最小；
                 * 相等也弹，保留更晚滑出的新位，窗口语义不变） */
                while (dq_count > 0) {
                    const int tail = (dq_head + dq_count - 1) % dqCap;
                    if (gb[dq[tail]] >= g_target) --dq_count; else break;
                }
                dq[(dq_head + dq_count) % dqCap] = pos;
                ++dq_count;

                float win_min_g = (dq_count > 0) ? gb[dq[dq_head]] : 1.0f;

                int read_pos = (pos + 1) % la_len;
                float delayed_s = h->mc_limiter_la_buf[c][read_pos];

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


void process_stereo_chain(auradsp_handle h, const float* src, float* dst,
                          int frames, bool skip_spatial);



/* 离散多声道处理链本体 (Phase B: Category A 独立单声道滤波 + Category B 声场保持) */
void process_multichannel_chain(auradsp_handle h, const float* src, float* dst, int frames, int ch) {
    if (!h || !src || !dst || frames <= 0 || ch <= 0) return;
    h->stage_ch_active = ch;   /* [Phase B] stage 级 per-channel 数据全声道有效 */

    // 1. 全量拷贝至目标工作区，就地推进
    memcpy(dst, src, (size_t)frames * ch * sizeof(float));

    // 2. 前级 Category A 效果器（支持 8 声道独立按掩码处理）
    if (h->p.gate_enable.load(std::memory_order_relaxed)) {
        gate_process_mc(h, dst, frames, ch);
    }
    sample_stage_peak_mc(h, 13, dst, frames, ch);   /* Stage 13: Gate stage output */
    if (h->p.filter_enable.load(std::memory_order_relaxed)) {
        filter_process_mc(h, dst, frames, ch);
    }
    sample_stage_peak_mc(h, 15, dst, frames, ch);   /* Stage 15: Filter output */
    auradsp::plugin_chain_process_n(h, 0, dst, (uint32_t)frames, (uint32_t)ch);

    if (h->p.shelf_enable.load(std::memory_order_relaxed) &&
        h->p.shelf_gain.load(std::memory_order_relaxed) != 0.0f) {
        shelf_process_mc(h, dst, frames, ch);
    }
    if (h->p.dyneq_enable.load(std::memory_order_relaxed)) {
        dyneq_process_mc(h, dst, frames, ch);
    }
    sample_stage_peak_mc(h, 14, dst, frames, ch);   /* Stage 14: Dynamic EQ output */
    if (h->p.tube_enable.load(std::memory_order_relaxed)) {
        tube_process_mc(h, dst, frames, ch);
    }

    auradsp::plugin_chain_process_n(h, 1, dst, (uint32_t)frames, (uint32_t)ch);

    /* [PATCHED-AuraDSP P-026 E4] Stage 16: BassMono 采样点跨模式同语义（采在 basspsycho 之前）；
     * WP4 升级为全声道处理（支持标准四对与 merge 模式） */
    if (h->p.bassmono_enable.load(std::memory_order_relaxed)) {
        bassmono_process_mc(h, dst, frames, ch);
    }
    sample_stage_peak_mc(h, 16, dst, frames, ch); /* Stage 16: BassMono 全声道 */

    /* [PATCHED-AuraDSP P-034] Step 10: comp_process_mc (全声道逐声道/成对独立压缩) */
    comp_process_mc(h, dst, frames, ch);

    // 3. Category B 跨声道/声场效果器与前置 FL/FR vendor 核心（仅作用于前置立体声对，保持环绕声场完整性）
    // Step 11: Vendor bass (前置 FL/FR 对)
    if (h->shelf_scratch && h->mx_stereo) {
        for (int i = 0; i < frames; ++i) {
            h->shelf_scratch[i * 2]     = dst[i * ch + 0];
            h->shelf_scratch[i * 2 + 1] = dst[i * ch + 1];
        }

        if (h->p.bass_enable.load(std::memory_order_relaxed)) {
            basspsycho_process(h, h->shelf_scratch, frames);
        }

        /* [PATCHED-AuraDSP P-020 B4] 门控改走「本次调用」参数 */
        AuraStageGates g;
        g.tube = 0;    /* tube 已由 tube_process_mc 逐声道处理 */
        g.comp = 0;    /* comp 已由 comp_process_mc 逐声道处理 */
        g.bass = -1;   /* bass 只看全局 bassBoostEnabled（控制线程不写） */
        g.eq = 0;      /* eq 已由 eq_process_mc 逐声道处理 */
        g.arbmag = 0;  /* arbmag 逐声道改走池，不在链内跑 FL/FR 对 */
        g.limiter = 0; /* MC 侧由 limiter_process_mc 承担 lookahead/link/mask */

        JamesDSPProcessMultiplexedStageSet(&h->jdsp, h->shelf_scratch,
                                           h->mx_stereo, (size_t)frames,
                                           "bass", 1, &g);

        for (int i = 0; i < frames; ++i) {
            dst[i * ch + 0] = h->mx_stereo[i * 2];
            dst[i * ch + 1] = h->mx_stereo[i * 2 + 1];
        }
    }

    /* [PATCHED-AuraDSP P-035] Step 12: eq_process_mc (全声道逐声道独立 EQ，设备采样率 IR) */
    eq_process_mc(h, dst, frames, ch);

    // Step 13: arbmag 逐声道池统一全声道处理
    if (h->p.arbmag_enable.load(std::memory_order_relaxed) &&
        h->p.arbmag_ready.load(std::memory_order_relaxed) &&
        h->arbmag_pool.loaded) {
        for (int c = 0; c < ch; ++c) {
            arbmag_pool_process_strided(h, dst, frames, ch, c);
        }
    }
    sample_stage_peak_mc(h, 4, dst, frames, ch);

    // Step 14: Category B 其余 vendor 核心（仅作用于前置 FL/FR，保持环绕声场完整性）
    if (h->shelf_scratch && h->mx_stereo) {
        AuraStageGates g;
        g.tube = 0;
        g.comp = 0;
        g.bass = 0;
        g.eq = 0;
        g.arbmag = 0;
        g.limiter = 0;

        for (int i = 0; i < frames; ++i) {
            h->mx_stereo[i * 2]     = dst[i * ch + 0];
            h->mx_stereo[i * 2 + 1] = dst[i * ch + 1];
        }

        JamesDSPProcessMultiplexedStageSet(&h->jdsp, h->mx_stereo,
                                           h->mx_stereo, (size_t)frames,
                                           "convolver,ddc,liveprog,crossfeed,stereo", 1,
                                           &g);

        for (int i = 0; i < frames; ++i) {
            dst[i * ch + 0] = h->mx_stereo[i * 2];
            dst[i * ch + 1] = h->mx_stereo[i * 2 + 1];
        }

        /* 15. post_gain_process_mc：全声道输出增益与逐声道 trim（D13 / M-4） */
        post_gain_process_mc(h, dst, frames, ch);

        auradsp::plugin_chain_process_n(h, 2, dst, (uint32_t)frames, (uint32_t)ch);

        for (int i = 0; i < frames; ++i) {
            h->mx_stereo[i * 2]     = dst[i * ch + 0];
            h->mx_stereo[i * 2 + 1] = dst[i * ch + 1];
        }

        if (h->p.haas_enable.load(std::memory_order_relaxed)) {
            haas_process(h, h->mx_stereo, frames);
        }
        sample_stage_peak_mc(h, 17, h->mx_stereo, frames, 2); /* Stage 17: Haas（仅 FL/FR 对） */
        if (h->p.spatial_enable.load(std::memory_order_relaxed)) {
            spatial_process(h, h->mx_stereo, frames);
        }
        sample_stage_peak_mc(h, 20, h->mx_stereo, frames, 2); /* Stage 20: Spatial（仅 FL/FR 对） */

        for (int i = 0; i < frames; ++i) {
            dst[i * ch + 0] = h->mx_stereo[i * 2];
            dst[i * ch + 1] = h->mx_stereo[i * 2 + 1];
        }
    }

    // 4. 后级 Category A 效果器（支持 8 声道独立按掩码处理）
    if (h->p.exciter_enable.load(std::memory_order_relaxed)) {
        exciter_process_mc(h, dst, frames, ch);
    }
    sample_stage_peak_mc(h, 18, dst, frames, ch);   /* Stage 18: Exciter output */

    /* WP1 混响边界：离散多声道路径使用 MC FDN（全声道，N 进 N 出）。
     * 位置在 exciter 之后、plugin stage 3/loudness 之前——尾音不再经过
     * spatial/exciter；vendor 段已移除 reverb，两套混响不会同时运行。 */
    if (h->p.reverb_preset.load(std::memory_order_relaxed) != -1) {
        mc_reverb_process_mc(h, dst, frames, ch);
    }

    auradsp::plugin_chain_process_n(h, 3, dst, (uint32_t)frames, (uint32_t)ch);

    if (h->p.loudness_enable.load(std::memory_order_relaxed)) {
        loudness_process_mc(h, dst, frames, ch);
    }
    sample_stage_peak_mc(h, 19, dst, frames, ch);   /* Stage 19: Loudness output */
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

    auradsp::plugin_chain_process_n(h, 4, dst, (uint32_t)frames, (uint32_t)ch);
}


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
                                 int frames, bool skip_spatial) {
    /* [Phase B] 立体声链只产生 L/R 两列 stage 数据——把有效列数钉回 2，
     * 阻断矩阵/双耳模式下读到上一次 MC 模式的陈旧 stage_peak_ch。 */
    h->stage_ch_active = 2;
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
    auradsp::plugin_chain_process(h, 0, const_cast<float*>(src), (uint32_t)frames);

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
    auradsp::plugin_chain_process(h, 1, const_cast<float*>(src), (uint32_t)frames);

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
    auradsp::plugin_chain_process(h, 2, dst, (uint32_t)frames);

    /* Haas 差分环绕（Stage 2 后 / Freeverb 前） */
    if (h->p.haas_enable.load(std::memory_order_relaxed)) {
        haas_process(h, dst, frames);
    }
    sample_stage_peak(h, 17, dst, frames);   /* Stage 17: Haas output */

    /* 空间音效 L1（haas 后 / exciter 前：空间族抱团，最后一道音色工序之前）。
     * B1 多声道双耳模式已在上游渲染，skip_spatial 避免二次空间化。 */
    if (!skip_spatial && h->p.spatial_enable.load(std::memory_order_relaxed)) {
        spatial_process(h, dst, frames);
    }
    sample_stage_peak(h, 20, dst, frames);   /* Stage 20: Spatial output */

    /* 激励器（Haas 后 / Freeverb 前：最后一道音色工序，再进房间） */
    if (h->p.exciter_enable.load(std::memory_order_relaxed)) {
        exciter_process(h, dst, frames);
    }
    sample_stage_peak(h, 18, dst, frames);   /* Stage 18: Exciter output */

    /* WP1：立体声/矩阵/双耳路径的混响由 vendor Progenitor2 承担
     * （vendor 段内 stage_reverb）。自研 Freeverb 已退役；spatial.fdn
     * 晚期混响也已移除，不再有第二套房间。 */

    /* Stage 3: Post-Reverb（混响后，默认阶段） */
    auradsp::plugin_chain_process(h, 3, dst, (uint32_t)frames);

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
    auradsp::plugin_chain_process(h, 4, dst, (uint32_t)frames);
}
