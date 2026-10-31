/*
 * auradsp_engine.c — AuraDSP Engines 统一 C ABI 实现（Desktop v1）
 *
 * 包装 engine/legacy（纯 C 算法核，原 vendor/libjamesdsp 收编而来，见
 * engine/legacy/PATCHES.md 的 14 条补丁登记；溯源见 source/ORIGIN.md、vendor/ORIGIN.md）。
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
#include "platform/port/env.h"
#include "plugins/integration/plugin_chain_adapter.h"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <mutex>
#include <new>

#if defined(_M_X64) || defined(__x86_64__) || defined(_M_IX86) || defined(__i386__)
#include <xmmintrin.h>
#endif

namespace {

/* 进程级全局初始化（NSEEL JIT 运行时），引用计数（对齐 Android 侧做法） */
std::mutex g_global_mutex;
int g_global_ref = 0;

/* [P2 静音门控] 读环境变量（create 控制线程一次性；不进 RT 路径）。
 * 平台差异已收敛到 port/env.h。 */
bool read_env(const char* name, char* buf, size_t cap) {
    return auradsp::platform::get_env(name, buf, cap);
}

/* [P2 静音门控] 门控状态推进（RT 线程，无锁无分配）。
 * 进入条件：输入连续静音 ≥ hold 且**本块输出残量** ≤ -120 dBFS（混响/延迟
 * 尾巴必须真的衰减完，否则切零会听到断崖）。退出只在块首输入扫描处发生。 */
void gate_update(auradsp_handle h, float in_peak, float out_peak, int frames) {
    if (!h->gate_enabled) {
        h->gate_active = false;
        h->gate_silent_frames = 0;
        h->gate_idle_frames = 0;
        return;
    }
    if (h->gate_active) {
        h->gate_idle_frames += frames;
        return;
    }
    if (in_peak <= h->gate_peak_thresh) {
        if (h->gate_silent_frames < h->gate_hold_frames) {
            h->gate_silent_frames += frames;
            if (h->gate_silent_frames > h->gate_hold_frames)
                h->gate_silent_frames = h->gate_hold_frames;
        }
    } else {
        h->gate_silent_frames = 0;
    }
    if (h->gate_silent_frames >= h->gate_hold_frames &&
        out_peak <= h->gate_resid_thresh) {
        h->gate_active = true;
        h->gate_idle_frames = 0;
    }
}

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

    /* 失败路径的全局引用回收（2026-10-31 审查修复）：create 内所有
     * return nullptr 分支此前都漏了 global_unref()，失败一次引用计数永久 +1。
     * RAII 守卫让任意早退自动回收，成功时解除。 */
    struct GlobalRefGuard {
        bool armed = true;
        ~GlobalRefGuard() { if (armed) global_unref(); }
    } ref_guard;

    auto* h = new (std::nothrow) auradsp_handle_s();
    if (!h) return nullptr;
    h->sample_rate = sample_rate;
    h->max_block = max_block_frames;
    if (!auradsp::plugin_chain_prepare(h, sample_rate, (uint32_t)max_block_frames)) {
        delete h;
        return nullptr;
    }
    h->fft_scratch = new (std::nothrow) float[kVizFftMax];
    h->hann = new (std::nothrow) float[kVizFftMax];
    if (!h->fft_scratch || !h->hann) {
        delete[] h->fft_scratch; delete[] h->hann; delete h; return nullptr;
    }
    h->viz_hist = new (std::nothrow) float[kVizFftMax * 2]();
    if (!h->viz_hist) {
        delete[] h->fft_scratch; delete[] h->hann; delete h; return nullptr;
    }
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
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist; delete[] h->eq_in_hist;
        delete[] h->shelf_scratch; delete[] h->conv_scratch;
        delete[] h->mx_scratch; delete[] h->mx_stereo;
        delete h; return nullptr;
    }
    /* Haas 延迟环：25ms 上限 + 一块余量，清零（开轮即录制，无陈旧音频 burst） */
    h->haas_ring_len = (int)(0.025 * sample_rate) + max_block_frames + 64;
    h->haas_ring = new (std::nothrow) float[(size_t)h->haas_ring_len]();
    if (!h->haas_ring) {
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist; delete[] h->eq_in_hist;
        delete[] h->shelf_scratch; delete[] h->conv_scratch;
        delete[] h->mx_scratch; delete[] h->mx_stereo;
        delete h; return nullptr;
    }

    /* B5 后续：arbmag 逐声道池（句柄级，create 分配；失败不算致命——
     * pool 的空位在 process 侧永远直通，与 legacy 上游构造失败容忍一致）。 */
    arbmag_pool_alloc(h);
    eq_pool_alloc(h);

    /* 注意：P-005 的 scratch 绑定必须放在 JamesDSPInit 之后——
     * JamesDSPInit 内部 memset(jdsp, 0, sizeof) 会清掉提前写入的指针 */

    for (int i = 0; i < kVizFftMax; ++i) h->hann[i] = 0.0f;
    rebuild_hann(h, kVizFftDefault);
    /* 产出间隔按实际 fs 归一到 33ms（≈30Hz）。
     * UI 侧默认 vizFps=20、每 50ms 拉一次且只取最新帧——旧实现 100Hz
     * 发射（fs/100）意味着约 70% 的双路 4096 点 FFT + 32 带映射在 RT
     * 线程上白算。30Hz 仍高于 UI 消费上限，不产生可见空档；44.1k/96k
     * 同样按 fs 归一。
     * 不用 std::max：Windows 头把 max 定义成宏，会把 std::max 展开坏
     * （MSVC C2589）。 */
    int viz_int = (int)(h->sample_rate / 30.0 + 0.5);
    if (viz_int < 1) viz_int = 1;
    h->viz_interval.store(viz_int);

    for (int i = 0; i < 8; ++i) {
        h->p.input_ch_gain[i].store(1.0f);
    }
    /* WP0 脚手架：逐声道输出补偿默认 0 dB（WP5 消费；显式覆盖让
     * tools/gen_param_contract.py 能取到数组默认）。 */
    for (int i = 0; i < 8; ++i) {
        h->p.post_gain_ch[i].store(0.0f);
    }
    /* [P2 静音门控] hold=2000ms；AURADSP_GATE=0 关闭；AURADSP_GATE_DB 覆盖
     * 静音判定阈值（默认 -90 dBFS）。create 为控制线程，读环境安全。 */
    h->gate_hold_frames = (int)(2.0f * sample_rate);
    if (h->gate_hold_frames < 1) h->gate_hold_frames = 1;
    {
        char env[32];
        if (read_env("AURADSP_GATE", env, sizeof(env)) && env[0] == '0')
            h->gate_enabled = false;
        if (read_env("AURADSP_GATE_DB", env, sizeof(env))) {
            float db = (float)atof(env);
            if (db < -140.0f) db = -140.0f;
            if (db > 0.0f) db = 0.0f;
            h->gate_peak_thresh = powf(10.0f, db * 0.05f);
        }
    }
    const float default_comp_freq[7] = {95.0f, 200.0f, 400.0f, 800.0f, 1600.0f, 3400.0f, 7500.0f};
    for (int i = 0; i < 7; ++i) {
        h->p.comp_freq[i].store(default_comp_freq[i]);
        h->p.comp_gain[i].store(-0.35f);
    }

    std::lock_guard<std::mutex> lk(h->ctrl_mutex);
    JamesDSPInit(&h->jdsp, max_block_frames, sample_rate);
    /* P-005：scratch 绑定（必须在 memset 之后）+ 默认纯湿（=上游行为） */
    h->jdsp.auraConvScratch = h->conv_scratch;
    h->jdsp.auraConvWet = 1.0f;
    h->jdsp.auraConvDry = 0.0f;
    h->jdsp.auraConvMixUsed = 0;
    JamesDSPInitFxGains(&h->jdsp);
    LiveProgSetChannels(&h->jdsp, h->channel_count.load()); /* [PATCHED-AuraDSP P-038] 同步声道数环境 */
    shelf_recalc(h);
    filter_recalc(h);
    apply_params_locked(h);
    /* WP1：MC FDN 混响 RT 状态显式复位（create 时尚未 open，直接清）。 */
    mc_reverb_reset(h);
    /* 空间音效 RT 状态显式复位（含新增的源/耳 pinna、mix/headazim 平滑器）。
     * 控制线程一次性开销，RT 无影响。 */
    spatial_reset(h);
    /* Lookahead Limiter RT 状态显式复位与初始化 */
    h->mc_limiter_la_len = (int)(0.0015 * sample_rate + 0.5);
    if (h->mc_limiter_la_len < 1) h->mc_limiter_la_len = 1;
    if (h->mc_limiter_la_len > auradsp_handle_s::kLimLookaheadMax)
        h->mc_limiter_la_len = auradsp_handle_s::kLimLookaheadMax;

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
    h->mc_limiter_dq_len = 0; /* PF-2：0 != 任何 la_len，首块强制重建 deque */
    h->open.store(true);
    h->state.store(AURADSP_STATE_PROCESSING);
    ref_guard.armed = false;
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
    auradsp::plugin_chain_reset(h);
    arbmag_pool_free(h);
    eq_pool_free(h);
    delete[] h->fft_scratch;
    delete[] h->hann;
    delete[] h->viz_hist; delete[] h->eq_in_hist;
    delete[] h->shelf_scratch;
    delete[] h->conv_scratch;
    delete[] h->mx_scratch;
    delete[] h->mx_stereo;
    delete[] h->haas_ring;
    free(h->lp_code);
    free(h->eq_curve);
    free(h->arbmag_string);
    delete h;
    global_unref();
}

void auradsp_process(auradsp_handle h, const float* in, float* out, int frames) {
    /* ABI 是公开边界：空缓冲指针在内部 FFI 契约里虽不会出现，但违规调用
     * 会直接踩空；一次分支换内存安全（RT 开销可忽略）。 */
    if (!h || !in || !out || !h->open.load(std::memory_order_acquire) || frames <= 0) return;
    /* 内存安全防御：防御驱动层 frames > max_block 导致的 scratch 堆缓冲区溢出 */
    if (frames > h->max_block) frames = h->max_block;
    /* E-03：给控制侧延迟计算留一个无竞争的设备域块长快照。 */
    h->lat_block_frames.store(frames, std::memory_order_relaxed);

    ScopedFtzDazGuard ftzGuard;
    const int st = h->state.load(std::memory_order_relaxed);

    /* [ADR-003 Phase A] 多声道：先把 M 声道下混成立体声，处理完再上混回 M。
     * ch<=2 时整段跳过，立体声路径与改造前逐字节一致。 */
    const int ch = h->channel_count.load(std::memory_order_relaxed);
    const bool multichannel = (ch > 2);
    h->last_block_ch = ch;   /* [Phase B] emit_viz 填 channel_count；与 ch_out_peak 同块同源 */

    /* [P2 静音门控] 非处理态（旁路/停止）一律直通，门控状态清零重来——
     * 旁路时若沿用 gated 会把用户音频吞成零。 */
    if (st != AURADSP_STATE_PROCESSING) {
        h->gate_active = false;
        h->gate_silent_frames = 0;
        h->gate_idle_frames = 0;
    }
    /* gated：整条效果链跳过，直出零。输入扫描是这里唯一的工作量，用于
     * 「信号回来当块退出」（无淡入）。 */
    if (h->gate_active) {
        float in_peak = 0.0f;
        const int n_in = frames * ch;
        for (int i = 0; i < n_in; ++i) {
            const float a = fabsf(in[i]);
            if (a > in_peak) in_peak = a;
        }
        if (in_peak > h->gate_peak_thresh) {
            h->gate_active = false;
            h->gate_silent_frames = 0;
            h->gate_idle_frames = 0;
        } else {
            memset(out, 0, (size_t)frames * (size_t)ch * sizeof(float));
            /* 上限封顶（与 gate_silent_frames 同口径）：48k 连续静音
             * 12.4 小时后 int 会溢出成 UB，仅为诊断字段。 */
            if (h->gate_idle_frames < (1 << 30)) h->gate_idle_frames += frames;
            h->input_lvl_in_l = h->input_lvl_in_r = -120.0f;
            h->input_lvl_out_l = h->input_lvl_out_r = -120.0f;
            for (int i = 0; i < AURADSP_STAGE_MAX; ++i) {
                h->stage_peak_l[i] = 0.0f;
                h->stage_peak_r[i] = 0.0f;
                for (int c = 0; c < AURADSP_CH_MAX; ++c)
                    h->stage_peak_ch[i][c] = 0.0f;
            }
            for (int i = 0; i < AURADSP_VENDOR_STAGES; ++i) {
                h->jdsp.stagePeakL[i] = 0.0f;
                h->jdsp.stagePeakR[i] = 0.0f;
            }
            h->gr_limiter.store(0.0f, std::memory_order_relaxed);
            h->gr_comp.store(0.0f, std::memory_order_relaxed);
            h->gr_gate.store(0.0f, std::memory_order_relaxed);
            for (int i = 0; i < 3; ++i)
                h->gr_dyneq[i].store(0.0f, std::memory_order_relaxed);
            /* 频谱/EQ 输入历史同样写零：emit_viz 照常产出（UI 回落不冻结），
             * 且不会把 gated 前的最后一窗能量冻在频谱上。 */
            memset(h->shelf_scratch, 0, (size_t)frames * 2 * sizeof(float));
            viz_write(h, h->shelf_scratch, frames, 2);
            if (h->eq_in_hist) viz_write_eq_in(h, h->shelf_scratch, frames);
            h->frames_since_viz += frames;
            int vizIntG = h->viz_interval.load(std::memory_order_relaxed);
            if (vizIntG < 64) vizIntG = 480;
            if (h->frames_since_viz >= vizIntG) {
                h->frames_since_viz %= vizIntG;
                emit_viz(h);
            }
            return;
        }
    }

    /* [Input Gate: 顺序钉死在最前端] 全通道总输入增益 × 单通道平衡 */
    const float in_gain_db = h->p.input_gain.load(std::memory_order_relaxed);
    const float master_lin = (in_gain_db == 0.0f) ? 1.0f : powf(10.0f, in_gain_db * 0.05f);

    if (multichannel && h->mx_scratch) {
        if (st != AURADSP_STATE_PROCESSING) {
            /* 非处理态：直通但清洗非有限值（否则 NaN 会绕过全部 DSP 直达 DAC） */
            const int n = frames * ch;
            for (int i = 0; i < n; ++i)
                out[i] = std::isfinite(in[i]) ? in[i] : 0.0f;
            return;
        }
        /* 多声道输入门控处理：缩放写入 mx_scratch 并统计本级 IN / OUT 电平 */
        float pk_in_l = 0.0f, pk_in_r = 0.0f;
        float pk_out_l = 0.0f, pk_out_r = 0.0f;
        /* [Phase B 多声道电平] per-channel 输入峰值（增益前）→ stage 12 槽位，
         * 与 stereo 的 input_lvl_in 语义严格一致。 */
        float pk_in_ch[AURADSP_CH_MAX] = {};
        for (int i = 0; i < frames; ++i) {
            for (int c = 0; c < ch; ++c) {
                const float s_raw = in[i * ch + c];
                const float s_in = std::isfinite(s_raw) ? s_raw : 0.0f;
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
                if (c < AURADSP_CH_MAX && a_in > pk_in_ch[c]) pk_in_ch[c] = a_in;
            }
        }
        h->input_lvl_in_l = pk_in_l > 1e-6f ? 20.0f * log10f(pk_in_l) : -120.0f;
        h->input_lvl_in_r = pk_in_r > 1e-6f ? 20.0f * log10f(pk_in_r) : -120.0f;
        h->input_lvl_out_l = pk_out_l > 1e-6f ? 20.0f * log10f(pk_out_l) : -120.0f;
        h->input_lvl_out_r = pk_out_r > 1e-6f ? 20.0f * log10f(pk_out_r) : -120.0f;
        for (int c = 0; c < ch && c < AURADSP_CH_MAX; ++c) h->stage_peak_ch[12][c] = pk_in_ch[c];
        for (int c = ch; c < AURADSP_CH_MAX; ++c) h->stage_peak_ch[12][c] = 0.0f; /* 声道数下降时清陈旧槽 */

        const bool binaural =
            h->p.spatial_binaural.load(std::memory_order_relaxed) != 0 &&
            h->p.spatial_enable.load(std::memory_order_relaxed) != 0 &&
            h->channel_count.load(std::memory_order_relaxed) >= 4 &&
            h->mx_stereo && h->shelf_scratch;
        if (binaural) {
            /* B1：6/8ch → 双耳立体声，再复用完整立体声链；
             * 输出写回 FL/FR，其余声道置零（物理立体声端点取 FL/FR）。 */
            spatial_binaural_process(h, h->mx_scratch, h->mx_stereo, frames, ch);
            process_stereo_chain(h, h->mx_stereo, h->shelf_scratch, frames, true);
            for (int i = 0; i < frames; ++i) {
                out[i * ch + 0] = h->shelf_scratch[i * 2];
                out[i * ch + 1] = h->shelf_scratch[i * 2 + 1];
                for (int c = 2; c < ch; ++c) out[i * ch + c] = 0.0f;
            }
            h->frames_since_viz += frames;
            viz_write(h, h->shelf_scratch, frames, 2);
        } else {
            const int mode = h->p.channels_mode.load(std::memory_order_relaxed);
            if (mode == 1) {
                /* 模式 1: 离散多声道独立处理 (Phase B: Category A 独立单声道滤波 + Category B 声场保持) */
                process_multichannel_chain(h, h->mx_scratch, out, frames, ch);
                h->frames_since_viz += frames;
                viz_write(h, out, frames, ch);
            } else {
                /* 模式 0: 矩阵混音 (Phase A 修复版: 彻底解决左右环绕串扰与镜像颠倒) */
                if (!mx_downmix(h, h->mx_scratch, h->shelf_scratch, frames, ch) || !h->mx_stereo) {
                    memcpy(out, in, (size_t)frames * ch * sizeof(float));
                    return;
                }
                process_stereo_chain(h, h->shelf_scratch, h->mx_stereo, frames);
                mx_upmix(h, out, h->mx_stereo, frames, ch);
                h->frames_since_viz += frames;
                /* 频谱/历史取下混立体声（既存语义）；per-channel 电平则按
                 * mx_upmix 后真实写进设备的 out 实测——否则 [2..N-1] 恒 -120，
                 * 多声道默认路径上 6 根柱永久假死。 */
                viz_write(h, h->mx_stereo, frames, 2);
                viz_scan_out_peak(h, out, frames, ch);
            }
        }
        int vizInt = h->viz_interval.load(std::memory_order_relaxed);
        if (vizInt < 64) vizInt = 480;
        if (h->frames_since_viz >= vizInt) {
            h->frames_since_viz %= vizInt;
            emit_viz(h);
        }
        /* [P2 静音门控] 用本块实测输入/输出峰值推进门控（多声道取全通道）。 */
        {
            float pk_in_max = 0.0f, pk_out_max = 0.0f;
            for (int c = 0; c < ch && c < AURADSP_CH_MAX; ++c) {
                if (pk_in_ch[c] > pk_in_max) pk_in_max = pk_in_ch[c];
                if (h->ch_out_peak[c] > pk_out_max) pk_out_max = h->ch_out_peak[c];
            }
            gate_update(h, pk_in_max, pk_out_max, frames);
        }
        return;
    }

    if (st != AURADSP_STATE_PROCESSING) {
        const int n = frames * 2;
        for (int i = 0; i < n; ++i)
            out[i] = std::isfinite(in[i]) ? in[i] : 0.0f;
        return;
    }
    /* 立体声输入门控处理：写入 shelf_scratch 作为链前置工作区 */
    const float g0 = master_lin * h->p.input_ch_gain[0].load(std::memory_order_relaxed);
    const float g1 = master_lin * h->p.input_ch_gain[1].load(std::memory_order_relaxed);
    float pk_in_l = 0.0f, pk_in_r = 0.0f;
    float pk_out_l = 0.0f, pk_out_r = 0.0f;
    for (int i = 0; i < frames; ++i) {
        const float raw_l = in[i * 2];
        const float raw_r = in[i * 2 + 1];
        const float in_l = std::isfinite(raw_l) ? raw_l : 0.0f;
        const float in_r = std::isfinite(raw_r) ? raw_r : 0.0f;
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
    viz_write(h, out, frames, 2);
    int vizInt2 = h->viz_interval.load(std::memory_order_relaxed);
    if (vizInt2 < 64) vizInt2 = 480;
    if (h->frames_since_viz >= vizInt2) {
        h->frames_since_viz %= vizInt2;
        emit_viz(h);
    }
    gate_update(h,
                pk_in_l > pk_in_r ? pk_in_l : pk_in_r,
                h->ch_out_peak[0] > h->ch_out_peak[1] ? h->ch_out_peak[0]
                                                      : h->ch_out_peak[1],
                frames);
}

#include "engine_param_table.h"

auradsp_status auradsp_set_param(auradsp_handle h, const char* id,
                                 const void* value, uint32_t bytes) {
    if (!h || !id || !value) return AURADSP_E_PARAM;
    std::lock_guard<std::mutex> lk(h->ctrl_mutex);

    const EngineParamDesc* desc = find_param_desc(id);
    if (desc) {
        if (desc->custom_set) {
            return desc->custom_set(h, value, bytes);
        }
        if (desc->offset_in_p != kNoOffset) {
            if (bytes < 4) return AURADSP_E_PARAM;
            if (desc->type == ParamType::kBool) {
                const int32_t v = *(const int32_t*)value ? 1 : 0;
                auto* ptr = reinterpret_cast<std::atomic<int32_t>*>(
                    reinterpret_cast<char*>(&h->p) + desc->offset_in_p);
                ptr->store(v);
            } else if (desc->type == ParamType::kInt32) {
                int32_t v = *(const int32_t*)value;
                if (v < (int32_t)desc->min_val) v = (int32_t)desc->min_val;
                if (v > (int32_t)desc->max_val) v = (int32_t)desc->max_val;
                auto* ptr = reinterpret_cast<std::atomic<int32_t>*>(
                    reinterpret_cast<char*>(&h->p) + desc->offset_in_p);
                ptr->store(v);
            } else if (desc->type == ParamType::kFloat) {
                float v = *(const float*)value;
                /* NaN/Inf 必须拒绝：< / > 钳制对 NaN 全为 false，否则会原样
                 * 存入原子量，并沿 powf/反馈结构扩散；链尾卫士只能清输出，
                 * 无法清除已经污染的二阶节/延迟线/FDN 状态。 */
                if (!std::isfinite(v)) {
                    set_error(h, "param: rejected (NaN/Inf input)");
                    return AURADSP_E_PARAM;
                }
                if (v < desc->min_val) v = desc->min_val;
                if (v > desc->max_val) v = desc->max_val;
                auto* ptr = reinterpret_cast<std::atomic<float>*>(
                    reinterpret_cast<char*>(&h->p) + desc->offset_in_p);
                ptr->store(v);
            }
            if (desc->set_hook) {
                desc->set_hook(h);
            }
            return AURADSP_OK;
        }
    }

    return handle_indexed_param_set(h, id, value, bytes);
}

auradsp_status auradsp_get_param(auradsp_handle h, const char* id,
                                 void* out_value, uint32_t bytes) {
    if (!h || !id || !out_value) return AURADSP_E_PARAM;
    std::lock_guard<std::mutex> lk(h->ctrl_mutex);

    const EngineParamDesc* desc = find_param_desc(id);
    if (desc) {
        if (desc->custom_get) {
            return desc->custom_get(h, out_value, bytes);
        }
        if (desc->offset_in_p != kNoOffset) {
            if (bytes < 4) return AURADSP_E_PARAM;
            if (desc->type == ParamType::kBool || desc->type == ParamType::kInt32) {
                auto* ptr = reinterpret_cast<const std::atomic<int32_t>*>(
                    reinterpret_cast<const char*>(&h->p) + desc->offset_in_p);
                *(int32_t*)out_value = ptr->load();
                return AURADSP_OK;
            } else if (desc->type == ParamType::kFloat) {
                auto* ptr = reinterpret_cast<const std::atomic<float>*>(
                    reinterpret_cast<const char*>(&h->p) + desc->offset_in_p);
                *(float*)out_value = ptr->load();
                return AURADSP_OK;
            }
        }
    }

    return handle_indexed_param_get(h, id, out_value, bytes);
}

auradsp_state auradsp_get_state(auradsp_handle h) {
    return h ? (auradsp_state)h->state.load() : AURADSP_STATE_ERROR;
}

double auradsp_get_latency_ms(auradsp_handle h) {
    if (!h) return 0;
    /* E-03：jdsp.fs / enableASRC 由控制侧在 ASRC 重配时改写，读侧必须与
     * set_param 同锁才能避免形式上的数据竞争（块长已走原子快照）。 */
    std::lock_guard<std::mutex> lk(h->ctrl_mutex);
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

} /* extern "C" */
