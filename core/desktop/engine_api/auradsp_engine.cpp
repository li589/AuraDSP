/*
 * auradsp_engine.c — AuraDSP Engines 统一 C ABI 实现（Desktop v1）
 *
 * 包装 core/desktop/vendor-src/libjamesdsp（纯 C，原样未改，见 ORIGIN.md）。
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

#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <new>

#ifdef _WIN32
#include <windows.h> /* MultiByteToWideChar / _wfopen（审查修复 R-1） */
#endif

extern "C" {
#include "jdsp/jdsp_header.h"
#include "jdsp/Effects/eel2/fft.h"
}

/* vendor liveprogWrapper.c 的错误码转文案（未在头文件声明，全局符号） */
extern "C" const char* checkErrorCode(int errCode);
/* vendor 离线重采样（nseel-compiler.c 定义，无头文件声明） */
extern "C" void JamesDSPOfflineResampling(float const* in, float* out,
                                          size_t lenIn, size_t lenOut,
                                          int channels, double src_ratio);

/* IR 文件解码：dr_* 为 header-only；实现已由 vendor nseel-compiler.c 提供
 * （重复定义会 LNK2005），这里只引声明。 */
#include "jdsp/Effects/eel2/dr_wav.h"
#include "jdsp/Effects/eel2/dr_flac.h"

#define AURADSP_VERSION "1.1.0"
#define AURADSP_ABI 1

/* ---------------- SPSC 可视化环 ---------------- */
namespace {

constexpr int kVizRingCap = 64;   /* 2 的幂 */
/* 实数 FFT 点数：4096@48kHz → 11.7Hz/bin。
 * 曾用 1024（46.9Hz/bin）：20~50Hz 的前几个对数带连 1 个 bin 都分不到
 * （hi<=lo → 恒 0），表现为"低音区几根柱子永远不动"。 */
constexpr int kVizFftSize = 4096;
constexpr int kVizInterval = 480; /* 每 480 帧（10ms@48k）产出 1 帧 */

struct VizRing {
    auradsp_viz_frame slots[kVizRingCap];
    std::atomic<uint64_t> write_idx{0};
    std::atomic<uint64_t> read_idx{0};

    void push(const auradsp_viz_frame& f) {
        const uint64_t w = write_idx.load(std::memory_order_relaxed);
        /* 覆盖最旧帧（丢帧优于阻塞 RT 线程） */
        if (w - read_idx.load(std::memory_order_acquire) >= kVizRingCap)
            read_idx.store(w - kVizRingCap + 1, std::memory_order_release);
        slots[w & (kVizRingCap - 1)] = f;
        write_idx.store(w + 1, std::memory_order_release);
    }

    uint32_t read(auradsp_viz_frame* out, uint32_t max) {
        uint64_t r = read_idx.load(std::memory_order_relaxed);
        const uint64_t w = write_idx.load(std::memory_order_acquire);
        uint32_t n = 0;
        while (r < w && n < max) {
            out[n++] = slots[r & (kVizRingCap - 1)];
            ++r;
        }
        read_idx.store(r, std::memory_order_release);
        return n;
    }
};

/* 32 个对数频带的边界（Hz，20Hz ~ 20kHz） */
constexpr float kBandEdges[AURADSP_VIZ_BANDS + 1] = {
    20, 25, 31, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
    800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
    12500, 16000, 18000, 19000, 20000};

struct Params {
    std::atomic<int32_t>  bass_enable{0};
    std::atomic<float>    bass_gain{0.0f};      /* dB [0,15] */
    std::atomic<int32_t>  reverb_preset{-1};
    std::atomic<float>    stereo_mix{0.0f};     /* [0,1] */
    std::atomic<int32_t>  eq_enable{0};
    std::atomic<int32_t>  limiter_enable{0};
    std::atomic<float>    post_gain{0.0f};      /* dB [-15,15] */
    std::atomic<int32_t>  latency_mode{1};      /* 0=realtime 1=music 2=quality */
    std::atomic<int32_t>  channels_mode{0};     /* 0=stereo（Phase A，ADR-003） */
    /* Liveprog（EEL2 实时可编程 DSP；vendor 补丁 P-001 提供 slider1..8） */
    std::atomic<int32_t>  lp_enable{0};
    std::atomic<float>    lp_param[8];          /* slider1..8（C++20 值初始化 = 0） */
    /* 卷积 / 脉冲响应（v1.1 M4） */
    std::atomic<int32_t>  conv_enable{0};
    /* M3-a：轻量效果开关（真·重排序需 process 链补丁，后置 M3.5） */
    std::atomic<int32_t>  tube_enable{0};       /* T0 */
    std::atomic<int32_t>  xfeed_enable{0};      /* T1 ≈3ms */
    /* M5/P-002：声场分带（bandMixUsed 由宿主语义维护） */
    std::atomic<float>    stereo_band[5];
    std::atomic<int32_t>  stereo_band_used{0};
    /* M5-b：低频搁架（low-shelf，自研 RBJ biquad，零 vendor 改动） */
    std::atomic<int32_t>  shelf_enable{0};
    std::atomic<float>    shelf_freq{100.0f};   /* Hz [40,400] */
    std::atomic<float>    shelf_gain{0.0f};     /* dB [-15,15] */
};

/* 效果延迟档位（0=T0 1=T1 2=T2）与近似附加延迟 ms（ADR-002 表） */
struct LatencyItem { int tier; float ms; };
constexpr LatencyItem kLatReverb   {2, 30.0f};
constexpr LatencyItem kLatComp     {2, 85.0f};  /* FFTCompander FFTSIZE_DRS/2 */
constexpr LatencyItem kLatConvolver{2, 10.0f};  /* 保守下限，IR 长度另计 */
constexpr LatencyItem kLatCrossfeed{1, 3.0f};
constexpr LatencyItem kLatDdc      {1, 6.0f};
constexpr LatencyItem kLatLimiter  {0, 2.0f};

/* 每档预算上限 ms */
constexpr float kTierBudget[3] = {10.0f, 30.0f, 1e9f};

}  // namespace

struct auradsp_handle_s {
    JamesDSPLib jdsp;
    Params p;
    VizRing viz;
    std::mutex ctrl_mutex;            /* 仅保护 init/teardown/参数应用，不进 process */
    std::atomic<int> state{AURADSP_STATE_BYPASS};
    std::atomic<bool> open{false};
    float sample_rate = 48000.0f;
    int max_block = 2048;
    double latency_ms = 0.0;

    /* 频谱工作区（RT 线程专用，create 时分配） */
    float* fft_scratch = nullptr;     /* kVizFftSize floats */
    float  hann[kVizFftSize];
    float* viz_hist = nullptr;        /* kVizFftSize*2，L/R 交织环形历史窗 */
    int    viz_hist_pos = 0;          /* 下一个写入帧位（亦指向窗内最旧帧） */
    int    frames_since_viz = 0;
    uint64_t viz_seq = 0;
    float  viz_lvl_l = -120.0f;       /* 最近块峰值 dBFS（viz_write 记录） */
    float  viz_lvl_r = -120.0f;

    /* Liveprog 状态 */
    float* lp_slider_ptr[8] = {};     /* slider1..8 的 VM 寄存器指针（代码加载后刷新） */
    int    lp_status = 0;             /* 0=无代码 1=编译成功 <0=LiveProgStringParser 错误码 */
    char*  lp_code = nullptr;         /* 已下发代码副本（get_param 回读用） */
    size_t lp_code_len = 0;

    /* 卷积 IR 元数据（load 成功后填充；门卫见 load_ir_file） */
    std::atomic<bool>     ir_ready{false};
    std::atomic<int32_t>  ir_frames{0};        /* 引擎采样率下的帧数（重采样后） */
    std::atomic<int32_t>  ir_channels{0};
    std::atomic<int32_t>  ir_src_rate{0};      /* 文件原始采样率（0=无） */
    std::atomic<float>    ir_peak{0.0f};       /* 线性峰值（归一化提示用） */

    /* M5-b：低频搁架 biquad（系数原子写防撕裂；状态仅 RT 线程触碰） */
    struct ShelfBiquad {
        std::atomic<double> b0{1}, b1{0}, b2{0}, a1{0}, a2{1};
        double z1L = 0, z2L = 0, z1R = 0, z2R = 0;   /* TDF2 状态（RT 独占） */
    } shelf;
    float* shelf_scratch = nullptr;   /* max_block*2，vendor 链前置处理用 */

    char   last_error[256] = {0};
};

namespace {

/* 进程级全局初始化（NSEEL JIT 运行时），引用计数（对齐 Android 侧做法） */
std::mutex g_global_mutex;
int g_global_ref = 0;

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

void set_error(auradsp_handle h, const char* msg) {
    if (h) { snprintf(h->last_error, sizeof(h->last_error), "%s", msg); }
}

/* 计算当前启用组合的附加延迟（ms）；超档时返回 false */
bool compute_latency(auradsp_handle h, double* out_ms, bool* over_guard) {
    double ms = 0.0;
    if (h->p.limiter_enable.load(std::memory_order_relaxed)) ms += kLatLimiter.ms;
    if (h->p.reverb_preset.load(std::memory_order_relaxed) >= 0) {
        ms += kLatReverb.ms;
        if (h->p.latency_mode.load(std::memory_order_relaxed) < 2) *over_guard = true;
    }
    /* 卷积 = T2（ADR-002）：IR 已加载且使能时计入 */
    if (h->p.conv_enable.load(std::memory_order_relaxed) &&
        h->ir_ready.load(std::memory_order_relaxed)) {
        ms += kLatConvolver.ms;
        if (h->p.latency_mode.load(std::memory_order_relaxed) < 2) *over_guard = true;
    }
    /* 串扰消除 = T1 ≈3ms（实时档 10ms 预算内，交由总预算判断） */
    if (h->p.xfeed_enable.load(std::memory_order_relaxed)) ms += kLatCrossfeed.ms;
    if (h->p.latency_mode.load(std::memory_order_relaxed) < 2) {
        /* compressor/convolver/arbMag 未在本 ABI v1 暴露参数，预留守卫位 */
    }
    if (ms > kTierBudget[h->p.latency_mode.load(std::memory_order_relaxed)]) *over_guard = true;
    *out_ms = ms;
    return !*over_guard;
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
    if (sm > 0.0f) {
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

void apply_liveprog(auradsp_handle h) {
    if (h->p.lp_enable.load(std::memory_order_relaxed))
        LiveProgEnable(&h->jdsp);
    else
        LiveProgDisable(&h->jdsp);
}

/* ---- M5-b 低频搁架（RBJ cookbook low-shelf，Q=0.707）----
 * RT 路径：DF2T 双声道，系数原子读；控制线程重算系数。 */
void shelf_recalc(auradsp_handle h) {
    const double f0 = h->p.shelf_freq.load(std::memory_order_relaxed);
    const double gdb = h->p.shelf_gain.load(std::memory_order_relaxed);
    const double A = pow(10.0, gdb / 40.0);
    const double w0 = 2.0 * 3.14159265358979 * f0 / h->jdsp.fs;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / (2.0 * 0.7071067811865476);
    const double sqA2a = 2.0 * sqrt(A) * alpha;
    const double b0 = A * ((A + 1) - (A - 1) * cw + sqA2a);
    const double b1 = 2.0 * A * ((A - 1) - (A + 1) * cw);
    const double b2 = A * ((A + 1) - (A - 1) * cw - sqA2a);
    const double a0 = (A + 1) + (A - 1) * cw + sqA2a;
    const double a1 = -2.0 * ((A - 1) + (A + 1) * cw);
    const double a2 = (A + 1) + (A - 1) * cw - sqA2a;
    h->shelf.b0.store(b0 / a0, std::memory_order_release);
    h->shelf.b1.store(b1 / a0, std::memory_order_release);
    h->shelf.b2.store(b2 / a0, std::memory_order_release);
    h->shelf.a1.store(a1 / a0, std::memory_order_release);
    h->shelf.a2.store(a2 / a0, std::memory_order_release);
}

void shelf_process(auradsp_handle h, float* io, int frames) {
    const double b0 = h->shelf.b0.load(std::memory_order_acquire);
    const double b1 = h->shelf.b1.load(std::memory_order_acquire);
    const double b2 = h->shelf.b2.load(std::memory_order_acquire);
    const double a1 = h->shelf.a1.load(std::memory_order_acquire);
    const double a2 = h->shelf.a2.load(std::memory_order_acquire);
    double z1L = h->shelf.z1L, z2L = h->shelf.z2L;
    double z1R = h->shelf.z1R, z2R = h->shelf.z2R;
    for (int i = 0; i < frames; ++i) {
        const double xl = io[i * 2], xr = io[i * 2 + 1];
        const double yl = b0 * xl + z1L;
        z1L = b1 * xl - a1 * yl + z2L;
        z2L = b2 * xl - a2 * yl;
        const double yr = b0 * xr + z1R;
        z1R = b1 * xr - a1 * yr + z2R;
        z2R = b2 * xr - a2 * yr;
        io[i * 2] = (float)yl;
        io[i * 2 + 1] = (float)yr;
    }
    h->shelf.z1L = z1L; h->shelf.z2L = z2L;
    h->shelf.z1R = z1R; h->shelf.z2R = z2R;
}

void apply_tube(auradsp_handle h) {
    if (h->p.tube_enable.load(std::memory_order_relaxed))
        VacuumTubeEnable(&h->jdsp);
    else
        VacuumTubeDisable(&h->jdsp);
}

void apply_crossfeed(auradsp_handle h) {
    /* vendor lazy-build：enable 时用内置 HRTF blobs 建卷积（首次有一次性开销） */
    CrossfeedEnable(&h->jdsp,
                    h->p.xfeed_enable.load(std::memory_order_relaxed) ? 1 : 0);
}

void apply_convolver(auradsp_handle h) {
    if (h->p.conv_enable.load(std::memory_order_relaxed) &&
        h->ir_ready.load(std::memory_order_relaxed))
        Convolver1DEnable(&h->jdsp);
    else
        Convolver1DDisable(&h->jdsp);
}

/* ---- IR 文件加载 + 统一文件门卫（M4，规划 §5.2）----
 * 防线：L1 magic 嗅探（不信任扩展名）→ L2 尺寸限额 → L3 本函数在控制线程
 * （调用方不持锁，解码失败不连坐音频）→ L4 解码后健全性（NaN/Inf/声道/长度）。
 * 采样率不匹配 → JamesDSPOfflineResampling 重采样到引擎 fs（44.1↔48 等）。
 * 成功 → Convolver1DLoadImpulseResponse(updateOld=1) 持久化到 vendor 存储。 */
auradsp_status load_ir_file(auradsp_handle h, const char* path) {
    /* L2：路径与文件尺寸限额 */
    if (!path || !path[0]) { set_error(h, "convolver.ir.path: empty path"); return AURADSP_E_PARAM; }
    /* 审查修复 R-1：Windows fopen 走 ANSI 代码页，中文路径必挂——
     * UTF-8 → UTF-16 后走 _wfopen */
#ifdef _WIN32
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
    if (wlen <= 0) { set_error(h, "convolver.ir.path: invalid encoding"); return AURADSP_E_PARAM; }
    wchar_t* wpath = (wchar_t*)malloc((size_t)wlen * sizeof(wchar_t));
    if (!wpath) { set_error(h, "convolver.ir.path: OOM"); return AURADSP_E_IO; }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, wlen);
    FILE* fp = _wfopen(wpath, L"rb");
    free(wpath);
#else
    FILE* fp = fopen(path, "rb");
#endif
    if (!fp) { set_error(h, "convolver.ir: cannot open file"); return AURADSP_E_IO; }
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); set_error(h, "convolver.ir: seek failed"); return AURADSP_E_IO; }
    const long fsize = ftell(fp);
    if (fsize <= 44) { fclose(fp); set_error(h, "convolver.ir: file too small"); return AURADSP_E_PARAM; }
    if (fsize > 256 * 1024 * 1024) {
        fclose(fp);
        set_error(h, "convolver.ir: file too large (max 256MiB)");
        return AURADSP_E_PARAM;
    }
    rewind(fp);
    unsigned char* bytes = (unsigned char*)malloc((size_t)fsize);
    if (!bytes) { fclose(fp); set_error(h, "convolver.ir: OOM"); return AURADSP_E_IO; }
    const size_t got = fread(bytes, 1, (size_t)fsize, fp);
    fclose(fp);
    if (got != (size_t)fsize) { free(bytes); set_error(h, "convolver.ir: read failed"); return AURADSP_E_IO; }

    /* L1：magic 嗅探（RIFF..WAVE / fLaC；不信任扩展名） */
    const unsigned char* b = bytes;
    const bool is_wav = fsize > 12 && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F'
                        && b[8] == 'W' && b[9] == 'A' && b[10] == 'V' && b[11] == 'E';
    const bool is_flac = fsize > 4 && b[0] == 'f' && b[1] == 'L' && b[2] == 'a' && b[3] == 'C';
    unsigned int ch = 0, src_rate = 0;
    size_t frames = 0;
    float* data = nullptr;
    if (is_wav) {
        drwav wav;
        if (!drwav_init_memory(&wav, bytes, (size_t)fsize, nullptr)) {
            free(bytes); set_error(h, "convolver.ir: WAV header corrupt"); return AURADSP_E_PARAM;
        }
        ch = wav.channels; src_rate = (unsigned int)wav.sampleRate; frames = (size_t)wav.totalPCMFrameCount;
        if (ch < 1 || ch > 8 || frames == 0) {
            drwav_uninit(&wav); free(bytes);
            set_error(h, "convolver.ir: invalid WAV channels/frames");
            return AURADSP_E_PARAM;
        }
        /* 审查修复 R-2：总样本量上限（16M 帧 × 8ch 会要 512MB 分配） */
        if (frames > 16u * 1024 * 1024 || (unsigned long long)frames * ch > 64ull * 1024 * 1024) {
            drwav_uninit(&wav); free(bytes);
            set_error(h, "convolver.ir: too long (max 16M frames / 64M samples)");
            return AURADSP_E_PARAM;
        }
        data = (float*)malloc(frames * ch * sizeof(float));
        if (!data) { drwav_uninit(&wav); free(bytes); set_error(h, "convolver.ir: OOM"); return AURADSP_E_IO; }
        const drwav_uint64 rd = drwav_read_pcm_frames_f32(&wav, frames, data);
        drwav_uninit(&wav);
        if (rd != frames) { free(data); free(bytes); set_error(h, "convolver.ir: WAV truncated"); return AURADSP_E_PARAM; }
    } else if (is_flac) {
        drflac* flac = drflac_open_memory(bytes, (size_t)fsize, nullptr);
        if (!flac) { free(bytes); set_error(h, "convolver.ir: FLAC corrupt"); return AURADSP_E_PARAM; }
        ch = flac->channels; src_rate = (unsigned int)flac->sampleRate; frames = (size_t)flac->totalPCMFrameCount;
        if (ch < 1 || ch > 8 || frames == 0 ||
            frames > 16u * 1024 * 1024 ||
            (unsigned long long)frames * ch > 64ull * 1024 * 1024) {
            drflac_close(flac); free(bytes);
            set_error(h, "convolver.ir: invalid FLAC channels/frames/length");
            return AURADSP_E_PARAM;
        }
        data = (float*)malloc(frames * ch * sizeof(float));
        if (!data) { drflac_close(flac); free(bytes); set_error(h, "convolver.ir: OOM"); return AURADSP_E_IO; }
        const drflac_uint64 rd = drflac_read_pcm_frames_f32(flac, frames, data);
        drflac_close(flac);
        if (rd != frames) { free(data); free(bytes); set_error(h, "convolver.ir: FLAC truncated"); return AURADSP_E_PARAM; }
    } else {
        free(bytes);
        set_error(h, "convolver.ir: unknown format (need WAV/FLAC)");
        return AURADSP_E_PARAM;
    }
    free(bytes);

    /* L4：健全性扫描（NaN/Inf 会毒化卷积输出） */
    const size_t n = frames * ch;
    float peak = 0.0f;
    for (size_t i = 0; i < n; ++i) {
        const float v = data[i];
        if (isnan(v) || isinf(v)) {
            free(data);
            set_error(h, "convolver.ir: NaN/Inf samples in file");
            return AURADSP_E_PARAM;
        }
        const float a = fabsf(v);
        if (a > peak) peak = a;
    }
    if (peak == 0.0f) {
        free(data);
        set_error(h, "convolver.ir: all-silent IR");
        return AURADSP_E_PARAM;
    }

    /* 采样率不匹配 → 离线重采样到引擎 fs（诚实回读 src_rate 供 UI 提示） */
    size_t out_frames = frames;
    float* proc = data;
    if (src_rate != 0 && fabs((double)src_rate - h->jdsp.fs) > 0.5) {
        const double ratio = (double)h->jdsp.fs / (double)src_rate;
        out_frames = (size_t)ceil((double)frames * ratio);
        float* res = (float*)malloc(out_frames * ch * sizeof(float));
        if (!res) { free(data); set_error(h, "convolver.ir: OOM (resample)"); return AURADSP_E_IO; }
        memset(res, 0, out_frames * ch * sizeof(float));
        JamesDSPOfflineResampling(data, res, frames, out_frames, (int)ch, ratio);
        free(data);
        proc = res;
    }

    /* 交给 vendor：updateOld=1 → 存入 impulseResponseStorage（fs 变化可重建） */
    const int rc = Convolver1DLoadImpulseResponse(&h->jdsp, proc, ch, out_frames, 1);
    free(proc);
    if (rc != 1) {
        set_error(h, "convolver.ir: vendor load failed (partition select?)");
        return AURADSP_E_STATE;
    }
    h->ir_ready.store(true);
    h->ir_frames.store((int32_t)out_frames);
    h->ir_channels.store((int32_t)ch);
    h->ir_src_rate.store((int32_t)src_rate);
    h->ir_peak.store(peak);
    return AURADSP_OK;
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

/* 频谱历史写入（RT 线程，每个 process 块都必须调用！）。
 *
 * 教训：旧实现把"写历史"放在 emit_viz 里，而 emit_viz 只每 kVizInterval 帧触发
 * 一次 → 两次发射之间的音频块从未进窗，环形历史是"每两块丢一块"的梳状采样
 * 信号（= 信号 × 50% 占空比方波），频谱全是混叠假峰。这就是"低音区几根柱子
 * 不显示 / 频段间距怪"的真正根因（自 1024-FFT 版本起就存在）。
 */
void viz_write(auradsp_handle h, const float* out, int frames) {
    const int mask = kVizFftSize - 1;
    for (int i = 0; i < frames; ++i) {
        h->viz_hist[h->viz_hist_pos * 2]     = out[i * 2];
        h->viz_hist[h->viz_hist_pos * 2 + 1] = out[i * 2 + 1];
        h->viz_hist_pos = (h->viz_hist_pos + 1) & mask;
    }
    /* 记录本块峰值电平，供 emit_viz 使用 */
    float lvl_l = 0.0f, lvl_r = 0.0f;
    for (int i = 0; i < frames; ++i) {
        const float a = fabsf(out[i * 2]), b = fabsf(out[i * 2 + 1]);
        if (a > lvl_l) lvl_l = a;
        if (b > lvl_r) lvl_r = b;
    }
    h->viz_lvl_l = lvl_l > 1e-6f ? 20.0f * log10f(lvl_l) : -120.0f;
    h->viz_lvl_r = lvl_r > 1e-6f ? 20.0f * log10f(lvl_r) : -120.0f;
}

/* 频谱帧产出（RT 线程；只做 FFT + 带划分 + push，历史写入已由 viz_write 完成）。
 *
 * 关键：调用方块长可变（WASAPI 共享模式轮询下常见 200~1100 帧），
 * 绝不能要求单块 >= kVizFftSize，否则只有首个大块产出一次、之后永久静止。
 * 因此维护 kVizFftSize 帧的 L/R 环形历史窗（create 预分配，无 RT 分配），
 * 每次对"最近 kVizFftSize 帧"做汉宁窗实数 FFT。
 */
void emit_viz(auradsp_handle h) {
    const int kN = kVizFftSize;
    const int mask = kN - 1;

    /* 1) 按时间序提取整窗 + 汉宁窗（L 声道） */
    float* buf = h->fft_scratch;
    for (int i = 0; i < kN; ++i) {
        const int idx = (h->viz_hist_pos + i) & mask;   /* pos 即最旧帧 */
        buf[i] = h->viz_hist[idx * 2] * h->hann[i];
    }
    /* DC/次声泄漏抑制：去掉窗内均值再 FFT。直流或块状不连续信号会把能量
     * 泄进最低频带（汉宁窗旁瓣），表现为"低音区第一根柱子常亮"。 */
    double wmean = 0.0;
    for (int i = 0; i < kN; ++i) wmean += buf[i];
    wmean /= kN;
    for (int i = 0; i < kN; ++i) buf[i] -= (float)wmean;
    WDL_real_fft(buf, kN, 0);

    /* WDL 实 FFT：输出 kN/2 个复数，按 WDL_fft_permute(kN/2) 顺序存放 */
    const int half = kN / 2;
    const int nmag = half < 2048 ? half : 2048;
    const int32_t* perm = WDL_fft_permute_tab(half);
    float mag[2048];
    for (int i = 0; i < nmag; ++i) {
        const int pi = perm ? perm[i] : i;
        const float re = buf[pi * 2];
        const float im = buf[pi * 2 + 1];
        mag[i] = sqrtf(re * re + im * im);
    }
    const float bin_hz = h->sample_rate / (float)kN;

    auradsp_viz_frame f;
    memset(&f, 0, sizeof(f));
    f.seq = ++h->viz_seq;
    f.timestamp_ms = f.seq * (kVizInterval * 1000.0 / h->sample_rate);

    /* 3) 峰值电平（最近块，dBFS；由 viz_write 记录） */
    f.level_l_dbfs = h->viz_lvl_l;
    f.level_r_dbfs = h->viz_lvl_r;

    /* 4) 32 对数带：幅度归一（汉宁相干增益 0.5 × 单边 2）→ dBFS → [0,1] */
    const float amp_scale = 4.0f / (float)kN;
    for (int b = 0; b < AURADSP_VIZ_BANDS; ++b) {
        const int lo = (int)(kBandEdges[b] / bin_hz);
        const int hi = (int)(kBandEdges[b + 1] / bin_hz);
        if (hi <= lo || lo >= nmag) { f.spectrum[b] = 0; continue; }
        const int hb = hi > nmag ? nmag : hi;
        float m = 0;
        for (int i = lo; i < hb; ++i) if (mag[i] > m) m = mag[i];
        const float amp = m * amp_scale;
        /* -60..0 dBFS → 0..1（低于 -60 视为静音） */
        float v = 0.0f;
        if (amp > 1e-5f) v = (20.0f * log10f(amp) + 60.0f) * (1.0f / 60.0f);
        f.spectrum[b] = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    }
    h->viz.push(f);
}

}  // namespace

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
    h->fft_scratch = new (std::nothrow) float[kVizFftSize];
    if (!h->fft_scratch) { delete h; return nullptr; }
    h->viz_hist = new (std::nothrow) float[kVizFftSize * 2]();
    if (!h->viz_hist) { delete[] h->fft_scratch; delete h; return nullptr; }
    h->shelf_scratch = new (std::nothrow) float[(size_t)max_block_frames * 2]();
    if (!h->shelf_scratch) {
        delete[] h->fft_scratch; delete[] h->viz_hist; delete h; return nullptr;
    }
    for (int i = 0; i < kVizFftSize; ++i)
        h->hann[i] = 0.5f * (1.0f - cosf(2.0f * 3.14159265358979f * i / (kVizFftSize - 1)));

    std::lock_guard<std::mutex> lk(h->ctrl_mutex);
    JamesDSPInit(&h->jdsp, max_block_frames, sample_rate);
    shelf_recalc(h);
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
    delete[] h->fft_scratch;
    delete[] h->viz_hist;
    delete[] h->shelf_scratch;
    free(h->lp_code);
    delete h;
    global_unref();
}

void auradsp_process(auradsp_handle h, const float* in, float* out, int frames) {
    if (!h || !h->open.load(std::memory_order_acquire) || frames <= 0) return;
    const int st = h->state.load(std::memory_order_relaxed);
    if (st != AURADSP_STATE_PROCESSING) {
        if (out != in) memcpy(out, in, (size_t)frames * 2 * sizeof(float));
        return;
    }
    /* libjamesdsp 稳态无分配；块超限时内部自动重分配（pfloat32Multiplexed） */
    if (h->p.shelf_enable.load(std::memory_order_relaxed) &&
        h->p.shelf_gain.load(std::memory_order_relaxed) != 0.0f) {
        /* M5-b：低频搁架在 vendor 链前（链头效果；scratch 复用 in 原位不可写） */
        memcpy(h->shelf_scratch, in, (size_t)frames * 2 * sizeof(float));
        shelf_process(h, h->shelf_scratch, frames);
        h->jdsp.processFloatMultiplexd(&h->jdsp, h->shelf_scratch, out, (size_t)frames);
    } else {
        h->jdsp.processFloatMultiplexd(&h->jdsp, const_cast<float*>(in), out, (size_t)frames);
    }

    /* 可视化：每块写入历史窗（无条件），每 kVizInterval 帧产出一次；
     * 失败不影响音频路径 */
    h->frames_since_viz += frames;
    viz_write(h, out, frames);
    if (h->frames_since_viz >= kVizInterval) {
        h->frames_since_viz = 0;
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
        const int32_t saved = h->p.reverb_preset.load(std::memory_order_relaxed);
        double ms = 0.0; bool over = false;
        if (v != saved) {
            h->p.reverb_preset.store(v);
            compute_latency(h, &ms, &over);
            /* ADR-002 守卫：T2 效果禁止在实时/音乐档启用（UI 应置灰，此处兜底） */
            if (v >= 0 && over) {
                h->p.reverb_preset.store(saved);
                set_error(h, "latency guard: reverb is T2, switch to quality mode first");
                return AURADSP_E_LATENCY_GUARD;
            }
        }
        if (h->open.load()) apply_reverb(h);   /* 只动混响链 */
        compute_latency(h, &ms, &over);        /* 刷新延迟读数（开启/关闭都回落正确） */
        h->latency_ms = ms;
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
    if (!strcmp(id, "mode.latency") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value;
        if (v < 0 || v > 2) return AURADSP_E_PARAM;
        const int32_t old = h->p.latency_mode.exchange(v);
        double ms; bool over = false;
        if (!compute_latency(h, &ms, &over)) {
            /* 组合超档：回滚（UI 需先关闭 T2 效果再切档） */
            h->p.latency_mode.store(old);
            set_error(h, "latency guard: disable T2 effects (reverb) before switching");
            return AURADSP_E_LATENCY_GUARD;
        }
        h->latency_ms = ms;
        return AURADSP_OK;
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
            set_error(h, "convolver.enable: no IR loaded");
            return AURADSP_E_STATE;
        }
        const int32_t old = h->p.conv_enable.exchange(v);
        double ms = 0.0; bool over = false;
        if (v && !compute_latency(h, &ms, &over)) {
            /* ADR-002：卷积是 T2，实时/音乐档拒绝 */
            h->p.conv_enable.store(old);
            set_error(h, "latency guard: convolver is T2, switch to quality mode first");
            return AURADSP_E_LATENCY_GUARD;
        }
        if (h->open.load()) apply_convolver(h);
        compute_latency(h, &ms, &over);
        h->latency_ms = ms;
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
    if (!strcmp(id, "convolver.clear") && bytes >= 4) {
        h->p.conv_enable.store(0);
        h->ir_ready.store(false);
        h->ir_frames.store(0);
        h->ir_channels.store(0);
        h->ir_src_rate.store(0);
        h->ir_peak.store(0.0f);
        if (h->open.load()) apply_convolver(h);
        return AURADSP_OK;
    }
    /* ---- M3-a：轻量效果开关 ---- */
    if (!strcmp(id, "tube.enable") && bytes >= 4) {
        h->p.tube_enable.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_tube(h);   /* T0，无守卫 */
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
    if (!strcmp(id, "crossfeed.enable") && bytes >= 4) {
        h->p.xfeed_enable.store(*(const int32_t*)value ? 1 : 0);
        if (h->open.load()) apply_crossfeed(h);
        double ms; bool over;
        compute_latency(h, &ms, &over);   /* T1：超实时档总预算时 UI 会看到延迟徽标变色 */
        h->latency_ms = ms;
        return AURADSP_OK;
    }
    set_error(h, "unknown param id");
    return AURADSP_E_PARAM;
}

auradsp_status auradsp_get_param(auradsp_handle h, const char* id,
                                 void* out_value, uint32_t bytes) {
    if (!h || !id || !out_value) return AURADSP_E_PARAM;
    if (!strcmp(id, "bass.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.bass_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "bass.gain") && bytes >= 4) { *(float*)out_value = h->p.bass_gain.load(); return AURADSP_OK; }
    if (!strcmp(id, "reverb.preset") && bytes >= 4) { *(int32_t*)out_value = h->p.reverb_preset.load(); return AURADSP_OK; }
    if (!strcmp(id, "stereo.mix") && bytes >= 4) { *(float*)out_value = h->p.stereo_mix.load(); return AURADSP_OK; }
    if (!strncmp(id, "stereo.band", 11) && bytes >= 4) {
        const char d = id[11];
        if (d < '1' || d > '5' || id[12] != 0) return AURADSP_E_PARAM;
        *(float*)out_value = h->p.stereo_band[d - '1'].load();
        return AURADSP_OK;
    }
    if (!strcmp(id, "stereo.bandUsed") && bytes >= 4) { *(int32_t*)out_value = h->p.stereo_band_used.load(); return AURADSP_OK; }
    if (!strcmp(id, "eq.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.eq_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "limiter.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.limiter_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "post.gain") && bytes >= 4) { *(float*)out_value = h->p.post_gain.load(); return AURADSP_OK; }
    if (!strcmp(id, "mode.latency") && bytes >= 4) { *(int32_t*)out_value = h->p.latency_mode.load(); return AURADSP_OK; }
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
    if (!strcmp(id, "tube.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.tube_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "crossfeed.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.xfeed_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "shelf.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.shelf_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "shelf.freq") && bytes >= 4) { *(float*)out_value = h->p.shelf_freq.load(); return AURADSP_OK; }
    if (!strcmp(id, "shelf.gain") && bytes >= 4) { *(float*)out_value = h->p.shelf_gain.load(); return AURADSP_OK; }
    /* graph.effects：M3 链视图注册表（固定 vendor 顺序；exposed=参数通道已开放） */
    if (!strcmp(id, "graph.effects") && bytes >= 1024) {
        /* 14 项注册表：id / 延迟档 / 参数通道是否开放（exposed=false 的节点
         * 在链视图里展示为"参数开放中"占位） */
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
            "{\"id\":\"comp\",\"tier\":2,\"exposed\":false},"
            "{\"id\":\"arbmag\",\"tier\":2,\"exposed\":false},"
            "{\"id\":\"ddc\",\"tier\":1,\"exposed\":false},"
            "{\"id\":\"vdc\",\"tier\":0,\"exposed\":false}"
            "]";
        snprintf((char*)out_value, bytes, "%s", reg);
        return AURADSP_OK;
        return AURADSP_OK;
    }
    return AURADSP_E_PARAM;
}

auradsp_state auradsp_get_state(auradsp_handle h) {
    return h ? (auradsp_state)h->state.load() : AURADSP_STATE_ERROR;
}

double auradsp_get_latency_ms(auradsp_handle h) {
    if (!h) return 0;
    double ms; bool over = false;
    compute_latency(h, &ms, &over);
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
