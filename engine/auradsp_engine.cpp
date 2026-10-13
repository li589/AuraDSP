/*
 * auradsp_engine.c — AuraDSP Engines 统一 C ABI 实现（Desktop v1）
 *
 * 包装 vendor/libjamesdsp（纯 C，原样未改，见 ORIGIN.md）。
 * 参数语义与 Android 侧 JamesDspEngine（AIDL VendorParamId 透传）对齐：
 *   bass.enable/bass.gain/reverb.preset/stereo.mix/eq.enable/post.gain
 * 新增桌面侧参数：
 *   limiter.enable / mode.latency（ADR-002 三档守卫）/ channels.mode（ADR-003，Phase A 仅 stereo）
 *
 * 延迟模型（48kHz，依据 ADR-002；后续以实测修正）：
 *   T0: bass(0) tube(0) stereo(<1) eq(0) limiter(~2) post.gain(0)
 *   T1: crossfeed(~3) ddc(~6)
 *   T2: reverb(~30) convolver(IR 长度) compressor(~85, FFTSIZE_DRS/2@48k) arbMag(分块)
 *
 * RT 契约：process() 无 malloc/锁/IO；频谱每 latency 检测间隔计算一次，
 * 结果写 SPSC 环（引擎只写，UI 只读）。
 */
#include "auradsp_engine.h"
#include "engine_internal.h"
#include "auradsp_plugin_host.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <new>

#if defined(_M_X64) || defined(__x86_64__) || defined(_M_IX86) || defined(__i386__)
#include <xmmintrin.h>
#endif

#ifdef _WIN32
#include <windows.h> /* MultiByteToWideChar / _wfopen（审查修复 R-1） */
#endif

namespace {

/* 进程级全局初始化（NSEEL JIT 运行时），引用计数（对齐 Android 侧做法） */
std::mutex g_global_mutex;
int g_global_ref = 0;

}  // namespace

/* NOTE: external linkage — called cross-TU (probe). */
bool global_init() {
    std::lock_guard<std::mutex> lk(g_global_mutex);
    if (g_global_ref == 0) {
        JamesDSPGlobalMemoryAllocation();
        WDL_fft_init();
    }
    ++g_global_ref;
    return true;
}

void global_unref() {
    std::lock_guard<std::mutex> lk(g_global_mutex);
    if (g_global_ref > 0) --g_global_ref;
    /* 有意不调用 JamesDSPGlobalMemoryDeallocation：NSEEL 卸载期风险 > 退出前泄漏 */
}

/* ================= ABI 实现 ================= */

extern "C" {

const char* auradsp_version(void) { return AURADSP_VERSION; }
uint32_t    auradsp_abi(void) { return AURADSP_ABI; }

auradsp_handle auradsp_create(float sample_rate, int max_block_frames) {
    if (sample_rate < 8000 || sample_rate > 192000) return nullptr;
    if (max_block_frames <= 0 || max_block_frames > 16384) return nullptr;
    if (!global_init()) return nullptr;

    auto* h = new (std::nothrow) auradsp_handle_s();
    if (!h) return nullptr;
    h->sample_rate = sample_rate;
    h->max_block = max_block_frames;
    h->fft_scratch = new (std::nothrow) float[kVizFftMax];
    h->hann = new (std::nothrow) float[kVizFftMax];
    if (!h->fft_scratch) { delete h; return nullptr; }
    h->viz_hist = new (std::nothrow) float[kVizFftMax * 2]();
    if (!h->viz_hist) { delete[] h->fft_scratch; delete h; return nullptr; }
    /* [EQ tap] 第二条环形历史。分配失败不算致命：emit_viz 里对 nullptr
     * 已有分支，eq_in_spectrum 保持全 0，UI 会退回旧的全链输出谱。 */
    h->eq_in_hist = new (std::nothrow) float[kVizFftMax * 2]();
    h->shelf_scratch = new (std::nothrow) float[(size_t)max_block_frames * 2]();
    if (!h->shelf_scratch) {
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist; delete[] h->eq_in_hist; delete h; return nullptr;
    }
    h->conv_scratch = new (std::nothrow) float[(size_t)max_block_frames * 2]();
    if (!h->conv_scratch) {
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist; delete[] h->eq_in_hist;
        delete[] h->shelf_scratch; delete h; return nullptr;
    }
    h->mx_scratch = new (std::nothrow) float[(size_t)max_block_frames * kMxMaxChannels]();
    h->mx_stereo = new (std::nothrow) float[(size_t)max_block_frames * 2]();
    if (!h->mx_scratch || !h->mx_stereo) {
        delete[] h->plugin_buf_l; delete[] h->plugin_buf_r;
        delete[] h->mx_scratch; delete[] h->mx_stereo;
        delete h; return nullptr;
    }
    h->plugin_buf_l = new (std::nothrow) float[(size_t)max_block_frames]();
    h->plugin_buf_r = new (std::nothrow) float[(size_t)max_block_frames]();
    if (!h->plugin_buf_l || !h->plugin_buf_r) {
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist; delete[] h->eq_in_hist;
        delete[] h->shelf_scratch; delete[] h->conv_scratch;
    delete[] h->mx_scratch; delete[] h->mx_stereo;
        delete[] h->plugin_buf_l; delete[] h->plugin_buf_r;
        delete h; return nullptr;
    }
    /* Haas 延迟环：25ms 上限 + 一块余量，清零（开轮即录制，无陈旧音频 burst） */
    h->haas_ring_len = (int)(0.025 * sample_rate) + max_block_frames + 64;
    h->haas_ring = new (std::nothrow) float[(size_t)h->haas_ring_len]();
    if (!h->haas_ring) {
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist; delete[] h->eq_in_hist;
        delete[] h->shelf_scratch; delete[] h->conv_scratch;
    delete[] h->mx_scratch; delete[] h->mx_stereo;
        delete[] h->plugin_buf_l; delete[] h->plugin_buf_r;
        delete h; return nullptr;
    }
    h->plugin_host = std::make_unique<auradsp::PluginHostManager>();
    h->plugin_host->updateFormat(sample_rate, (uint32_t)max_block_frames);

    /* 注意：P-005 的 scratch 绑定必须放在 JamesDSPInit 之后——
     * JamesDSPInit 内部 memset(jdsp, 0, sizeof) 会清掉提前写入的指针 */

    for (int i = 0; i < kVizFftMax; ++i) h->hann[i] = 0.0f;
    rebuild_hann(h, kVizFftDefault);
    /* 产出间隔按实际 fs 归一到 10ms，44.1k/96k 下帧率才不会漂。
     * 不用 std::max：Windows 头把 max 定义成宏，会把 std::max 展开坏
     * （MSVC C2589）。 */
    int viz_int = (int)(h->sample_rate / 100.0 + 0.5);
    if (viz_int < 1) viz_int = 1;
    h->viz_interval.store(viz_int);

    for (int i = 0; i < 8; ++i) {
        h->p.input_ch_gain[i].store(1.0f);
    }

    std::lock_guard<std::mutex> lk(h->ctrl_mutex);
    JamesDSPInit(&h->jdsp, max_block_frames, sample_rate);
    /* P-005：scratch 绑定（必须在 memset 之后）+ 默认纯湿（=上游行为） */
    h->jdsp.auraConvScratch = h->conv_scratch;
    h->jdsp.auraConvWet = 1.0f;
    h->jdsp.auraConvDry = 0.0f;
    h->jdsp.auraConvMixUsed = 0;
    fv_alloc(h->fvL, sample_rate, 0);
    fv_alloc(h->fvR, sample_rate, kFvStereoSpread);
    JamesDSPInitFxGains(&h->jdsp);
    shelf_recalc(h);
    filter_recalc(h);
    apply_params_locked(h);
    h->open.store(true);
    h->state.store(AURADSP_STATE_PROCESSING);
    return h;
}

void auradsp_destroy(auradsp_handle h) {
    if (!h) return;
    {
        std::lock_guard<std::mutex> lk(h->ctrl_mutex);
        if (h->open.load()) {
            JamesDSPFree(&h->jdsp);
            h->open.store(false);
        }
    }
    if (h->plugin_host) {
        for (size_t s = 0; s < auradsp::PluginHostManager::kMaxPluginSlots; ++s) {
            h->plugin_host->unloadPluginSlot(s);
        }
        h->plugin_host.reset();
    }
    fv_free(h->fvL);
    fv_free(h->fvR);
    delete[] h->fft_scratch;
    delete[] h->viz_hist; delete[] h->eq_in_hist;
    delete[] h->shelf_scratch;
    delete[] h->conv_scratch;
    delete[] h->haas_ring;
    delete[] h->plugin_buf_l;
    delete[] h->plugin_buf_r;
    free(h->lp_code);
    delete h;
    global_unref();
}

void auradsp_process(auradsp_handle h, const float* in, float* out, int frames) {
    if (!h || !h->open.load(std::memory_order_acquire) || frames <= 0) return;
    /* 内存安全防御：防御驱动层 frames > max_block 导致的 scratch 堆缓冲区溢出 */
    if (frames > h->max_block) frames = h->max_block;

    ScopedFtzDazGuard ftzGuard;
    const int st = h->state.load(std::memory_order_relaxed);

    /* [ADR-003 Phase A] 多声道：先把 M 声道下混成立体声，处理完再上混回 M。
     * ch<=2 时整段跳过，立体声路径与改造前逐字节一致。 */
    const int ch = h->channel_count.load(std::memory_order_relaxed);
    const bool multichannel = (ch > 2);

    /* [Input Gate: 顺序钉死在最前端] 全通道总输入增益 × 单通道平衡 */
    const float in_gain_db = h->p.input_gain.load(std::memory_order_relaxed);
    const float master_lin = (in_gain_db == 0.0f) ? 1.0f : powf(10.0f, in_gain_db * 0.05f);

    if (multichannel && h->mx_scratch) {
        if (st != AURADSP_STATE_PROCESSING) {
            /* 非处理态：原样直通（含全部声道），不做矩阵 */
            memcpy(out, in, (size_t)frames * ch * sizeof(float));
            return;
        }
        /* 多声道输入门控处理：缩放写入 mx_scratch 并统计本级 IN / OUT 电平 */
        float pk_in_l = 0.0f, pk_in_r = 0.0f;
        float pk_out_l = 0.0f, pk_out_r = 0.0f;
        for (int i = 0; i < frames; ++i) {
            for (int c = 0; c < ch; ++c) {
                const float s_in = in[i * ch + c];
                const float bal = (c < 8) ? h->p.input_ch_gain[c].load(std::memory_order_relaxed) : 1.0f;
                const float s_out = s_in * (master_lin * bal);
                h->mx_scratch[i * ch + c] = s_out;
                const float a_in = fabsf(s_in);
                const float a_out = fabsf(s_out);
                if (c == 0) {
                    if (a_in > pk_in_l) pk_in_l = a_in;
                    if (a_out > pk_out_l) pk_out_l = a_out;
                } else if (c == 1) {
                    if (a_in > pk_in_r) pk_in_r = a_in;
                    if (a_out > pk_out_r) pk_out_r = a_out;
                }
            }
        }
        h->input_lvl_in_l = pk_in_l > 1e-6f ? 20.0f * log10f(pk_in_l) : -120.0f;
        h->input_lvl_in_r = pk_in_r > 1e-6f ? 20.0f * log10f(pk_in_r) : -120.0f;
        h->input_lvl_out_l = pk_out_l > 1e-6f ? 20.0f * log10f(pk_out_l) : -120.0f;
        h->input_lvl_out_r = pk_out_r > 1e-6f ? 20.0f * log10f(pk_out_r) : -120.0f;

        if (!mx_downmix(h, h->mx_scratch, h->shelf_scratch, frames, ch) || !h->mx_stereo) {
            memcpy(out, in, (size_t)frames * ch * sizeof(float));
            return;
        }
        process_stereo_chain(h, h->shelf_scratch, h->mx_stereo, frames);
        mx_upmix(h, out, h->mx_stereo, frames, ch);
        /* 可视化只统计前置立体声工作区（真实信号走向的近似，见 ADR-003） */
        h->frames_since_viz += frames;
        viz_write(h, h->mx_stereo, frames);
        const int vizInt = h->viz_interval.load(std::memory_order_relaxed);
        while (h->frames_since_viz >= vizInt) {
            h->frames_since_viz -= vizInt;
            emit_viz(h);
        }
        return;
    }

    if (st != AURADSP_STATE_PROCESSING) {
        if (out != in) memcpy(out, in, (size_t)frames * 2 * sizeof(float));
        return;
    }
    /* 立体声输入门控处理：写入 shelf_scratch 作为链前置工作区 */
    const float g0 = master_lin * h->p.input_ch_gain[0].load(std::memory_order_relaxed);
    const float g1 = master_lin * h->p.input_ch_gain[1].load(std::memory_order_relaxed);
    float pk_in_l = 0.0f, pk_in_r = 0.0f;
    float pk_out_l = 0.0f, pk_out_r = 0.0f;
    for (int i = 0; i < frames; ++i) {
        const float in_l = in[i * 2];
        const float in_r = in[i * 2 + 1];
        const float out_l = in_l * g0;
        const float out_r = in_r * g1;
        h->shelf_scratch[i * 2]     = out_l;
        h->shelf_scratch[i * 2 + 1] = out_r;
        const float a_in_l = fabsf(in_l);
        const float a_in_r = fabsf(in_r);
        const float a_out_l = fabsf(out_l);
        const float a_out_r = fabsf(out_r);
        if (a_in_l > pk_in_l) pk_in_l = a_in_l;
        if (a_in_r > pk_in_r) pk_in_r = a_in_r;
        if (a_out_l > pk_out_l) pk_out_l = a_out_l;
        if (a_out_r > pk_out_r) pk_out_r = a_out_r;
    }
    h->input_lvl_in_l = pk_in_l > 1e-6f ? 20.0f * log10f(pk_in_l) : -120.0f;
    h->input_lvl_in_r = pk_in_r > 1e-6f ? 20.0f * log10f(pk_in_r) : -120.0f;
    h->input_lvl_out_l = pk_out_l > 1e-6f ? 20.0f * log10f(pk_out_l) : -120.0f;
    h->input_lvl_out_r = pk_out_r > 1e-6f ? 20.0f * log10f(pk_out_r) : -120.0f;

    process_stereo_chain(h, h->shelf_scratch, out, frames);
    h->frames_since_viz += frames;
    viz_write(h, out, frames);
    const int vizInt2 = h->viz_interval.load(std::memory_order_relaxed);
    while (h->frames_since_viz >= vizInt2) {
        h->frames_since_viz -= vizInt2;
        emit_viz(h);
    }
}

auradsp_status auradsp_set_param(auradsp_handle h, const char* id,
                                 const void* value, uint32_t bytes) {
    if (!h || !id || !value) return AURADSP_E_PARAM;
    std::lock_guard<std::mutex> lk(h->ctrl_mutex);

    if (!strcmp(id, "bass.enable") && bytes >= 4) {
        h->p.bass_enable.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_bass(h);   /* 只动 bass 链 */
        return AURADSP_OK;
    }
    if (!strcmp(id, "bass.gain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < 0) db = 0; if (db > 15) db = 15;
        h->p.bass_gain.store(db);
        if (h->open.load() && h->p.bass_enable.load())
            BassBoostSetParam(&h->jdsp, db);   /* 仅更新系数，不重建 */
        return AURADSP_OK;
    }
    if (!strcmp(id, "reverb.preset") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value;
        if (v < -1) return AURADSP_E_PARAM;
        /* ADR-006：不再因延迟档拒绝混响，混响可自由启用。 */
        if (v != h->p.reverb_preset.load(std::memory_order_relaxed)) {
            h->p.reverb_preset.store(v);
            compute_latency(h, &h->latency_ms);
        }
        if (h->open.load()) apply_reverb(h);   /* 只动混响链 */
        compute_latency(h, &h->latency_ms);  /* 刷新延迟读数（开启/关闭都回落正确） */
        return AURADSP_OK;
    }
    if (!strcmp(id, "stereo.mix") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.stereo_mix.store(v);
        /* 总滑块语义 = 回到统一 mix（清分带模式），UI 同步隐藏高级态覆盖。
         * 注意：vendor 的 bandMixUsed 也必须显式清（烟囱测试抓回的真 bug：
         * 只清 engine 侧标志会让 vendor 残留分带路径）。 */
        h->p.stereo_band_used.store(0);
        if (h->open.load()) {
            StereoEnhancementUseUnifiedMix(&h->jdsp);
            apply_stereo(h);   /* 只动立体声增强链 */
        }
        return AURADSP_OK;
    }
    if (!strcmp(id, "stereo.bandUsed") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value ? 1 : 0;
        h->p.stereo_band_used.store(v);
        if (h->open.load()) {
            if (v) {
                apply_stereo(h);
            } else {
                StereoEnhancementUseUnifiedMix(&h->jdsp);
                apply_stereo(h);
            }
        }
        return AURADSP_OK;
    }
    if (!strncmp(id, "stereo.band", 11) && bytes >= 4) {
        const char d = id[11];
        if (d < '1' || d > '5' || id[12] != 0) { set_error(h, "unknown param id"); return AURADSP_E_PARAM; }
        const int idx = d - '1';
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.stereo_band[idx].store(v, std::memory_order_relaxed);
        h->p.stereo_band_used.store(1);
        if (h->open.load()) apply_stereo(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "eq.enable") && bytes >= 4) {
        h->p.eq_enable.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_eq(h);   /* 只动 EQ 链 */
        return AURADSP_OK;
    }
    /* ---- M5 第二批：EQ 频率轴曲线（multimodalEQ 轴注入） ----
     * value = "[eqm:<interp>:<op>;]f:g;f:g;..."（解析器最多支持 64 点，
     *   freq 升序，gain dB [-64,64]）。
     * 可选头 `eqm:` 携带工作模式（UI 侧拼接，见 AppModel._pushEqCurve）：
     *   interp = 0(PCHIP)/1(Makima)；op = 0(FIR)/2(6阶IIR)/5(12阶IIR)。
     * 无头或头非法时回退 (1, 0)，旧曲线字符串行为不变。
     * 不足 NUMPTS 用末端值线性补齐；MultimodalEqualizerAxisInterpolation
     * 内部 memcpy 恰好 NUMPTS 点。注意 vendor 的 IIR 分支不使用
     * interpolationMode，因此 IIR 模式下 interp 选择无声学意义。 */
    if (!strcmp(id, "eq.curve")) {
        if (!h->open.load()) { set_error(h, "eq.curve: engine closed"); return AURADSP_E_STATE; }
        if (bytes == 0 || bytes > 4096) {
            set_error(h, "eq.curve: invalid length");
            return AURADSP_E_PARAM;
        }
        char* txt = (char*)malloc((size_t)bytes + 1);
        if (!txt) { set_error(h, "eq.curve: OOM"); return AURADSP_E_IO; }
        memcpy(txt, value, bytes);
        txt[bytes] = 0;
        double freqAx[NUMPTS], gainAx[NUMPTS];
        int interp = 1, op = 0;
        const int n = build_eq_axis(txt, h->sample_rate, freqAx, gainAx,
                                    &interp, &op);
        free(txt);
        if (n < 2) {
            set_error(h, "eq.curve: need >= 2 points (f:g;f:g;...)");
            return AURADSP_E_PARAM;
        }
        MultimodalEqualizerAxisInterpolation(&h->jdsp, interp, op, freqAx, gainAx);
        return AURADSP_OK;
    }
    if (!strcmp(id, "limiter.enable") && bytes >= 4) {
        h->p.limiter_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "post.gain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -15) db = -15; if (db > 15) db = 15;
        h->p.post_gain.store(db);
        if (h->open.load()) apply_post(h);   /* 只动后级增益 */
        return AURADSP_OK;
    }
    /* ---- P-010 每效果输出增益门 + 自动补偿 ---- */
    if (!strcmp(id, "bass.outgain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -12) db = -12; if (db > 6) db = 6;
        h->p.bass_outgain.store(db);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "bass.autogain") && bytes >= 4) {
        h->p.bass_autogain.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "eq.outgain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -12) db = -12; if (db > 6) db = 6;
        h->p.eq_outgain.store(db);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "eq.autogain") && bytes >= 4) {
        h->p.eq_autogain.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "tube.outgain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -12) db = -12; if (db > 6) db = 6;
        h->p.tube_outgain.store(db);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "tube.autogain") && bytes >= 4) {
        h->p.tube_autogain.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "comp.outgain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -12) db = -12; if (db > 6) db = 6;
        h->p.comp_outgain.store(db);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "comp.autogain") && bytes >= 4) {
        h->p.comp_autogain.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "reverb.outgain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -12) db = -12; if (db > 6) db = 6;
        h->p.reverb_outgain.store(db);
        return AURADSP_OK;
    }
    if (!strcmp(id, "reverb.autogain") && bytes >= 4) {
        h->p.reverb_autogain.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) h->rev_ag_in = h->rev_ag_out = 0.0; h->rev_ag_comp = 1.0;
        return AURADSP_OK;
    }
    /* ---- 噪声门 / Deesser / 自动增益补偿 ---- */
    if (!strcmp(id, "gate.enable") && bytes >= 4) {
        h->p.gate_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "gate.threshold") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < -60) v = -60; if (v > 0) v = 0;
        h->p.gate_threshold.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "gate.attack") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 1) v = 1; if (v > 100) v = 100;
        h->p.gate_attack.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "gate.release") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 10) v = 10; if (v > 500) v = 500;
        h->p.gate_release.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "gate.autogain") && bytes >= 4) {
        h->p.gate_autogain.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) h->gate_ag_in = h->gate_ag_out = 0.0; h->gate_ag_comp = 1.0;
        return AURADSP_OK;
    }
    if (!strcmp(id, "deesser.enable") && bytes >= 4) {
        h->p.deesser_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "deesser.freq") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 2000) v = 2000; if (v > 10000) v = 10000;
        h->p.deesser_freq.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "deesser.amount") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.deesser_amount.store(v);
        return AURADSP_OK;
    }
    /* ---- 响度补偿 ---- */
    if (!strcmp(id, "loudness.enable") && bytes >= 4) {
        h->p.loudness_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "loudness.amount") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.loudness_amount.store(v);
        return AURADSP_OK;
    }
    /* ---- 独立滤波器（RBJ HP/LP/BP） ---- */
    if (!strcmp(id, "filter.enable") && bytes >= 4) {
        h->p.filter_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "filter.type") && bytes >= 4) {
        int32_t v = *(const int32_t*)value;
        if (v < 0) v = 0; if (v > 2) v = 2;
        h->p.filter_type.store(v);
        filter_recalc(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "filter.freq") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 20) v = 20; if (v > 20000) v = 20000;
        h->p.filter_freq.store(v);
        filter_recalc(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "filter.q") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0.3f) v = 0.3f; if (v > 10) v = 10;
        h->p.filter_q.store(v);
        filter_recalc(h);
        return AURADSP_OK;
    }
    /* ---- 全参数动态EQ（系数每块现算，只存值；钳位与 dsp_dyneq.cpp 双保险） ---- */
    if (!strcmp(id, "dyneq.enable") && bytes >= 4) {
        h->p.dyneq_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "dyneq.attack") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0.1f) v = 0.1f; if (v > 100.0f) v = 100.0f;
        h->p.dyneq_attack.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "dyneq.release") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 10.0f) v = 10.0f; if (v > 1000.0f) v = 1000.0f;
        h->p.dyneq_release.store(v);
        return AURADSP_OK;
    }
#define DYNEQ_BAND_SET(tag, P, FMIN, FMAX, QMIN, QMAX) \
    if (!strcmp(id, "dyneq." tag ".enable") && bytes >= 4) { \
        h->p.dyneq_##P##_enable.store(*(const int32_t*)value ? 1 : 0); \
        return AURADSP_OK; \
    } \
    if (!strcmp(id, "dyneq." tag ".freq") && bytes >= 4) { \
        float v = *(const float*)value; \
        if (v < (FMIN)) v = (FMIN); if (v > (FMAX)) v = (FMAX); \
        h->p.dyneq_##P##_freq.store(v); \
        return AURADSP_OK; \
    } \
    if (!strcmp(id, "dyneq." tag ".q") && bytes >= 4) { \
        float v = *(const float*)value; \
        if (v < (QMIN)) v = (QMIN); if (v > (QMAX)) v = (QMAX); \
        h->p.dyneq_##P##_q.store(v); \
        return AURADSP_OK; \
    } \
    if (!strcmp(id, "dyneq." tag ".gain") && bytes >= 4) { \
        float v = *(const float*)value; \
        if (v < -12.0f) v = -12.0f; if (v > 12.0f) v = 12.0f; \
        h->p.dyneq_##P##_gain.store(v); \
        return AURADSP_OK; \
    } \
    if (!strcmp(id, "dyneq." tag ".range") && bytes >= 4) { \
        float v = *(const float*)value; \
        if (v < 0.0f) v = 0.0f; if (v > 24.0f) v = 24.0f; \
        h->p.dyneq_##P##_range.store(v); \
        return AURADSP_OK; \
    } \
    if (!strcmp(id, "dyneq." tag ".threshold") && bytes >= 4) { \
        float v = *(const float*)value; \
        if (v < -60.0f) v = -60.0f; if (v > 0.0f) v = 0.0f; \
        h->p.dyneq_##P##_threshold.store(v); \
        return AURADSP_OK; \
    }
    DYNEQ_BAND_SET("low", l, 20.0f, 500.0f, 0.5f, 2.0f)
    DYNEQ_BAND_SET("mid", m, 200.0f, 8000.0f, 0.3f, 10.0f)
    DYNEQ_BAND_SET("high", h, 2000.0f, 20000.0f, 0.5f, 2.0f)
#undef DYNEQ_BAND_SET
    /* ---- 心理声学低音（谐波合成三滑块终于有引擎了） ---- */
    if (!strcmp(id, "bass.harmonics") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.bass_harmonics.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "bass.harmonicblend") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.bass_harmonicblend.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "bass.subfreq") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 10) v = 10; if (v > 40) v = 40;
        h->p.bass_subfreq.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "bass.cutoff") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 30) v = 30; if (v > 300) v = 300;
        h->p.bass_cutoff_f.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "arbmag.outgain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -12) db = -12; if (db > 6) db = 6;
        h->p.arbmag_outgain.store(db);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "arbmag.autogain") && bytes >= 4) {
        h->p.arbmag_autogain.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_fx_gains(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "input.gain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -15.0f) db = -15.0f; if (db > 15.0f) db = 15.0f;
        h->p.input_gain.store(db);
        return AURADSP_OK;
    }
    if (!strncmp(id, "input.balance.", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) { set_error(h, "unknown input balance channel"); return AURADSP_E_PARAM; }
        const int idx = d - '1';
        float v = *(const float*)value;
        if (v < 0.0f) v = 0.0f; if (v > 2.0f) v = 2.0f;
        h->p.input_ch_gain[idx].store(v, std::memory_order_relaxed);
        return AURADSP_OK;
    }
    if (!strcmp(id, "mode.latency") && bytes >= 4) {
        /* ADR-006：延迟档已撤销，该参数不再是合法入参。
         * 明确返回 PARAM（而非静默忽略），让「旧版 UI 下发延迟档」成为可诊断错误。 */
        set_error(h, "mode.latency removed by ADR-006 (latency is measurement-only)");
        return AURADSP_E_PARAM;
    }
    if (!strcmp(id, "channels.mode") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value;
        if (v != 0) {
            set_error(h, "multichannel matrix lands in Phase A follow-up (ADR-003)");
            return AURADSP_E_UNSUPPORTED;
        }
        h->p.channels_mode.store(0);
        return AURADSP_OK;
    }
    /* ---- Liveprog（EEL2 实时可编程 DSP，v1.1 增量） ---- */
    if (!strcmp(id, "liveprog.enable") && bytes >= 4) {
        h->p.lp_enable.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_liveprog(h);   /* 只动 liveprog 链 */
        return AURADSP_OK;
    }
    if (!strcmp(id, "liveprog.code")) {
        /* value = UTF-8 脚本全文，bytes = 字节数（可不含 NUL）。
         * 注意：LiveProgStringParser 内部持 jdsp_lock，编译期间音频线程
         * 会短暂让出该锁（小脚本 ≈毫秒级），与 vendor 自家 app 行为一致。 */
        if (bytes == 0 || bytes > 256 * 1024) {
            set_error(h, "liveprog.code: size must be 1..256KiB");
            return AURADSP_E_PARAM;
        }
        char* buf = (char*)malloc((size_t)bytes + 1);
        if (!buf) { set_error(h, "liveprog.code: OOM"); return AURADSP_E_IO; }
        memcpy(buf, value, bytes);
        buf[bytes] = 0;
        const int rc = LiveProgStringParser(&h->jdsp, buf);
        free(buf);
        if (rc != 1) {
            h->lp_status = rc;
            set_error(h, checkErrorCode(rc));
            return AURADSP_E_PARAM;
        }
        lp_refresh_sliders(h);
        h->lp_status = 1;
        free(h->lp_code);
        h->lp_code = (char*)malloc((size_t)bytes + 1);
        if (h->lp_code) {
            memcpy(h->lp_code, value, bytes);
            h->lp_code[bytes] = 0;
            h->lp_code_len = bytes;
        }
        /* 代码热替换后保持使能状态一致 */
        if (h->open.load() && h->p.lp_enable.load(std::memory_order_relaxed))
            LiveProgEnable(&h->jdsp);
        return AURADSP_OK;
    }
    if (!strcmp(id, "liveprog.unload") && bytes >= 4) {
        /* 停用并清编译态（不销毁 VM，保留下一次加载的快速路径） */
        h->p.lp_enable.store(0);
        h->jdsp.eel.compileSucessfully = 0;
        h->lp_status = 0;
        if (h->open.load()) apply_liveprog(h);
        return AURADSP_OK;
    }
    if (!strncmp(id, "liveprog.param", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) { set_error(h, "unknown param id"); return AURADSP_E_PARAM; }
        const int idx = d - '1';
        h->p.lp_param[idx].store(*(const float*)value, std::memory_order_relaxed);
        if (h->lp_slider_ptr[idx])
            *h->lp_slider_ptr[idx] = *(const float*)value;
        return AURADSP_OK;
    }
    /* ---- 卷积 / IR（v1.1 M4） ---- */
    if (!strcmp(id, "convolver.enable") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value ? 1 : 0;
        if (v && !h->ir_ready.load(std::memory_order_relaxed)) {
            set_error(h, "未加载脉冲响应：请先在 03 卡片点击「打开 IR」选择 .wav 文件，再启用卷积混响");
            return AURADSP_E_STATE;
        }
        h->p.conv_enable.store(v);
        if (h->open.load()) apply_convolver(h);
        compute_latency(h, &h->latency_ms);
        return AURADSP_OK;
    }
    if (!strcmp(id, "convolver.ir.path")) {
        /* value = UTF-8 路径，bytes = 字节数。加载成功不自动使能（UI 明确开）。 */
        if (!h->open.load()) { set_error(h, "convolver.ir.path: engine closed"); return AURADSP_E_STATE; }
        if (bytes == 0 || bytes > 4096) {
            set_error(h, "convolver.ir.path: invalid length");
            return AURADSP_E_PARAM;
        }
        char* pbuf = (char*)malloc((size_t)bytes + 1);
        if (!pbuf) { set_error(h, "convolver.ir.path: OOM"); return AURADSP_E_IO; }
        memcpy(pbuf, value, bytes);
        pbuf[bytes] = 0;
        const auradsp_status st = load_ir_file(h, pbuf);
        free(pbuf);
        if (st != AURADSP_OK) return st;
        /* 若已在使能态，重载 IR 后保持生效 */
        if (h->p.conv_enable.load(std::memory_order_relaxed) && h->open.load())
            apply_convolver(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "convolver.mix") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.conv_mix.store(v);
        /* 干湿比 1.0 等价于上游原行为（纯湿），此时关掉混合路径省一次拷贝 */
        h->jdsp.auraConvWet = v;
        h->jdsp.auraConvDry = 1.0f - v;
        h->jdsp.auraConvMixUsed = (v < 0.999f) ? 1 : 0;
        return AURADSP_OK;
    }
    if (!strcmp(id, "convolver.clear") && bytes >= 4) {
        h->p.conv_enable.store(0);
        h->ir_ready.store(false);
        h->ir_frames.store(0);
        h->ir_channels.store(0);
        h->ir_src_rate.store(0);
        h->ir_peak.store(0.0f);
        memset(h->ir_spectrum, 0, sizeof(h->ir_spectrum));
        if (h->open.load()) apply_convolver(h);
        return AURADSP_OK;
    }
    /* ---- 任意响应均衡器（ArbMag / AutoEq GraphicEQ） ---- */
    if (!strcmp(id, "arbmag.enable") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value ? 1 : 0;
        if (v && !h->p.arbmag_ready.load(std::memory_order_relaxed)) {
            set_error(h, "未加载响应曲线：请先配置或粘贴 GraphicEQ 节点，再启用任意响应 EQ");
            return AURADSP_E_STATE;
        }
        h->p.arbmag_enable.store(v);
        if (h->open.load()) apply_arbmag(h);
        compute_latency(h, &h->latency_ms);
        return AURADSP_OK;
    }
    if (!strcmp(id, "arbmag.string")) {
        if (bytes == 0 || bytes > 256 * 1024) {
            set_error(h, "arbmag.string: size must be 1..256KiB");
            return AURADSP_E_PARAM;
        }
        char* buf = (char*)malloc((size_t)bytes + 1);
        if (!buf) { set_error(h, "arbmag.string: OOM"); return AURADSP_E_IO; }
        memcpy(buf, value, bytes);
        buf[bytes] = 0;
        ArbitraryResponseEqualizerStringParser(&h->jdsp, buf);
        free(buf);
        const int nodes = (int)h->jdsp.arbMag.instance.coeffGen.nodesCount;
        h->p.arbmag_nodes.store(nodes);
        h->p.arbmag_ready.store(nodes > 0 ? 1 : 0);
        if (h->open.load() && h->p.arbmag_enable.load(std::memory_order_relaxed)) {
            apply_arbmag(h);
        }
        return AURADSP_OK;
    }
    /* ---- M3-a：轻量效果开关 ---- */
    if (!strcmp(id, "tube.enable") && bytes >= 4) {
        h->p.tube_enable.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_tube(h);   /* T0，无守卫 */
        return AURADSP_OK;
    }
    if (!strcmp(id, "tube.gain") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -3.0f) db = -3.0f; if (db > 12.0f) db = 12.0f;
        h->p.tube_gain.store(db);
        if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed))
            VacuumTubeSetGain(&h->jdsp, (double)db);
        return AURADSP_OK;
    }
    /* P-011：音色/混合/补偿（vendor 直接下发，RT 只读；未 open 只存值，create/apply_tube 推送） */
    if (!strcmp(id, "tube.style") && bytes >= 4) {
        int32_t v = *(const int32_t*)value;
        if (v < 0) v = 0; if (v > 2) v = 2;
        h->p.tube_style.store(v);
        if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed))
            VacuumTubeSetCharacter(&h->jdsp, (int)v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "tube.mix") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0.0f) v = 0.0f; if (v > 1.0f) v = 1.0f;
        h->p.tube_mix.store(v);
        if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed))
            VacuumTubeSetDryWet(&h->jdsp, v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "tube.compensation") && bytes >= 4) {
        float db = *(const float*)value;
        if (db < -12.0f) db = -12.0f; if (db > 12.0f) db = 12.0f;
        h->p.tube_compensation.store(db);
        if (h->open.load() && h->p.tube_enable.load(std::memory_order_relaxed))
            VacuumTubeSetOutComp(&h->jdsp, (double)db);
        return AURADSP_OK;
    }
    /* ---- 动态压限器 (Compressor, FFTCompander) ---- */
    if (!strcmp(id, "comp.enable") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value ? 1 : 0;
        h->p.comp_enable.store(v);
        if (h->open.load()) apply_comp(h);
        compute_latency(h, &h->latency_ms);
        return AURADSP_OK;
    }
    if (!strcmp(id, "comp.timeconstant") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0.02f) v = 0.02f; if (v > 0.5f) v = 0.5f;
        h->p.comp_timeconstant.store(v);
        if (h->open.load() && h->p.comp_enable.load(std::memory_order_relaxed))
            apply_comp(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "comp.granularity") && bytes >= 4) {
        int32_t v = *(const int32_t*)value;
        if (v < 0) v = 0; if (v > 4) v = 4;
        h->p.comp_granularity.store(v);
        if (h->open.load() && h->p.comp_enable.load(std::memory_order_relaxed))
            apply_comp(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "comp.tfresolution") && bytes >= 4) {
        int32_t v = *(const int32_t*)value;
        if (v < 0) v = 0; if (v > 3) v = 3;
        h->p.comp_tfresolution.store(v);
        if (h->open.load() && h->p.comp_enable.load(std::memory_order_relaxed))
            apply_comp(h);
        return AURADSP_OK;
    }
    /* ---- M5-b 低频搁架 ---- */
    if (!strcmp(id, "shelf.enable") && bytes >= 4) {
        h->p.shelf_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "shelf.freq") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 40) v = 40; if (v > 400) v = 400;
        h->p.shelf_freq.store(v);
        shelf_recalc(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "shelf.gain") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < -15) v = -15; if (v > 15) v = 15;
        h->p.shelf_gain.store(v);
        shelf_recalc(h);
        return AURADSP_OK;
    }
    /* ---- BassMono 低频单声道化 ---- */
    if (!strcmp(id, "bassmono.enable") && bytes >= 4) {
        h->p.bassmono_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "bassmono.freq") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 20) v = 20; if (v > 300) v = 300;
        h->p.bassmono_freq.store(v);
        return AURADSP_OK;
    }
    /* ---- Haas 差分环绕 ---- */
    if (!strcmp(id, "haas.enable") && bytes >= 4) {
        h->p.haas_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "haas.delay") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 25) v = 25;
        h->p.haas_delay_ms.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "haas.mix") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.haas_mix.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "haas.side") && bytes >= 4) {
        h->p.haas_side.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    /* ---- 激励器 ---- */
    if (!strcmp(id, "exciter.enable") && bytes >= 4) {
        h->p.exciter_enable.store(*(const int32_t*)value ? 1 : 0);
        return AURADSP_OK;
    }
    if (!strcmp(id, "exciter.amount") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.exciter_amount.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "exciter.hifreq") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 3000) v = 3000; if (v > 10000) v = 10000;
        h->p.exciter_hifreq.store(v);
        return AURADSP_OK;
    }
    /* ---- VDC 空间校正（M5-3） ---- */
    if (!strcmp(id, "ddc.load")) {
        if (!h->open.load()) { set_error(h, "ddc.load: engine closed"); return AURADSP_E_STATE; }
        if (bytes == 0 || bytes > 4096) {
            set_error(h, "ddc.load: invalid path length");
            return AURADSP_E_PARAM;
        }
        char* pbuf = (char*)malloc((size_t)bytes + 1);
        if (!pbuf) { set_error(h, "ddc.load: OOM"); return AURADSP_E_IO; }
        memcpy(pbuf, value, bytes);
        pbuf[bytes] = 0;
        /* 读文件（UTF-8 路径 + 尺寸限额），内容交给 DDCStringParser */
        auradsp_status st = AURADSP_OK;
        char* content = read_text_file(h, pbuf, 4 * 1024 * 1024, &st);
        free(pbuf);
        if (!content) return st;
        const int rc = DDCStringParser(&h->jdsp, content);
        free(content);
        /* vendor 语义：1=加载成功，0=与当前相同（跳过），-1=失败 */
        if (rc < 0) {
            h->p.ddc_ready.store(0);
            set_error(h, "ddc.load: parse failed (need SR_44100/SR_48000 coeffs)");
            return AURADSP_E_PARAM;
        }
        h->p.ddc_ready.store(1);
        /* 加载成功不自动使能（UI 明确开） */
        return AURADSP_OK;
    }
    if (!strcmp(id, "ddc.enable") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value ? 1 : 0;
        if (v && !h->p.ddc_ready.load(std::memory_order_relaxed)) {
            set_error(h, "未加载 VDC 滤波器：请先在 04 卡片点击「打开」选择 .vdc 文件，再启用 VDC");
            return AURADSP_E_STATE;
        }
        const int rc = v ? DDCEnable(&h->jdsp, 1) : (DDCDisable(&h->jdsp), 1);
        if (v && rc != 1) {
            h->p.ddc_enable.store(0);
            set_error(h, "ddc.enable: rejected by engine");
            return AURADSP_E_STATE;
        }
        h->p.ddc_enable.store(v);
        return AURADSP_OK;
    }
    /* ---- [ADR-003 Phase A] 多声道矩阵 ---- */
    if (!strcmp(id, "channels.count") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value;
        /* 只接受 2 / 6 / 8（立体声 / 5.1 / 7.1）；其它值拒收而不是静默截断，
         * 否则驱动层缓冲尺寸与引擎解释不一致会直接越界。 */
        if (v != 2 && v != 6 && v != 8) {
            set_error(h, "channels.count: must be 2 (stereo), 6 (5.1) or 8 (7.1)");
            return AURADSP_E_PARAM;
        }
        h->channel_count.store(v);
        return AURADSP_OK;
    }

    /* ---- 引擎配置项（来自 AppConfig，此前全部被硬编码旁路） ---- */
    if (!strcmp(id, "gate.maxIrSeconds") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0.1f) v = 0.1f;
        if (v > 600.0f) v = 600.0f;
        h->gate_max_ir_seconds.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "gate.maxFileMb") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 1.0f) v = 1.0f;
        if (v > 4096.0f) v = 4096.0f;
        h->gate_max_file_mb.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "viz.fftSize") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value;
        /* 必须 2 的幂且落在 [1024, kVizFftMax]。缓冲区在 create 时已按
         * kVizFftMax 一次性分配，这里只改使用长度，不重分配、不动指针。 */
        if (v < 1024 || v > kVizFftMax || (v & (v - 1)) != 0) {
            set_error(h, "viz.fftSize: must be a power of two within [1024, 8192]");
            return AURADSP_E_PARAM;
        }
        /* 汉宁窗内容依赖窗长，重建会与 RT 的 emit_viz 竞争。因此只允许在
         * 「尚未产出过任何频谱帧」时修改——即引擎启动初始化阶段。
         * 这是配置项（config.vizFftSize）而非实时滑块，语义正好吻合。 */
        if (h->viz_emitted.load(std::memory_order_relaxed)) {
            set_error(h, "viz.fftSize: only changeable before the first viz frame");
            return AURADSP_E_STATE;
        }
        rebuild_hann(h, (int)v);
        h->viz_fft_size.store((int)v);
        return AURADSP_OK;
    }

    /* ---- M3.5-a：处理顺序（P-004 表驱动链） ---- */
    if (!strcmp(id, "graph.order") && bytes >= 16) {
        char* ord = (char*)malloc((size_t)bytes + 1);
        if (!ord) { set_error(h, "graph.order: OOM"); return AURADSP_E_IO; }
        memcpy(ord, value, bytes);
        ord[bytes] = 0;
        const int rc = JamesDSPRebuildChain(&h->jdsp, ord);
        free(ord);
        if (rc != 0) {
            set_error(h, "graph.order: invalid list (need all 12 stages exactly once)");
            return AURADSP_E_PARAM;
        }
        return AURADSP_OK;
    }
    /* ---- M5-c 参数化混响 ---- */
    if (!strcmp(id, "freeverb.enable") && bytes >= 4) {
        /* ADR-006：不再因延迟档拒绝，可自由启用。 */
        const int32_t v = *(const int32_t*)value ? 1 : 0;
        h->p.fv_enable.store(v);
        compute_latency(h, &h->latency_ms);
        return AURADSP_OK;
    }
    if (!strcmp(id, "freeverb.decay") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.fv_decay.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "freeverb.damp") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.fv_damp.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "freeverb.wet") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.fv_wet.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "freeverb.dry") && bytes >= 4) {
        float v = *(const float*)value;
        if (v < 0) v = 0; if (v > 1) v = 1;
        h->p.fv_dry.store(v);
        return AURADSP_OK;
    }
    if (!strcmp(id, "crossfeed.enable") && bytes >= 4) {
        h->p.xfeed_enable.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_crossfeed(h);
        compute_latency(h, &h->latency_ms);
        return AURADSP_OK;
    }
    if (!strcmp(id, "crossfeed.mode") && bytes >= 4) {
        int32_t m = *(const int32_t*)value;
        if (m < 0) m = 0; if (m > 3) m = 3;
        h->p.xfeed_mode.store(m);
        if (h->open.load() && h->p.xfeed_enable.load()) apply_crossfeed(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "crossfeed.fcut") && bytes >= 4) {
        float f = *(const float*)value;
        if (f < 300.0f) f = 300.0f; if (f > 2000.0f) f = 2000.0f;
        h->p.xfeed_fcut.store(f);
        if (h->open.load() && h->p.xfeed_enable.load() && h->p.xfeed_mode.load() == 3) apply_crossfeed(h);
        return AURADSP_OK;
    }
    if (!strcmp(id, "crossfeed.feed") && bytes >= 4) {
        float d = *(const float*)value;
        if (d < 1.0f) d = 1.0f; if (d > 15.0f) d = 15.0f;
        h->p.xfeed_feed.store(d);
        if (h->open.load() && h->p.xfeed_enable.load() && h->p.xfeed_mode.load() == 3) apply_crossfeed(h);
        return AURADSP_OK;
    }
    set_error(h, "unknown param id");
    return AURADSP_E_PARAM;
}

auradsp_status auradsp_get_param(auradsp_handle h, const char* id,
                                 void* out_value, uint32_t bytes) {
    if (!h || !id || !out_value) return AURADSP_E_PARAM;
    std::lock_guard<std::mutex> lk(h->ctrl_mutex);
    if (!strcmp(id, "bass.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.bass_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.gain") && bytes >= 4) { *(float*)out_value = h->p.bass_gain.load(); return AURADSP_OK; }
    if (!strcmp(id, "reverb.preset") && bytes >= 4) { *(int32_t*)out_value = h->p.reverb_preset.load(); return AURADSP_OK; }
    if (!strcmp(id, "stereo.mix") && bytes >= 4) { *(float*)out_value = h->p.stereo_mix.load(); return AURADSP_OK; }
    if (!strcmp(id, "stereo.bandUsed") && bytes >= 4) { *(int32_t*)out_value = h->p.stereo_band_used.load(); return AURADSP_OK; }
    if (!strncmp(id, "stereo.band", 11) && bytes >= 4) {
        const char d = id[11];
        if (d < '1' || d > '5' || id[12] != 0) return AURADSP_E_PARAM;
        *(float*)out_value = h->p.stereo_band[d - '1'].load();
        return AURADSP_OK;
    }
    if (!strcmp(id, "eq.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.eq_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "limiter.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.limiter_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "post.gain") && bytes >= 4) { *(float*)out_value = h->p.post_gain.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.outgain") && bytes >= 4) { *(float*)out_value = h->p.bass_outgain.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.autogain") && bytes >= 4) { *(int32_t*)out_value = h->p.bass_autogain.load(); return AURADSP_OK; }
    if (!strcmp(id, "eq.outgain") && bytes >= 4) { *(float*)out_value = h->p.eq_outgain.load(); return AURADSP_OK; }
    if (!strcmp(id, "eq.autogain") && bytes >= 4) { *(int32_t*)out_value = h->p.eq_autogain.load(); return AURADSP_OK; }
    if (!strcmp(id, "tube.outgain") && bytes >= 4) { *(float*)out_value = h->p.tube_outgain.load(); return AURADSP_OK; }
    if (!strcmp(id, "tube.autogain") && bytes >= 4) { *(int32_t*)out_value = h->p.tube_autogain.load(); return AURADSP_OK; }
    if (!strcmp(id, "dyneq.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.dyneq_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "dyneq.attack") && bytes >= 4) { *(float*)out_value = h->p.dyneq_attack.load(); return AURADSP_OK; }
    if (!strcmp(id, "dyneq.release") && bytes >= 4) { *(float*)out_value = h->p.dyneq_release.load(); return AURADSP_OK; }
#define DYNEQ_BAND_GET(tag, P) \
    if (!strcmp(id, "dyneq." tag ".enable") && bytes >= 4) { *(int32_t*)out_value = h->p.dyneq_##P##_enable.load(); return AURADSP_OK; } \
    if (!strcmp(id, "dyneq." tag ".freq") && bytes >= 4) { *(float*)out_value = h->p.dyneq_##P##_freq.load(); return AURADSP_OK; } \
    if (!strcmp(id, "dyneq." tag ".q") && bytes >= 4) { *(float*)out_value = h->p.dyneq_##P##_q.load(); return AURADSP_OK; } \
    if (!strcmp(id, "dyneq." tag ".gain") && bytes >= 4) { *(float*)out_value = h->p.dyneq_##P##_gain.load(); return AURADSP_OK; } \
    if (!strcmp(id, "dyneq." tag ".range") && bytes >= 4) { *(float*)out_value = h->p.dyneq_##P##_range.load(); return AURADSP_OK; } \
    if (!strcmp(id, "dyneq." tag ".threshold") && bytes >= 4) { *(float*)out_value = h->p.dyneq_##P##_threshold.load(); return AURADSP_OK; }
    DYNEQ_BAND_GET("low", l)
    DYNEQ_BAND_GET("mid", m)
    DYNEQ_BAND_GET("high", h)
#undef DYNEQ_BAND_GET
    if (!strcmp(id, "comp.outgain") && bytes >= 4) { *(float*)out_value = h->p.comp_outgain.load(); return AURADSP_OK; }
    if (!strcmp(id, "comp.autogain") && bytes >= 4) { *(int32_t*)out_value = h->p.comp_autogain.load(); return AURADSP_OK; }
    if (!strcmp(id, "reverb.outgain") && bytes >= 4) { *(float*)out_value = h->p.reverb_outgain.load(); return AURADSP_OK; }
    if (!strcmp(id, "reverb.autogain") && bytes >= 4) { *(int32_t*)out_value = h->p.reverb_autogain.load(); return AURADSP_OK; }
    if (!strcmp(id, "gate.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.gate_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "gate.threshold") && bytes >= 4) { *(float*)out_value = h->p.gate_threshold.load(); return AURADSP_OK; }
    if (!strcmp(id, "gate.attack") && bytes >= 4) { *(float*)out_value = h->p.gate_attack.load(); return AURADSP_OK; }
    if (!strcmp(id, "gate.release") && bytes >= 4) { *(float*)out_value = h->p.gate_release.load(); return AURADSP_OK; }
    if (!strcmp(id, "gate.autogain") && bytes >= 4) { *(int32_t*)out_value = h->p.gate_autogain.load(); return AURADSP_OK; }
    if (!strcmp(id, "deesser.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.deesser_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "deesser.freq") && bytes >= 4) { *(float*)out_value = h->p.deesser_freq.load(); return AURADSP_OK; }
    if (!strcmp(id, "deesser.amount") && bytes >= 4) { *(float*)out_value = h->p.deesser_amount.load(); return AURADSP_OK; }
    if (!strcmp(id, "loudness.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.loudness_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "loudness.amount") && bytes >= 4) { *(float*)out_value = h->p.loudness_amount.load(); return AURADSP_OK; }
    if (!strcmp(id, "filter.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.filter_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "filter.type") && bytes >= 4) { *(int32_t*)out_value = h->p.filter_type.load(); return AURADSP_OK; }
    if (!strcmp(id, "filter.freq") && bytes >= 4) { *(float*)out_value = h->p.filter_freq.load(); return AURADSP_OK; }
    if (!strcmp(id, "filter.q") && bytes >= 4) { *(float*)out_value = h->p.filter_q.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.harmonics") && bytes >= 4) { *(float*)out_value = h->p.bass_harmonics.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.harmonicblend") && bytes >= 4) { *(float*)out_value = h->p.bass_harmonicblend.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.subfreq") && bytes >= 4) { *(float*)out_value = h->p.bass_subfreq.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.cutoff") && bytes >= 4) { *(float*)out_value = h->p.bass_cutoff_f.load(); return AURADSP_OK; }
    if (!strcmp(id, "arbmag.outgain") && bytes >= 4) { *(float*)out_value = h->p.arbmag_outgain.load(); return AURADSP_OK; }
    if (!strcmp(id, "arbmag.autogain") && bytes >= 4) { *(int32_t*)out_value = h->p.arbmag_autogain.load(); return AURADSP_OK; }
    if (!strcmp(id, "input.gain") && bytes >= 4) { *(float*)out_value = h->p.input_gain.load(); return AURADSP_OK; }
    if (!strncmp(id, "input.balance.", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) return AURADSP_E_PARAM;
        *(float*)out_value = h->p.input_ch_gain[d - '1'].load();
        return AURADSP_OK;
    }
    /* mode.latency 已由 ADR-006 移除：回读同样明确报错，不返回陈旧值。 */
    if (!strcmp(id, "mode.latency") && bytes >= 4) { return AURADSP_E_PARAM; }
    if (!strcmp(id, "channels.mode") && bytes >= 4) { *(int32_t*)out_value = h->p.channels_mode.load(); return AURADSP_OK; }
    /* ---- Liveprog 回读（v1.1） ---- */
    if (!strcmp(id, "liveprog.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.lp_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "liveprog.status") && bytes >= 4) { *(int32_t*)out_value = h->lp_status; return AURADSP_OK; }
    if (!strcmp(id, "liveprog.code")) {
        if (!h->lp_code) { *(char*)out_value = 0; return AURADSP_OK; }
        if (bytes < h->lp_code_len + 1) { set_error(h, "liveprog.code: buffer too small"); return AURADSP_E_PARAM; }
        memcpy(out_value, h->lp_code, h->lp_code_len + 1);
        return AURADSP_OK;
    }
    if (!strncmp(id, "liveprog.param", 14) && bytes >= 4) {
        const char d = id[14];
        if (d < '1' || d > '8' || id[15] != 0) return AURADSP_E_PARAM;
        *(float*)out_value = h->p.lp_param[d - '1'].load();
        return AURADSP_OK;
    }
    /* ---- 卷积 / IR 回读（v1.1 M4） ---- */
    if (!strcmp(id, "convolver.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.conv_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "convolver.ready") && bytes >= 4) { *(int32_t*)out_value = h->ir_ready.load() ? 1 : 0; return AURADSP_OK; }
    if (!strcmp(id, "convolver.ir.frames") && bytes >= 4) { *(int32_t*)out_value = h->ir_frames.load(); return AURADSP_OK; }
    if (!strcmp(id, "convolver.ir.channels") && bytes >= 4) { *(int32_t*)out_value = h->ir_channels.load(); return AURADSP_OK; }
    if (!strcmp(id, "convolver.ir.srcRate") && bytes >= 4) { *(int32_t*)out_value = h->ir_src_rate.load(); return AURADSP_OK; }
    if (!strcmp(id, "convolver.ir.peak") && bytes >= 4) { *(float*)out_value = h->ir_peak.load(); return AURADSP_OK; }
    if (!strcmp(id, "convolver.ir.spectrum")) {
        if (!h->ir_ready.load()) return AURADSP_E_STATE;
        const int ch = h->ir_channels.load();
        if (ch <= 0 || ch > 8) return AURADSP_E_STATE;
        const size_t req = (size_t)ch * AURADSP_VIZ_BANDS * sizeof(float);
        if (bytes < req) {
            set_error(h, "convolver.ir.spectrum: buffer too small");
            return AURADSP_E_PARAM;
        }
        memcpy(out_value, h->ir_spectrum, req);
        return AURADSP_OK;
    }
    if (!strcmp(id, "convolver.mix") && bytes >= 4) { *(float*)out_value = h->p.conv_mix.load(); return AURADSP_OK; }
    if (!strcmp(id, "ddc.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.ddc_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "ddc.ready") && bytes >= 4) { *(int32_t*)out_value = h->p.ddc_ready.load(); return AURADSP_OK; }
    if (!strcmp(id, "tube.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.tube_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "tube.gain") && bytes >= 4) { *(float*)out_value = h->p.tube_gain.load(); return AURADSP_OK; }
    if (!strcmp(id, "tube.style") && bytes >= 4) { *(int32_t*)out_value = h->p.tube_style.load(); return AURADSP_OK; }
    if (!strcmp(id, "tube.mix") && bytes >= 4) { *(float*)out_value = h->p.tube_mix.load(); return AURADSP_OK; }
    if (!strcmp(id, "tube.compensation") && bytes >= 4) { *(float*)out_value = h->p.tube_compensation.load(); return AURADSP_OK; }
    if (!strcmp(id, "comp.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.comp_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "comp.timeconstant") && bytes >= 4) { *(float*)out_value = h->p.comp_timeconstant.load(); return AURADSP_OK; }
    if (!strcmp(id, "comp.granularity") && bytes >= 4) { *(int32_t*)out_value = h->p.comp_granularity.load(); return AURADSP_OK; }
    if (!strcmp(id, "comp.tfresolution") && bytes >= 4) { *(int32_t*)out_value = h->p.comp_tfresolution.load(); return AURADSP_OK; }
    if (!strcmp(id, "crossfeed.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.xfeed_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "crossfeed.mode") && bytes >= 4) { *(int32_t*)out_value = h->p.xfeed_mode.load(); return AURADSP_OK; }
    if (!strcmp(id, "crossfeed.fcut") && bytes >= 4) { *(float*)out_value = h->p.xfeed_fcut.load(); return AURADSP_OK; }
    if (!strcmp(id, "crossfeed.feed") && bytes >= 4) { *(float*)out_value = h->p.xfeed_feed.load(); return AURADSP_OK; }
    if (!strcmp(id, "shelf.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.shelf_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "bassmono.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.bassmono_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "bassmono.freq") && bytes >= 4) { *(float*)out_value = h->p.bassmono_freq.load(); return AURADSP_OK; }
    if (!strcmp(id, "haas.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.haas_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "haas.delay") && bytes >= 4) { *(float*)out_value = h->p.haas_delay_ms.load(); return AURADSP_OK; }
    if (!strcmp(id, "haas.mix") && bytes >= 4) { *(float*)out_value = h->p.haas_mix.load(); return AURADSP_OK; }
    if (!strcmp(id, "haas.side") && bytes >= 4) { *(int32_t*)out_value = h->p.haas_side.load(); return AURADSP_OK; }
    if (!strcmp(id, "exciter.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.exciter_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "exciter.amount") && bytes >= 4) { *(float*)out_value = h->p.exciter_amount.load(); return AURADSP_OK; }
    if (!strcmp(id, "exciter.hifreq") && bytes >= 4) { *(float*)out_value = h->p.exciter_hifreq.load(); return AURADSP_OK; }
    if (!strcmp(id, "shelf.freq") && bytes >= 4) { *(float*)out_value = h->p.shelf_freq.load(); return AURADSP_OK; }
    if (!strcmp(id, "shelf.gain") && bytes >= 4) { *(float*)out_value = h->p.shelf_gain.load(); return AURADSP_OK; }
    if (!strcmp(id, "freeverb.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.fv_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "freeverb.decay") && bytes >= 4) { *(float*)out_value = h->p.fv_decay.load(); return AURADSP_OK; }
    if (!strcmp(id, "freeverb.damp") && bytes >= 4) { *(float*)out_value = h->p.fv_damp.load(); return AURADSP_OK; }
    if (!strcmp(id, "freeverb.wet") && bytes >= 4) { *(float*)out_value = h->p.fv_wet.load(); return AURADSP_OK; }
    if (!strcmp(id, "freeverb.dry") && bytes >= 4) { *(float*)out_value = h->p.fv_dry.load(); return AURADSP_OK; }
    if (!strcmp(id, "channels.count") && bytes >= 4) { *(int32_t*)out_value = h->channel_count.load(); return AURADSP_OK; }
    if (!strcmp(id, "gate.maxIrSeconds") && bytes >= 4) { *(float*)out_value = h->gate_max_ir_seconds.load(); return AURADSP_OK; }
    if (!strcmp(id, "gate.maxFileMb") && bytes >= 4) { *(float*)out_value = h->gate_max_file_mb.load(); return AURADSP_OK; }
    if (!strcmp(id, "viz.fftSize") && bytes >= 4) { *(int32_t*)out_value = h->viz_fft_size.load(); return AURADSP_OK; }
    /* ---- 任意响应均衡器（ArbMag）回读 ---- */
    if (!strcmp(id, "arbmag.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.arbmag_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "arbmag.ready") && bytes >= 4) { *(int32_t*)out_value = h->p.arbmag_ready.load(); return AURADSP_OK; }
    if (!strcmp(id, "arbmag.nodeCount") && bytes >= 4) { *(int32_t*)out_value = h->p.arbmag_nodes.load(); return AURADSP_OK; }
    /* graph.effects：M3 链视图注册表（固定 vendor 顺序；exposed=参数通道已开放） */
    if (!strcmp(id, "graph.effects") && bytes >= 2048) {
        /* 21 项注册表：id / 延迟档 / 参数通道是否开放（exposed=false 的节点
         * 在链视图里展示为"参数开放中"占位）。
         * 注：此前写「14 项」，随 comp/arbmag 暴露与自研效果增补早已增至 20 项，
         * dyneq 入库（e1375b0）后现为 21 项，注释未同步。增删改条目时必须同步此处计数。
         * 容量门 2048：21 项时 payload 已近 1000 字节，再增条目会静默截断 JSON；
         * 宁可让小 buffer 拿 E_PARAM，也不断尾残 JSON。 */
        const char* reg =
            "["
            "{\"id\":\"tube\",\"tier\":0,\"exposed\":true},"
            "{\"id\":\"bass\",\"tier\":0,\"exposed\":true},"
            "{\"id\":\"eq\",\"tier\":0,\"exposed\":true},"
            "{\"id\":\"convolver\",\"tier\":2,\"exposed\":true},"
            "{\"id\":\"liveprog\",\"tier\":0,\"exposed\":true},"
            "{\"id\":\"crossfeed\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"stereo\",\"tier\":0,\"exposed\":true},"
            "{\"id\":\"reverb\",\"tier\":2,\"exposed\":true},"
            "{\"id\":\"post\",\"tier\":0,\"exposed\":true},"
            "{\"id\":\"limiter\",\"tier\":0,\"exposed\":true},"
            "{\"id\":\"comp\",\"tier\":2,\"exposed\":true},"
            "{\"id\":\"bassmono\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"haas\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"exciter\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"gate\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"filter\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"dyneq\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"loudness\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"arbmag\",\"tier\":2,\"exposed\":true},"
            "{\"id\":\"ddc\",\"tier\":1,\"exposed\":true},"
            "{\"id\":\"vdc\",\"tier\":0,\"exposed\":false}"
            "]";
        snprintf((char*)out_value, bytes, "%s", reg);
        return AURADSP_OK;
    }
    return AURADSP_E_PARAM;
}

auradsp_state auradsp_get_state(auradsp_handle h) {
    return h ? (auradsp_state)h->state.load() : AURADSP_STATE_ERROR;
}

double auradsp_get_latency_ms(auradsp_handle h) {
    if (!h) return 0;
    double ms = 0.0;
    compute_latency(h, &ms);
    return ms;
}

const char* auradsp_last_error(auradsp_handle h) {
    return h ? h->last_error : "null handle";
}

uint32_t auradsp_viz_read(auradsp_handle h, auradsp_viz_frame* out, uint32_t max_frames) {
    if (!h || !out || !max_frames) return 0;
    return h->viz.read(out, max_frames);
}

/* ---- 第三方插件宿主（M1：VST3 / CLAP 64位） ---- */
int auradsp_plugin_scan(auradsp_handle h, const char* extra_dirs_json, int deep_scan) {
    if (!h || !h->plugin_host) return 0;
    std::string extra = extra_dirs_json ? extra_dirs_json : "";
    return h->plugin_host->scanPlugins(extra, deep_scan != 0);
}

// C2：分块扫描。与一次性 scan 共用同一套枚举与元数据提取实现，
// 结果一致；差别只在于可被切成小步、并在步间让出调用线程。
int auradsp_plugin_scan_begin(auradsp_handle h, const char* extra_dirs_json, int deep_scan) {
    if (!h || !h->plugin_host) return 0;
    std::string extra = extra_dirs_json ? extra_dirs_json : "";
    return h->plugin_host->scanBegin(extra, deep_scan != 0);
}

int auradsp_plugin_scan_step(auradsp_handle h, int max_items) {
    if (!h || !h->plugin_host) return 0;
    return h->plugin_host->scanStep(max_items);
}

int auradsp_plugin_scan_progress(auradsp_handle h, int* out_total) {
    if (!h || !h->plugin_host) return -1;
    int processed = h->plugin_host->scanProcessed();
    if (out_total) *out_total = h->plugin_host->scanTotal();
    return processed;
}

int auradsp_plugin_scan_end(auradsp_handle h) {
    if (!h || !h->plugin_host) return 0;
    return h->plugin_host->scanEnd();
}

int auradsp_plugin_get_count(auradsp_handle h) {
    if (!h || !h->plugin_host) return 0;
    return (int)h->plugin_host->getScannedCount();
}

int auradsp_plugin_get_item(auradsp_handle h, int index, char* out_json, int max_len) {
    if (!h || !h->plugin_host || !out_json || max_len <= 1 || index < 0) return 0;
    std::string json = h->plugin_host->getScannedItemJson((size_t)index);
    if ((int)json.length() >= max_len) {
        memcpy(out_json, json.data(), (size_t)(max_len - 1));
        out_json[max_len - 1] = '\0';
        return max_len - 1;
    }
    memcpy(out_json, json.data(), json.length());
    out_json[json.length()] = '\0';
    return (int)json.length();
}

int auradsp_plugin_get_all(auradsp_handle h, char* out_json, int max_len) {
    if (!h || !h->plugin_host || !out_json || max_len <= 1) return 0;
    std::string json = h->plugin_host->getAllScannedJson();
    if ((int)json.length() >= max_len) {
        memcpy(out_json, json.data(), (size_t)(max_len - 1));
        out_json[max_len - 1] = '\0';
        return max_len - 1;
    }
    memcpy(out_json, json.data(), json.length());
    out_json[json.length()] = '\0';
    return (int)json.length();
}

/* ---- 多插槽感知控制 (slot: 0..3，以 kMaxPluginSlots 为准) ---- */
int auradsp_plugin_get_num_slots(auradsp_handle h) {
    (void)h;
    return (int)auradsp::PluginHostManager::kMaxPluginSlots;
}

int auradsp_plugin_slot_load(auradsp_handle h, int slot, const char* path, const char* plugin_id) {
    if (!h || !h->plugin_host || !path || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    std::string id = plugin_id ? plugin_id : "";
    bool ok = h->plugin_host->loadPluginSlot((size_t)slot, path, id, h->sample_rate, (uint32_t)h->max_block);
    return ok ? 1 : 0;
}

int auradsp_plugin_slot_unload(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    h->plugin_host->unloadPluginSlot((size_t)slot);
    return 1;
}

int auradsp_plugin_slot_load_async(auradsp_handle h, int slot, const char* path, const char* plugin_id) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    std::string p = path ? path : "";
    std::string id = plugin_id ? plugin_id : "";
    return h->plugin_host->submitSlotLoadAsync((size_t)slot, p, id,
        h->plugin_host->getSampleRate(), h->plugin_host->getMaxBlockSize()) ? 1 : 0;
}

int auradsp_plugin_slot_unload_async(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return h->plugin_host->submitSlotUnloadAsync((size_t)slot) ? 1 : 0;
}

int auradsp_plugin_slot_task_state(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return h->plugin_host->slotTaskState((size_t)slot);
}

int auradsp_plugin_slot_set_bypass(auradsp_handle h, int slot, int bypass) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    h->plugin_host->setBypassSlot((size_t)slot, bypass != 0);
    return 1;
}

int auradsp_plugin_slot_get_bypass(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 1;
    return h->plugin_host->isBypassedSlot((size_t)slot) ? 1 : 0;
}

uint32_t auradsp_plugin_slot_get_latency(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return h->plugin_host->getLatencySlot((size_t)slot);
}

int auradsp_plugin_slot_get_status(auradsp_handle h, int slot, char* out_json, int max_len) {
    if (!h || !h->plugin_host || !out_json || max_len <= 1 || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    std::string json = h->plugin_host->getStatusJsonSlot((size_t)slot);
    if ((int)json.length() >= max_len) {
        memcpy(out_json, json.data(), (size_t)(max_len - 1));
        out_json[max_len - 1] = '\0';
        return max_len - 1;
    }
    memcpy(out_json, json.data(), json.length());
    out_json[json.length()] = '\0';
    return (int)json.length();
}

int auradsp_plugin_slot_show_editor(auradsp_handle h, int slot, const char* title) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    // E1：title 可空；为空时 C++ 侧退化为插件自报名。
    return h->plugin_host->showEditorSlot((size_t)slot, title ? title : "") ? 1 : 0;
}

int auradsp_plugin_slot_close_editor(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    h->plugin_host->closeEditorSlot((size_t)slot);
    return 1;
}

int auradsp_plugin_slot_is_editor_open(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return h->plugin_host->isEditorOpenSlot((size_t)slot) ? 1 : 0;
}

int auradsp_plugin_slot_save_preset(auradsp_handle h, int slot, const char* path) {
    if (!h || !h->plugin_host || !path || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return h->plugin_host->savePresetSlot((size_t)slot, path) ? 1 : 0;
}

int auradsp_plugin_slot_load_preset(auradsp_handle h, int slot, const char* path) {
    if (!h || !h->plugin_host || !path || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return h->plugin_host->loadPresetSlot((size_t)slot, path) ? 1 : 0;
}

int auradsp_plugin_slot_set_insert_stage(auradsp_handle h, int slot, int stage) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    h->plugin_host->setInsertStageSlot((size_t)slot, stage);
    return 1;
}

int auradsp_plugin_slot_get_insert_stage(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 3;
    return h->plugin_host->getInsertStageSlot((size_t)slot);
}

/* 兼容旧版单插槽（映射至 slot 0） */
int auradsp_plugin_load(auradsp_handle h, const char* path, const char* plugin_id) {
    return auradsp_plugin_slot_load(h, 0, path, plugin_id);
}

int auradsp_plugin_unload(auradsp_handle h) {
    return auradsp_plugin_slot_unload(h, 0);
}

int auradsp_plugin_set_bypass(auradsp_handle h, int bypass) {
    return auradsp_plugin_slot_set_bypass(h, 0, bypass);
}

int auradsp_plugin_get_bypass(auradsp_handle h) {
    return auradsp_plugin_slot_get_bypass(h, 0);
}

uint32_t auradsp_plugin_get_latency(auradsp_handle h) {
    return auradsp_plugin_slot_get_latency(h, 0);
}

int auradsp_plugin_get_status(auradsp_handle h, char* out_json, int max_len) {
    return auradsp_plugin_slot_get_status(h, 0, out_json, max_len);
}

} /* extern "C" */
