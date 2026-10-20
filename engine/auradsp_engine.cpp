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

// Windows 7 兼容补丁：提供 CreateFile2 回退，避免 MSVC STL <filesystem> 静态依赖 Win8+ 的 CreateFile2 导致 Win7 LoadLibrary 127
extern "C" {
    typedef struct _CREATEFILE2_EXTENDED_PARAMETERS_SHIM {
        DWORD dwSize;
        DWORD dwFileAttributes;
        DWORD dwFileFlags;
        DWORD dwSecurityQosFlags;
        LPSECURITY_ATTRIBUTES lpSecurityAttributes;
        HANDLE hTemplateFile;
    } CREATEFILE2_EXTENDED_PARAMETERS_SHIM;

    static HANDLE WINAPI AuraFallback_CreateFile2(
        LPCWSTR lpFileName,
        DWORD dwDesiredAccess,
        DWORD dwShareMode,
        DWORD dwCreationDisposition,
        CREATEFILE2_EXTENDED_PARAMETERS_SHIM* pCreateExParams)
    {
        typedef HANDLE (WINAPI *PFN_CF2)(LPCWSTR, DWORD, DWORD, DWORD, void*);
        static PFN_CF2 s_real = (PFN_CF2)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "CreateFile2");
        if (s_real) {
            return s_real(lpFileName, dwDesiredAccess, dwShareMode, dwCreationDisposition, pCreateExParams);
        }
        DWORD dwFlagsAndAttributes = 0;
        DWORD dwSecurityFlags = 0;
        if (pCreateExParams && pCreateExParams->dwSize >= sizeof(CREATEFILE2_EXTENDED_PARAMETERS_SHIM)) {
            dwFlagsAndAttributes = pCreateExParams->dwFileAttributes | pCreateExParams->dwFileFlags;
            dwSecurityFlags = pCreateExParams->dwSecurityQosFlags;
        }
        return CreateFileW(lpFileName, dwDesiredAccess, dwShareMode,
                           pCreateExParams ? pCreateExParams->lpSecurityAttributes : NULL,
                           dwCreationDisposition, dwFlagsAndAttributes | dwSecurityFlags,
                           pCreateExParams ? pCreateExParams->hTemplateFile : NULL);
    }

    void* __imp_CreateFile2 = (void*)AuraFallback_CreateFile2;
}
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

    /* B5 后续：arbmag 逐声道池（句柄级，create 分配；失败不算致命——
     * pool 的空位在 process 侧永远直通，与 legacy 上游构造失败容忍一致）。 */
    arbmag_pool_alloc(h);

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
    fv_alloc(h->fvL, sample_rate, 0);
    fv_alloc(h->fvR, sample_rate, kFvStereoSpread);
    JamesDSPInitFxGains(&h->jdsp);
    shelf_recalc(h);
    filter_recalc(h);
    apply_params_locked(h);
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
    arbmag_pool_free(h);
    delete[] h->fft_scratch;
    delete[] h->hann;
    delete[] h->viz_hist; delete[] h->eq_in_hist;
    delete[] h->shelf_scratch;
    delete[] h->conv_scratch;
    delete[] h->mx_scratch;
    delete[] h->mx_stereo;
    delete[] h->haas_ring;
    delete[] h->plugin_buf_l;
    delete[] h->plugin_buf_r;
    free(h->lp_code);
    free(h->eq_curve);
    free(h->arbmag_string);
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
            /* 非处理态：直通但清洗非有限值（否则 NaN 会绕过全部 DSP 直达 DAC） */
            const int n = frames * ch;
            for (int i = 0; i < n; ++i)
                out[i] = std::isfinite(in[i]) ? in[i] : 0.0f;
            return;
        }
        /* 多声道输入门控处理：缩放写入 mx_scratch 并统计本级 IN / OUT 电平 */
        float pk_in_l = 0.0f, pk_in_r = 0.0f;
        float pk_out_l = 0.0f, pk_out_r = 0.0f;
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
            }
        }
        h->input_lvl_in_l = pk_in_l > 1e-6f ? 20.0f * log10f(pk_in_l) : -120.0f;
        h->input_lvl_in_r = pk_in_r > 1e-6f ? 20.0f * log10f(pk_in_r) : -120.0f;
        h->input_lvl_out_l = pk_out_l > 1e-6f ? 20.0f * log10f(pk_out_l) : -120.0f;
        h->input_lvl_out_r = pk_out_r > 1e-6f ? 20.0f * log10f(pk_out_r) : -120.0f;

        const bool binaural =
            h->p.spatial_binaural.load(std::memory_order_relaxed) != 0 &&
            h->p.spatial_enable.load(std::memory_order_relaxed) != 0 &&
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
            viz_write(h, h->shelf_scratch, frames);
        } else {
            const int mode = h->p.channels_mode.load(std::memory_order_relaxed);
            if (mode == 1) {
                /* 模式 1: 离散多声道独立处理 (Phase B: Category A 独立单声道滤波 + Category B 声场保持) */
                process_multichannel_chain(h, h->mx_scratch, out, frames, ch);
                h->frames_since_viz += frames;
                viz_write(h, out, frames);
            } else {
                /* 模式 0: 矩阵混音 (Phase A 修复版: 彻底解决左右环绕串扰与镜像颠倒) */
                if (!mx_downmix(h, h->mx_scratch, h->shelf_scratch, frames, ch) || !h->mx_stereo) {
                    memcpy(out, in, (size_t)frames * ch * sizeof(float));
                    return;
                }
                process_stereo_chain(h, h->shelf_scratch, h->mx_stereo, frames);
                mx_upmix(h, out, h->mx_stereo, frames, ch);
                h->frames_since_viz += frames;
                viz_write(h, h->mx_stereo, frames);
            }
        }
        const int vizInt = h->viz_interval.load(std::memory_order_relaxed);
        while (h->frames_since_viz >= vizInt) {
            h->frames_since_viz -= vizInt;
            emit_viz(h);
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
    viz_write(h, out, frames);
    const int vizInt2 = h->viz_interval.load(std::memory_order_relaxed);
    while (h->frames_since_viz >= vizInt2) {
        h->frames_since_viz -= vizInt2;
        emit_viz(h);
    }
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
    /* S-9 修复：json.length() 为 size_t，(int) 强转在 >2GB 时回绕成负、
     * 跳过截断分支后 memcpy 拿到超长长度即越界。改为 size_t 与
     * (size_t)max_len 比较（入口已保证 max_len>=2，减 1 不回绕）。 */
    if (json.length() >= (size_t)max_len) {
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
    if (json.length() >= (size_t)max_len) {
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
    if (json.length() >= (size_t)max_len) {
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
