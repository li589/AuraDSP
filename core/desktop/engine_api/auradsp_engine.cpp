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

struct ScopedFtzDazGuard {
#if defined(_M_X64) || defined(__x86_64__)
    unsigned int oldCsr;
    ScopedFtzDazGuard() : oldCsr(_mm_getcsr()) {
        _mm_setcsr(oldCsr | 0x8040); // FTZ (bit 15) | DAZ (bit 6)
    }
    ~ScopedFtzDazGuard() {
        _mm_setcsr(oldCsr);
    }
#else
    ScopedFtzDazGuard() = default;
    ~ScopedFtzDazGuard() = default;
#endif
};

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
/* 频谱工作区（RT 线程专用，create 时按 kVizFftMax 一次性分配到最大，
 * 运行时只改 viz_fft_size 这个使用长度 —— 这样 viz.fftSize 参数随时可下发，
 * 不需要在控制线程重分配缓冲区（那会与 RT 线程的 emit_viz 竞争）。 */
/* [ADR-003] 多声道矩阵支持的最大声道数 */
constexpr int kMxMaxChannels = 8;

constexpr int kVizFftMax = 8192;   /* 2 的幂；缓冲区按此上限一次性分配 */
/* 默认使用长度。11.7Hz/bin @48k：20~50Hz 的前几个对数带才分得到 bin。
 * 曾用 1024（46.9Hz/bin），表现为"低音区几根柱子永远不动"。
 * 可由参数 viz.fftSize 在 [1024, kVizFftMax] 内调整（不重分配缓冲区）。 */
constexpr int kVizFftDefault = 4096;

struct VizRing {
    auradsp_viz_frame slots[kVizRingCap];
    std::atomic<uint64_t> write_idx{0};
    std::atomic<uint64_t> read_idx{0};

    void push(const auradsp_viz_frame& f) {
        const uint64_t w = write_idx.load(std::memory_order_relaxed);
        const uint64_t r = read_idx.load(std::memory_order_acquire);
        /* 标准 SPSC 契约：写者绝不写 read_idx，环满时安全丢弃新帧防数据竞争 */
        if (w - r >= (uint64_t)kVizRingCap)
            return;
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
    std::atomic<float>    conv_mix{1.0f};      /* 干湿比 [0,1]：1=纯湿（P-005） */
    /* VDC 空间校正（v1.2 M5-3） */
    std::atomic<int32_t>  ddc_enable{0};
    std::atomic<int32_t>  ddc_ready{0};
    /* M3-a：轻量效果开关（真·重排序需 process 链补丁，后置 M3.5） */
    std::atomic<int32_t>  tube_enable{0};       /* T0 */
    std::atomic<float>    tube_gain{0.0f};      /* dB [-3, 12] 驱动度 */
    std::atomic<int32_t>  xfeed_enable{0};      /* T1 ≈3ms */
    /* M5/P-002：声场分带（bandMixUsed 由宿主语义维护） */
    std::atomic<float>    stereo_band[5];
    std::atomic<int32_t>  stereo_band_used{0};
    /* M5-b：低频搁架（low-shelf，自研 RBJ biquad，零 vendor 改动） */
    std::atomic<int32_t>  shelf_enable{0};
    std::atomic<float>    shelf_freq{100.0f};   /* Hz [40,400] */
    std::atomic<float>    shelf_gain{0.0f};     /* dB [-15,15] */
    /* M5-c：参数化混响（Freeverb，T2 档） */
    std::atomic<int32_t>  fv_enable{0};
    std::atomic<float>    fv_decay{0.5f};       /* 0..1 → feedback 0.7..0.98 */
    std::atomic<float>    fv_damp{0.5f};        /* 0..1 */
    std::atomic<float>    fv_wet{0.3f};         /* 0..1 */
    std::atomic<float>    fv_dry{1.0f};         /* 0..1 */
};

/* ---- M5-c Freeverb（Schroeder-Moorer：8 comb + 4 allpass / 声道）----
 * 经典 tuning（@44.1k）按 fs 缩放；create 分配、destroy 释放，RT 零分配。
 * 参数换算沿用 classic freeverb：feedback = 0.7+decay*0.28，damp=damp*0.4。
 * 右声道施加 +23 采样点经典立体声扩展（Stereo Spread），产生自然空间去相关。 */
constexpr int kFvCombs = 8, kFvAllpasses = 4;
constexpr int kFvCombTuning[kFvCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
constexpr int kFvAllpTuning[kFvAllpasses] = {556, 441, 341, 225};
constexpr int kFvStereoSpread = 23;
/* Freeverb 经典梳/全通长度标定在 44.1kHz（1116/556 等即该采样率下的采样数）。
 * 比例必须按**实际** fs 计算，不能写死 48/44.1 —— 写死意味着在 44.1k 或
 * 96k 设备上混响音调与衰减时间整体偏移（旧实现在非 48k 下必然失准）。 */
constexpr double kFvTuningRefRate = 44100.0;

struct FvVoice {
    float* combBuf[kFvCombs];
    int    combSize[kFvCombs];
    int    combIdx[kFvCombs];
    float  filterstore[kFvCombs];   /* 8 个 comb 独立阻尼状态，杜绝互调串扰 */
    float  damp1 = 0, damp2 = 1;
    float* apBuf[kFvAllpasses];
    int    apSize[kFvAllpasses];
    int    apIdx[kFvAllpasses];
};

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

/* 每样本：返回湿信号（Schroeder-Moorer 架构：8 并联 Comb 累加后串联 4 全通做扩散） */
inline float fv_voice_process(FvVoice& v, float in, float feedback) {
    float out = 0.0f;
    for (int i = 0; i < kFvCombs; ++i) {
        const float y = v.combBuf[i][v.combIdx[i]];
        v.filterstore[i] = y * v.damp2 + v.filterstore[i] * v.damp1;
        /* 截断次正常数 (subnormal float)，防止静音时 CPU 触发微码异常陷阱 */
        if (fabsf(v.filterstore[i]) < 1e-15f) v.filterstore[i] = 0.0f;
        v.combBuf[i][v.combIdx[i]] = in + v.filterstore[i] * feedback;
        if (++v.combIdx[i] >= v.combSize[i]) v.combIdx[i] = 0;
        out += y;
    }
    /* 全通扩散层：以 Comb 累加输出为输入，逐级全通相位扩散 */
    for (int i = 0; i < kFvAllpasses; ++i) {
        const float bufout = v.apBuf[i][v.apIdx[i]];
        const float input2 = out + bufout * 0.5f;
        v.apBuf[i][v.apIdx[i]] = input2;
        if (++v.apIdx[i] >= v.apSize[i]) v.apIdx[i] = 0;
        out = bufout - input2;
    }
    if (fabsf(out) < 1e-15f) out = 0.0f;
    return out;
}

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
    float* fft_scratch = nullptr;     /* kVizFftMax floats */
    float* hann = nullptr;            /* kVizFftMax floats */
    float* viz_hist = nullptr;        /* kVizFftMax*2，L/R 交织环形历史窗 */
    std::atomic<int> viz_fft_size{kVizFftDefault};  /* 实际使用长度（2 的幂，<= kVizFftMax） */
    std::atomic<int> viz_interval{480};              /* 产出间隔（帧）= fs/100，即 10ms */
    std::atomic<bool> viz_emitted{false};           /* 是否已产出过频谱帧（窗体重建的安全闸） */
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
    float                 ir_spectrum[8][AURADSP_VIZ_BANDS] = {};

    /* FileGate 资源上限（控制线程下发，来自 config 的安全与资源参数；
     * 此前引擎写死 256MiB / 16M 帧，config 里的同名字段从不生效） */
    std::atomic<float> gate_max_ir_seconds{30.0f};
    std::atomic<float> gate_max_file_mb{64.0f};

    /* M5-c：Freeverb（RT 独占；create 分配） */
    FvVoice fvL, fvR;

    /* M5-b：低频搁架 biquad（系数原子写防撕裂；状态仅 RT 线程触碰） */
    struct ShelfBiquad {
        std::atomic<double> b0{1}, b1{0}, b2{0}, a1{0}, a2{1};
        double z1L = 0, z2L = 0, z1R = 0, z2R = 0;   /* TDF2 状态（RT 独占） */
    } shelf;
    float* shelf_scratch = nullptr;   /* max_block*2，vendor 链前置处理用 */
    float* conv_scratch = nullptr;    /* max_block*2，卷积干湿比（P-005）用 */

    /* M1 插件宿主引擎与双声道平面工作区 */
    std::unique_ptr<auradsp::PluginHostManager> plugin_host;
    float* plugin_buf_l = nullptr;
    float* plugin_buf_r = nullptr;

    /* [ADR-003 Phase A] 多声道矩阵工作区 */
    std::atomic<int> channel_count{2};   /* 驱动层交织缓冲的声道数（2=立体声） */
    float* mx_scratch = nullptr;         /* max_block*kMxMaxChannels，留存各声道 */
    float* mx_stereo = nullptr;          /* max_block*2，下混后的立体声链输出 */

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
    /* 参数化混响 = T2 类（无算法延迟但按档位限定，对齐混响语义） */
    if (h->p.fv_enable.load(std::memory_order_relaxed) &&
        h->p.latency_mode.load(std::memory_order_relaxed) < 2) *over_guard = true;
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
    /* 截断次正常数 (subnormal float)，防止静音时 CPU 陷入微码陷阱 */
    if (fabs(z1L) < 1e-15) z1L = 0.0;
    if (fabs(z2L) < 1e-15) z2L = 0.0;
    if (fabs(z1R) < 1e-15) z1R = 0.0;
    if (fabs(z2R) < 1e-15) z2R = 0.0;
    h->shelf.z1L = z1L; h->shelf.z2L = z2L;
    h->shelf.z1R = z1R; h->shelf.z2R = z2R;
}

void apply_tube(auradsp_handle h) {
    if (h->p.tube_enable.load(std::memory_order_relaxed)) {
        VacuumTubeSetGain(&h->jdsp, (double)h->p.tube_gain.load(std::memory_order_relaxed));
        VacuumTubeEnable(&h->jdsp);
    } else {
        VacuumTubeDisable(&h->jdsp);
    }
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
/* 通用 UTF-8 路径文本读入（R-1 修复：Windows 走 _wfopen，避免 ANSI 代码页）。
 * 成功返回 malloc 的 NUL 结尾内容，失败置 error 返回 nullptr。 */
char* read_text_file(auradsp_handle h, const char* path, long max_bytes,
                     auradsp_status* st) {
    *st = AURADSP_OK;
    if (!path || !path[0]) { set_error(h, "path: empty"); *st = AURADSP_E_PARAM; return nullptr; }
#ifdef _WIN32
    const int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
    if (wlen <= 0) { set_error(h, "path: invalid encoding"); *st = AURADSP_E_PARAM; return nullptr; }
    wchar_t* wpath = (wchar_t*)malloc((size_t)wlen * sizeof(wchar_t));
    if (!wpath) { set_error(h, "path: OOM"); *st = AURADSP_E_IO; return nullptr; }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, wlen);
    FILE* fp = _wfopen(wpath, L"rb");
    free(wpath);
#else
    FILE* fp = fopen(path, "rb");
#endif
    if (!fp) { set_error(h, "file: cannot open"); *st = AURADSP_E_IO; return nullptr; }
    fseek(fp, 0, SEEK_END);
    const long sz = ftell(fp);
    if (sz <= 0 || sz > max_bytes) {
        fclose(fp);
        set_error(h, "file: empty or too large");
        *st = AURADSP_E_PARAM;
        return nullptr;
    }
    rewind(fp);
    char* buf = (char*)malloc((size_t)sz + 1);
    if (!buf) { fclose(fp); set_error(h, "file: OOM"); *st = AURADSP_E_IO; return nullptr; }
    const size_t got = fread(buf, 1, (size_t)sz, fp);
    fclose(fp);
    if (got != (size_t)sz) {
        free(buf);
        set_error(h, "file: read failed");
        *st = AURADSP_E_IO;
        return nullptr;
    }
    buf[sz] = 0;
    return buf;
}

/* 离线计算 IR 多声道频谱包络（复用 viz FFT 基建：WDL_real_fft + 32 对数带） */
void compute_ir_spectrum(auradsp_handle h, const float* data, size_t frames, int ch) {
    if (!h || !data || frames == 0 || ch <= 0) return;
    const int safe_ch = ch > 8 ? 8 : ch;
    memset(h->ir_spectrum, 0, sizeof(h->ir_spectrum));

    const int kN = kVizFftDefault;
    const int half = kN / 2;
    const int nmag = half < 2048 ? half : 2048;
    const int32_t* perm = WDL_fft_permute_tab(half);
    const float bin_hz = h->sample_rate / (float)kN;

    float* buf = (float*)malloc(kN * sizeof(float));
    if (!buf) return;

    for (int c = 0; c < safe_ch; ++c) {
        const size_t take = frames < (size_t)kN ? frames : (size_t)kN;
        // IR 特性：t=0 往往是核心直达声/脉冲尖峰，不能用对称 Hann 窗压制。
        // 采用单侧平顶 Tukey 窗：前段直通 (w=1.0)，仅尾部 64 帧施加平滑余弦衰减防截断跳变。
        const size_t fade_len = take > 128 ? 64 : (take > 4 ? take / 4 : 0);
        const size_t fade_start = take - fade_len;
        for (size_t i = 0; i < take; ++i) {
            float w = 1.0f;
            if (i >= fade_start && fade_len > 0) {
                const float frac = (float)(i - fade_start) / (float)fade_len;
                w = 0.5f * (1.0f + cosf(3.14159265358979f * frac));
            }
            buf[i] = data[i * ch + c] * w;
        }
        for (size_t i = take; i < (size_t)kN; ++i) {
            buf[i] = 0.0f;
        }

        WDL_real_fft(buf, kN, 0);

        float mag[2048];
        float max_m = 1e-9f;
        for (int i = 0; i < nmag; ++i) {
            const int pi = perm ? perm[i] : i;
            const float re = buf[pi * 2];
            const float im = buf[pi * 2 + 1];
            const float m = sqrtf(re * re + im * im);
            mag[i] = m;
            if (m > max_m) max_m = m;
        }

        for (int b = 0; b < AURADSP_VIZ_BANDS; ++b) {
            const int lo = (int)(kBandEdges[b] / bin_hz);
            const int hi = (int)(kBandEdges[b + 1] / bin_hz);
            if (hi <= lo || lo >= nmag) { h->ir_spectrum[c][b] = 0.0f; continue; }
            const int hb = hi > nmag ? nmag : hi;
            float m = 0.0f;
            for (int i = lo; i < hb; ++i) if (mag[i] > m) m = mag[i];
            const float rel = m / max_m;
            float v = 0.0f;
            if (rel > 1e-4f) {
                v = (20.0f * log10f(rel) + 50.0f) * (1.0f / 50.0f);
            }
            h->ir_spectrum[c][b] = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
        }
    }
    free(buf);
}

/* FileGate 文件体积上限（字节）：来自 gate.maxFileMb，兜底 64MiB。
 * 注意兜底判据必须是 "> 0" 而不是 "> 1"——set_param 已把取值夹到 [1,4096]，
 * 用 "> 1" 会把用户显式设置的 1MB 误判成"未设置"而回退到 64MB。
 * 控制线程下发，create 时也会按当时的值生效。 */
static inline long long gate_file_bytes(auradsp_handle h) {
    const float mb = h->gate_max_file_mb.load(std::memory_order_relaxed);
    const double v = (mb > 0.0f) ? (double)mb : 64.0;
    return (long long)(v * 1024.0 * 1024.0);
}

/* 重建汉宁窗。窗长必须**等于**实际 FFT 长度：取长窗的前 kN 个采样会只拿到
 * 上升沿（0→1），那不是窗函数——直流泄漏与旁瓣会直接把最低频带顶满
 * （实测 band0 从 ~0 变成 0.631）。
 * 只能在控制线程调用，且调用方须保证尚未发生过 emit_viz（见 viz.fftSize 参数）。 */
void rebuild_hann(auradsp_handle h, int n) {
    if (n < 2 || n > kVizFftMax) return;
    const double two_pi = 2.0 * 3.14159265358979;
    for (int i = 0; i < n; ++i) {
        h->hann[i] = (float)(0.5 * (1.0 - cos(two_pi * i / (n - 1))));
    }
}

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
    const long long maxFileBytes = gate_file_bytes(h);
    if (fsize > maxFileBytes) {
        fclose(fp);
        set_error(h, "convolver.ir: file too large (exceeds configured gate.maxFileMb)");
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

    /* 时长门卫：来自 config.maxIrDurationSeconds（gate.maxIrSeconds）。
 * 放在重采样**之前**，按文件自身采样率判定用户感知的时长；
 * 同时保留原有的硬顶（16M 帧 / 64M 样本）作为内存的最后防线。 */
const float maxIrSec = h->gate_max_ir_seconds.load(std::memory_order_relaxed);
    if (maxIrSec > 0.1f && src_rate > 0 &&
        (double)frames > (double)maxIrSec * (double)src_rate) {
        free(data);
        set_error(h, "convolver.ir: too long (exceeds configured gate.maxIrSeconds)");
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
    if (rc != 1) {
        free(proc);
        set_error(h, "convolver.ir: vendor load failed (partition select?)");
        return AURADSP_E_STATE;
    }
    compute_ir_spectrum(h, proc, out_frames, (int)ch);
    free(proc);
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
    const int mask = h->viz_fft_size.load(std::memory_order_relaxed) - 1;
    /* 历史写入与块峰值合并为一趟遍历：旧实现分两趟，等于把 out 多读一遍
     *（2048 帧块 = 多读 16KB）。两趟访问的下标序列完全一致，合并安全。 */
    float lvl_l = 0.0f, lvl_r = 0.0f;
    for (int i = 0; i < frames; ++i) {
        const float l = out[i * 2];
        const float r = out[i * 2 + 1];
        h->viz_hist[h->viz_hist_pos * 2]     = l;
        h->viz_hist[h->viz_hist_pos * 2 + 1] = r;
        h->viz_hist_pos = (h->viz_hist_pos + 1) & mask;
        const float a = fabsf(l), b = fabsf(r);
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
    const int kN = h->viz_fft_size.load(std::memory_order_relaxed);
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
    f.timestamp_ms =
        f.seq * (h->viz_interval.load(std::memory_order_relaxed) * 1000.0 / h->sample_rate);

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

    /* 5) [M3.5-c] vendor 链各 stage 的输出峰值转 dBFS。
     * 只有前 AURADSP_VENDOR_STAGES 项有数据；其余（到 ABI 容量上限）是保留位，
     * 恒为 -120 dBFS，UI 不应展示。 */
    for (int i = 0; i < AURADSP_STAGE_MAX; ++i) {
        if (i < AURADSP_VENDOR_STAGES) {
            const float pl = h->jdsp.stagePeakL[i];
            const float pr = h->jdsp.stagePeakR[i];
            f.stage_levels_l[i] = pl > 1e-6f ? 20.0f * log10f(pl) : -120.0f;
            f.stage_levels_r[i] = pr > 1e-6f ? 20.0f * log10f(pr) : -120.0f;
        } else {
            f.stage_levels_l[i] = -120.0f;
            f.stage_levels_r[i] = -120.0f;
        }
    }
    h->viz_emitted.store(true, std::memory_order_relaxed);
    h->viz.push(f);
}

}  // namespace

/* ================= ABI 实现 ================= */

extern "C" {

const char* auradsp_version(void) { return AURADSP_VERSION; }
uint32_t    auradsp_abi(void) { return AURADSP_ABI; }

/* ---------------------------------------------------------------------------
 * 组件延迟实测（D11）
 *
 * 做法：自建一次性探针 handle（不触碰调用方正在放音的 handle —— 实测两个 handle
 * 可安全共存，见 tools/probe_concurrent.py），只启用目标组件，注入单位脉冲，
 * 检测首个非零输出的样本位置。返回值是**测出来的**，不是查表来的。
 *
 * 先测一遍"全关基线"，再减去它——基线可能因链上零相位环节而有微小偏移，
 * 相减后得到的是该组件自身的净算法延迟。
 *
 * 窗口上限 kProbeWindow：覆盖 vendor 侧最大前瞻（FFT 块级）绰绰有余；
 * 超窗仍未出现输出即视为"无可测延迟"返回 0（纯 IIR 的正常情形）。
 * ------------------------------------------------------------------------- */
namespace {
constexpr int kProbeWindow = 16384;   /* @48k ≈ 341ms */
constexpr int kProbeBlock  = 256;

/* 把探针 handle 上的所有效果关掉，只留下要测的那个 */
void probe_isolate(auradsp_handle p, const char* comp) {
    const struct { const char* id; int i; } zeros[] = {
        {"bass.enable", 0}, {"eq.enable", 0}, {"tube.enable", 0},
        {"crossfeed.enable", 0}, {"limiter.enable", 0}, {"convolver.enable", 0},
        {"ddc.enable", 0}, {"liveprog.enable", 0}, {"shelf.enable", 0},
    };
    for (const auto& z : zeros) {
        const int32_t v = 0;
        auradsp_set_param(p, z.id, &v, 4);
    }
    int32_t zero = 0;
    auradsp_set_param(p, "reverb.preset", &zero, 4);   /* -1 = off */
    auradsp_set_param(p, "freeverb.enable", &zero, 4);
    const float zero_f = 0.0f;
    auradsp_set_param(p, "stereo.mix", &zero_f, 4);
    auradsp_set_param(p, "post.gain", &zero_f, 4);
    auradsp_set_param(p, "bass.gain", &zero_f, 4);

    if (!strcmp(comp, "bass")) {
        const int32_t one = 1; const float g = 6.0f;
        auradsp_set_param(p, "bass.enable", &one, 4);
        auradsp_set_param(p, "bass.gain", &g, 4);
    } else if (!strcmp(comp, "reverb")) {
        const int32_t one = 1;
        auradsp_set_param(p, "reverb.preset", &one, 4);
    } else if (!strcmp(comp, "eq")) {
        const int32_t one = 1;
        auradsp_set_param(p, "eq.enable", &one, 4);
        const char* curve = "20:0;100:0;1000:0;10000:0;20000:0;";
        auradsp_set_param(p, "eq.curve", curve, (uint32_t)strlen(curve));
    } else if (!strcmp(comp, "tube")) {
        const int32_t one = 1;
        auradsp_set_param(p, "tube.enable", &one, 4);
    } else if (!strcmp(comp, "crossfeed")) {
        const int32_t one = 1;
        auradsp_set_param(p, "crossfeed.enable", &one, 4);
    } else if (!strcmp(comp, "limiter") || !strcmp(comp, "post")) {
        const int32_t one = 1;
        auradsp_set_param(p, "limiter.enable", &one, 4);
    } else if (!strcmp(comp, "shelf")) {
        const int32_t one = 1; const float g = 6.0f;
        auradsp_set_param(p, "shelf.enable", &one, 4);
        auradsp_set_param(p, "shelf.gain", &g, 4);
    }
    /* convolver / ddc / liveprog 需要外部资源（IR / VDC / 脚本），
     * 无法在空探针上就绪，此时如实返回"不可测"而不是编一个数字。 */
}

bool probe_is_supported(const char* comp) {
    static const char* kSupported[] = {
        "bass", "reverb", "eq", "tube", "crossfeed", "limiter", "post", "shelf"
    };
    for (const char* s : kSupported)
        if (!strcmp(comp, s)) return true;
    return false;
}

/* 打脉冲，返回首个非零输出样本下标（无则 -1），并把输出总能量写入 *energy。
 * 能量用于判定「该组件是否真的参与了处理」——否则一个没接上的组件会被
 * 误报成「实测 0 ms 延迟」，把「测不到」谎报成「测到了」。 */
long probe_first_nonzero(auradsp_handle p, float threshold, double* energy) {
    float* in = (float*)calloc(kProbeBlock * 2, sizeof(float));
    float* out = (float*)calloc(kProbeBlock * 2, sizeof(float));
    if (!in || !out) { free(in); free(out); return -1; }
    long first = -1;
    double e = 0.0;
    bool injected = false;
    for (int processed = 0; processed < kProbeWindow; processed += kProbeBlock) {
        memset(in, 0, sizeof(float) * kProbeBlock * 2);
        if (!injected) { in[0] = 1.0f; in[1] = 1.0f; injected = true; }
        auradsp_process(p, in, out, kProbeBlock);
        for (int i = 0; i < kProbeBlock * 2; ++i) {
            const double a = fabs((double)out[i]);
            if (a > (double)threshold && first < 0) first = processed + i / 2;
            e += a * a;
        }
    }
    free(in);
    free(out);
    if (energy) *energy = e;
    return first;
}
}  // namespace

int auradsp_probe_component(const char* component, double sample_rate,
                            uint32_t* out_samples) {
    if (!component || !out_samples) return -1;
    *out_samples = 0;
    if (!probe_is_supported(component)) return -1;
    const double fs = (sample_rate > 8000.0) ? sample_rate : 48000.0;

    auradsp_handle probe = auradsp_create((float)fs, kProbeBlock);
    if (!probe) return -2;
    const int32_t quality = 2;
    auradsp_set_param(probe, "mode.latency", &quality, 4);

    /* 基线：全关，量出链自身的零点偏移与能量 */
    double base_energy = 0.0;
    probe_isolate(probe, "");
    const long baseline = probe_first_nonzero(probe, 1e-7f, &base_energy);

    double energy = 0.0;
    probe_isolate(probe, component);
    const long first = probe_first_nonzero(probe, 1e-7f, &energy);

    auradsp_destroy(probe);

    /* 参与度判据：目标组件必须让输出能量偏离基线，否则说明它没真正生效
     * （参数被守卫拒绝 / 效果未注册）。此时返回 -3「无法测量」，
     * 而不是谎报 0 毫秒。 */
    if (first < 0) return -3;                       /* 全程无输出：不可测 */
    if (fabs(energy - base_energy) <= 1e-9 * (base_energy + 1.0)) return -3;

    long delay = first - (baseline > 0 ? baseline : 0);
    if (delay < 0) delay = 0;
    *out_samples = (uint32_t)delay;
    return 0;
}

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
    h->shelf_scratch = new (std::nothrow) float[(size_t)max_block_frames * 2]();
    if (!h->shelf_scratch) {
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist; delete h; return nullptr;
    }
    h->conv_scratch = new (std::nothrow) float[(size_t)max_block_frames * 2]();
    if (!h->conv_scratch) {
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist;
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
        delete[] h->fft_scratch; delete[] h->hann; delete[] h->viz_hist;
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

    std::lock_guard<std::mutex> lk(h->ctrl_mutex);
    JamesDSPInit(&h->jdsp, max_block_frames, sample_rate);
    /* P-005：scratch 绑定（必须在 memset 之后）+ 默认纯湿（=上游行为） */
    h->jdsp.auraConvScratch = h->conv_scratch;
    h->jdsp.auraConvWet = 1.0f;
    h->jdsp.auraConvDry = 0.0f;
    h->jdsp.auraConvMixUsed = 0;
    fv_alloc(h->fvL, sample_rate, 0);
    fv_alloc(h->fvR, sample_rate, kFvStereoSpread);
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
    if (h->plugin_host) {
        for (size_t s = 0; s < auradsp::PluginHostManager::kMaxPluginSlots; ++s) {
            h->plugin_host->unloadPluginSlot(s);
        }
        h->plugin_host.reset();
    }
    fv_free(h->fvL);
    fv_free(h->fvR);
    delete[] h->fft_scratch;
    delete[] h->viz_hist;
    delete[] h->shelf_scratch;
    delete[] h->conv_scratch;
    delete[] h->plugin_buf_l;
    delete[] h->plugin_buf_r;
    free(h->lp_code);
    delete h;
    global_unref();
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
static inline bool mx_downmix(auradsp_handle h, const float* in, float* stereo,
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
static inline void mx_upmix(auradsp_handle h, float* out, const float* stereo,
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

static void process_stereo_chain(auradsp_handle h, const float* src, float* dst,
                                 int frames);

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
    if (multichannel && h->mx_scratch) {
        if (st != AURADSP_STATE_PROCESSING) {
            /* 非处理态：原样直通（含全部声道），不做矩阵 */
            memcpy(out, in, (size_t)frames * ch * sizeof(float));
            return;
        }
        if (!mx_downmix(h, in, h->shelf_scratch, frames, ch) || !h->mx_stereo) {
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
    /* 输入拷入 shelf_scratch（in 原位不可写，同时作为链前置工作区） */
    memcpy(h->shelf_scratch, in, (size_t)frames * 2 * sizeof(float));
    process_stereo_chain(h, h->shelf_scratch, out, frames);
    h->frames_since_viz += frames;
    viz_write(h, out, frames);
    const int vizInt2 = h->viz_interval.load(std::memory_order_relaxed);
    while (h->frames_since_viz >= vizInt2) {
        h->frames_since_viz -= vizInt2;
        emit_viz(h);
    }
}

/* 立体声处理链本体（RT 线程；src != dst 恒成立）。
 *
 * 抽成独立函数是为了让多声道路径复用同一条链：多声道场景先把 M 声道下混成
 * src，再走这条链得到 dst，最后上混回 M —— 保证"多声道 = 立体声 + 矩阵"
 * 这一不变式，不会出现两套效果逻辑各自漂移。
 * src 为只读输入，dst 为就地处理的工作区与输出。
 */
static void process_stereo_chain(auradsp_handle h, const float* src, float* dst,
                                 int frames) {
    /* Stage 0: Pre-DSP（链头，最前置） */
    process_plugin_slots_stage(h, 0, const_cast<float*>(src), frames);

    /* M5-b：低频搁架在 vendor 链前（就地改 src） */
    if (h->p.shelf_enable.load(std::memory_order_relaxed) &&
        h->p.shelf_gain.load(std::memory_order_relaxed) != 0.0f) {
        shelf_process(h, const_cast<float*>(src), frames);
    }

    /* Stage 1: Pre-Vendor（主效果前） */
    process_plugin_slots_stage(h, 1, const_cast<float*>(src), frames);

    /* libjamesdsp 稳态无分配；块超限时内部自动重分配（pfloat32Multiplexed） */
    h->jdsp.processFloatMultiplexd(&h->jdsp, const_cast<float*>(src), dst,
                                   (size_t)frames);

    /* Stage 2: Post-Vendor（主效果后 / 混响前） */
    process_plugin_slots_stage(h, 2, dst, frames);

    /* M5-c：Freeverb 在 vendor 链后（含输出限幅），wet/dry 原位混合 */
    if (h->p.fv_enable.load(std::memory_order_relaxed)) {
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
    }

    /* Stage 3: Post-Reverb（混响后，默认阶段） */
    process_plugin_slots_stage(h, 3, dst, frames);

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
    /* ---- M5 第二批：EQ 频率轴曲线（multimodalEQ 轴注入） ----
     * value = "f:g;f:g;..."（≤15 点，freq 升序，gain dB [-64,64]）。
     * 不足 NUMPTS 用末端值线性补齐；MultimodalEqualizerAxisInterpolation
     * 内部 memcpy 恰好 NUMPTS 点。operatingMode=0 立即重建 IR，
     * interpolationMode=1（makima，上游默认）。 */
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
        /* 解析点对（手写分词，避免 MSVC 无 strtok_r） */
        double pf[64], pg[64];
        int n = 0;
        char* cur = txt;
        while (cur && n < 64) {
            char* semi = strchr(cur, ';');
            if (semi) *semi = 0;
            char* colon = strchr(cur, ':');
            if (colon) {
                *colon = 0;
                const double f = atof(cur), g = atof(colon + 1);
                if (f > 0 && f <= 96000) {
                    pf[n] = f;
                    pg[n] = g < -64 ? -64 : (g > 64 ? 64 : g);
                    ++n;
                }
            }
            cur = semi ? semi + 1 : nullptr;
        }
        free(txt);
        if (n < 2) {
            set_error(h, "eq.curve: need >= 2 points (f:g;f:g;...)");
            return AURADSP_E_PARAM;
        }
        /* 简易插入排序按 freq 升序 */
        for (int i = 1; i < n; ++i) {
            const double kf = pf[i], kg = pg[i];
            int j = i - 1;
            while (j >= 0 && pf[j] > kf) { pf[j + 1] = pf[j]; pg[j + 1] = pg[j]; --j; }
            pf[j + 1] = kf; pg[j + 1] = kg;
        }
        /* 补齐到 NUMPTS：对数频率域均匀重采样（EQ 插值工作在 log-f 域，
         * 线性采样会把 UI 轴点挤掉——烟囱测试抓回） */
        double freqAx[NUMPTS], gainAx[NUMPTS];
        const double lf0 = log(pf[0]), lf1 = log(pf[n - 1]);
        for (int i = 0; i < NUMPTS; ++i) {
            const double t = (NUMPTS == 1) ? 0.0 : (double)i / (double)(NUMPTS - 1);
            const double target = exp(lf0 + t * (lf1 - lf0));
            int seg = 0;
            while (seg < n - 2 && pf[seg + 1] < target) ++seg;
            const double ls0 = log(pf[seg]), ls1 = log(pf[seg + 1]);
            const double k = (ls1 - ls0) > 1e-9
                ? (log(target) - ls0) / (ls1 - ls0) : 0.0;
            freqAx[i] = target;
            gainAx[i] = pg[seg] + k * (pg[seg + 1] - pg[seg]);
        }
        MultimodalEqualizerAxisInterpolation(&h->jdsp, 1, 0, freqAx, gainAx);
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
            set_error(h, "ddc.enable: no VDC loaded");
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
    /* ---- M5-c 参数化混响（T2 守卫与 reverb 同策略） ---- */
    if (!strcmp(id, "freeverb.enable") && bytes >= 4) {
        const int32_t v = *(const int32_t*)value ? 1 : 0;
        const int32_t old = h->p.fv_enable.exchange(v);
        double ms = 0.0; bool over = false;
        if (v && !compute_latency(h, &ms, &over)) {
            h->p.fv_enable.store(old);
            set_error(h, "latency guard: reverb-class effect, switch to quality mode first");
            return AURADSP_E_LATENCY_GUARD;
        }
        compute_latency(h, &ms, &over);
        h->latency_ms = ms;
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
    std::lock_guard<std::mutex> lk(h->ctrl_mutex);
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
    if (!strcmp(id, "crossfeed.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.xfeed_enable.load(); return AURADSP_OK; }
    if (!strcmp(id, "shelf.enable") && bytes >= 4) { *(int32_t*)out_value = h->p.shelf_enable.load(); return AURADSP_OK; }
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

/* ---- 第三方插件宿主（M1：VST3 / CLAP 64位） ---- */
int auradsp_plugin_scan(auradsp_handle h, const char* extra_dirs_json, int deep_scan) {
    if (!h || !h->plugin_host) return 0;
    std::string extra = extra_dirs_json ? extra_dirs_json : "";
    return h->plugin_host->scanPlugins(extra, deep_scan != 0);
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

/* ---- 多插槽感知控制 (slot = 0..1) ---- */
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

int auradsp_plugin_slot_show_editor(auradsp_handle h, int slot) {
    if (!h || !h->plugin_host || slot < 0 || slot >= (int)auradsp::PluginHostManager::kMaxPluginSlots) return 0;
    return h->plugin_host->showEditorSlot((size_t)slot) ? 1 : 0;
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
