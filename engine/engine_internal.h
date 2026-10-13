/* P2: shared internals (moved verbatim; zero logic change). */

#pragma once

#include "auradsp_engine.h"
#include "auradsp_plugin_host.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <new>
#include <xmmintrin.h>
#include <windows.h> /* MultiByteToWideChar / _wfopen（审查修复 R-1） */

#define AURADSP_VERSION "1.1.0"
#define AURADSP_ABI 1

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

/* 32 个对数频带的边界（Hz，20Hz ~ 20kHz）
 * 尾部原为 6300/8000/10000/12500/16000/18000/19000/20000 —— 其中后三带只有
 * 1kHz 宽（对数跨度 0.74%，是中频带的 ~1/4），在 UI 上被画成发丝。
 * 现改为 5950→20000 等比约 1.19，与全局阶梯一致，最窄带 2.46%。
 * 纯显示用分组表（频谱 + IR 频谱），不参与任何滤波或 DSP 决策。 */
constexpr float kBandEdges[AURADSP_VIZ_BANDS + 1] = {
    20, 25, 31, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, //
    630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, //
    5950, 7070, 8400, 10000, 11900, 14100, 16800, 20000};


struct Params {
    std::atomic<int32_t>  bass_enable{0};
    std::atomic<float>    bass_gain{0.0f};      /* dB [0,15] */
    std::atomic<int32_t>  reverb_preset{-1};
    std::atomic<float>    stereo_mix{0.0f};     /* [0,1] */
    std::atomic<int32_t>  eq_enable{0};
    std::atomic<int32_t>  limiter_enable{0};
    std::atomic<float>    post_gain{0.0f};      /* dB [-15,15] */
    /* latency_mode 已由 ADR-006 移除：延迟改为纯测量，不再有档位准入。 */
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
    std::atomic<int32_t>  tube_style{0};       /* P-011: 0 Triode / 1 Pentode / 2 Tape */
    std::atomic<float>    tube_mix{1.0f};       /* P-011: 湿比 [0, 1] */
    std::atomic<float>    tube_compensation{0.0f}; /* P-011: 输出补偿 dB [-12, 12] */
    std::atomic<int32_t>  xfeed_enable{0};      /* T1 ≈3ms */
    std::atomic<int32_t>  xfeed_mode{0};        /* 0: Default, 1: Chu Moy, 2: Jan Meier, 3: Custom */
    std::atomic<float>    xfeed_fcut{700.0f};   /* Hz [300, 2000] */
    std::atomic<float>    xfeed_feed{4.5f};     /* dB [1.0, 15.0] */
    /* M5/P-002：声场分带（bandMixUsed 由宿主语义维护） */
    std::atomic<float>    stereo_band[5];
    std::atomic<int32_t>  stereo_band_used{0};
    /* M5-b：低频搁架（low-shelf，自研 RBJ biquad，零 vendor 改动） */
    std::atomic<int32_t>  shelf_enable{0};
    std::atomic<float>    shelf_freq{100.0f};   /* Hz [40,400] */
    std::atomic<float>    shelf_gain{0.0f};     /* dB [-15,15] */
    /* BassMono：低频单声道化（one-pole LPF，RT 线程就地处理，零延迟） */
    std::atomic<int32_t>  bassmono_enable{0};
    std::atomic<float>    bassmono_freq{120.0f}; /* Hz [20,300] */
    /* Haas 差分环绕（延迟侧 0..25ms + 干湿混合；side 选延迟哪一侧） */
    std::atomic<int32_t>  haas_enable{0};
    std::atomic<float>    haas_delay_ms{12.0f};  /* ms [0,25] */
    std::atomic<float>    haas_mix{1.0f};        /* [0,1] */
    std::atomic<int32_t>  haas_side{0};          /* 0=延迟右 1=延迟左 */
    /* 激励器（HPF 取高频 + tanh 谐波混回；drive 固定，只暴露 amount/hifreq） */
    std::atomic<int32_t>  exciter_enable{0};
    std::atomic<float>    exciter_amount{0.3f};  /* [0,1] */
    std::atomic<float>    exciter_hifreq{5000.0f}; /* Hz [3000,10000] */
    /* 每效果输出增益门（dB [-12,6]）+ 自动增益补偿开关。
     * bass/eq/tube/comp 落地 vendor（P-010 的 fxOutGain/fxAutoGain）；
     * reverb 落地引擎侧 Freeverb。 */
    std::atomic<float>    bass_outgain{0.0f};
    std::atomic<int32_t>  bass_autogain{0};
    std::atomic<float>    eq_outgain{0.0f};
    std::atomic<int32_t>  eq_autogain{0};
    std::atomic<float>    tube_outgain{0.0f};
    std::atomic<int32_t>  tube_autogain{0};
    std::atomic<float>    comp_outgain{0.0f};
    std::atomic<int32_t>  comp_autogain{0};
    std::atomic<float>    reverb_outgain{0.0f};
    std::atomic<int32_t>  reverb_autogain{0};
    /* 噪声门 + 齿音消除（Deesser）+ 自动增益补偿（链头） */
    std::atomic<int32_t>  gate_enable{0};
    std::atomic<float>    gate_threshold{-40.0f}; /* dB [-60,0] */
    std::atomic<float>    gate_attack{10.0f};     /* ms [1,100] */
    std::atomic<float>    gate_release{100.0f};   /* ms [10,500] */
    std::atomic<int32_t>  gate_autogain{0};
    /* 响度补偿（信号自适应等响度：静音段按简化 ISO226 补低+高） */
    std::atomic<int32_t>  loudness_enable{0};
    std::atomic<float>    loudness_amount{0.5f};  /* [0,1] */    std::atomic<int32_t>  deesser_enable{0};
    std::atomic<float>    deesser_freq{6000.0f};  /* Hz [2000,10000] */
    std::atomic<float>    deesser_amount{0.5f};   /* [0,1] */
    /* 心理声学低音（谐波合成；频带 = LP(cutoff) − LP(subfreq)） */
    std::atomic<float>    bass_harmonics{0.45f};  /* [0,1] 谐波量 */
    std::atomic<float>    bass_harmonicblend{0.5f}; /* [0,1] 谐波混合 */
    std::atomic<float>    bass_subfreq{25.0f};    /* Hz [10,40] 谐波下限 */
    std::atomic<float>    bass_cutoff_f{120.0f};  /* Hz [30,300] 谐波上限 */
    /* 独立滤波器（RBJ biquad：HP/LP/BP，链头 gate 之后） */
    std::atomic<int32_t>  filter_enable{0};
    std::atomic<int32_t>  filter_type{0};     /* 0=HP 1=LP 2=BP */
    std::atomic<float>    filter_freq{80.0f}; /* Hz [20,20000] */
    std::atomic<float>    filter_q{0.707f};   /* [0.3,10] */
    /* M5-c：参数化混响（Freeverb，T2 档） */
    std::atomic<int32_t>  fv_enable{0};
    std::atomic<float>    fv_decay{0.5f};       /* 0..1 → feedback 0.7..0.98 */
    std::atomic<float>    fv_damp{0.5f};        /* 0..1 */
    std::atomic<float>    fv_wet{0.3f};         /* 0..1 */
    std::atomic<float>    fv_dry{1.0f};         /* 0..1 */
    /* 输入门控（钉死在链路最前端；全通道总增益 + 8通道单控平衡比例） */
    std::atomic<float>    input_gain{0.0f};     /* dB [-15,15] 默认 0.0 */
    std::atomic<float>    input_ch_gain[8];     /* 各声道单控比例 [0.0, 2.0]，默认 1.0 (100%) */
    /* 动态压限器（Compressor / FFTCompander） */
    std::atomic<int32_t>  comp_enable{0};
    std::atomic<float>    comp_timeconstant{0.14f};  /* 秒 [0.02, 0.5] */
    std::atomic<int32_t>  comp_granularity{1};       /* [0, 4] 频带颗粒度 */
    std::atomic<int32_t>  comp_tfresolution{1};      /* [0, 3] 时频模式: 1=标准, 3=Gammatone零延迟 */
    /* 任意响应均衡器（ArbMag / AutoEq GraphicEQ） */
    std::atomic<int32_t>  arbmag_enable{0};
    std::atomic<int32_t>  arbmag_ready{0};
    std::atomic<int32_t>  arbmag_nodes{0};
    std::atomic<float>    arbmag_outgain{0.0f};
    std::atomic<int32_t>  arbmag_autogain{0};
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

/* 各效果引入的近似附加延迟 ms。
 * ADR-006：延迟档硬约束已撤销，本表只用于「如实测量并上报」，
 * 不参与任何准入判定（kTierBudget / over_guard 一并删除）。
 * tier 字段保留为文档性标注，供 graph.effects 输出与 UI 排障参考。 */
struct LatencyItem { int tier; float ms; };
constexpr LatencyItem kLatReverb   {2, 30.0f};
constexpr LatencyItem kLatComp     {2, 85.0f};  /* FFTCompander FFTSIZE_DRS/2 */
constexpr LatencyItem kLatConvolver{2, 10.0f};  /* 保守下限，IR 长度另计 */
constexpr LatencyItem kLatArbMag   {2, 2.67f};  /* 分块 FFT 卷积（128 frames @48k） */
constexpr LatencyItem kLatCrossfeed{1, 3.0f};
constexpr LatencyItem kLatDdc      {1, 6.0f};
constexpr LatencyItem kLatLimiter  {0, 2.0f};


/* handle (moved verbatim) */
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
    /* 频谱分析用的一阶 DC blocker 状态（仅 viz 线程访问） */
    float dc_prev_in = 0.0f;
    float dc_prev_out = 0.0f;
    /* [EQ tap] vendor 链入口（均衡器输入）的第二条 tap。
     * 环形历史与 DC blocker 状态必须与上面那条**各自独立**：DC blocker
     * 是逐窗递推的有状态滤波器，两条 tap 共用一组状态就会互相插值，
     * 结果既不是主频谱、也不是 EQ 输入谱。 */
    float* eq_in_hist = nullptr;       /* kVizFftMax*2，L/R 交织环形历史窗 */
    int    eq_in_hist_pos = 0;
    float  eq_dc_prev_in = 0.0f;
    float  eq_dc_prev_out = 0.0f;
    uint64_t viz_seq = 0;
    float  viz_lvl_l = -120.0f;       /* 最近块峰值 dBFS（viz_write 记录） */
    float  viz_lvl_r = -120.0f;
    /* 输入门控实时本级电平（dBFS；RT 线程每块记录，emit_viz 填入 stage_levels 保留槽位） */
    float  input_lvl_in_l = -120.0f;
    float  input_lvl_in_r = -120.0f;
    float  input_lvl_out_l = -120.0f;
    float  input_lvl_out_r = -120.0f;

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
    /* 混响自动增益补偿平滑状态（RT 独占） */
    double rev_ag_in = 0.0, rev_ag_out = 0.0, rev_ag_comp = 1.0;

    /* M5-b：低频搁架 biquad（系数原子写防撕裂；状态仅 RT 线程触碰） */
    struct ShelfBiquad {
        std::atomic<double> b0{1}, b1{0}, b2{0}, a1{0}, a2{1};
        double z1L = 0, z2L = 0, z1R = 0, z2R = 0;   /* TDF2 状态（RT 独占） */
    } shelf;
    /* 独立滤波器 biquad（同 shelf 模式：控制线程重算系数，RT 只读） */
    struct FilterBiquad {
        std::atomic<double> b0{1}, b1{0}, b2{0}, a1{0}, a2{1};
        double z1L = 0, z2L = 0, z1R = 0, z2R = 0;
    } filter;
    /* BassMono one-pole 状态（RT 独占；系数值每块现算，天然跟随 rate/freq） */
    float bm_lp_l = 0.0f, bm_lp_r = 0.0f;
    /* 噪声门/Deesser 状态（RT 独占） */
    float gate_gain = 1.0f;         /* 门增益（平滑后） */
    float gate_ds_lp_l = 0.0f, gate_ds_lp_r = 0.0f;  /* Deesser 侧链 HP 状态 */
    float gate_ds_env = 0.0f;       /* Deesser 侧链包络 */
    double gate_ag_in = 0.0, gate_ag_out = 0.0, gate_ag_comp = 1.0;
    /* 心理声学低音 one-pole 状态（RT 独占；系数值每块现算） */
    float psy_lp_l = 0.0f, psy_lp_r = 0.0f;   /* cutoff LP */
    float psy_sub_l = 0.0f, psy_sub_r = 0.0f; /* subfreq LP */
    /* 响度补偿状态（RT 独占） */
    float loud_lp_l = 0.0f, loud_lp_r = 0.0f;   /* 200Hz LP（低频成分） */
    float loud_hp_l = 0.0f, loud_hp_r = 0.0f;   /* 6kHz HP 状态（高频成分） */
    double loud_level = 0.0;                      /* 慢速电平跟随（~0.5s） */
    /* Haas 右声道延迟环（RT 独占；create 时按 25ms 上限分配并清零） */
    float* haas_ring = nullptr;
    int    haas_ring_len = 0;
    int    haas_pos = 0;
    /* 激励器 one-pole HP 状态（RT 独占；系数值每块现算） */
    float exc_lp_l = 0.0f, exc_lp_r = 0.0f;
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

inline void set_error(auradsp_handle h, const char* msg) {
    if (h) { snprintf(h->last_error, sizeof(h->last_error), "%s", msg); }
}

inline 
/* 立体声块 RMS（reverb 自动补偿计量用；RT 独占调用） */
static double stereo_block_rms(const float* io, int frames) {
    double acc = 0.0;
    for (int i = 0; i < frames; ++i) {
        const double l = io[i * 2], r = io[i * 2 + 1];
        acc += l * l + r * r;
    }
    return sqrt(acc / (2.0 * (double)frames));
}

int build_eq_axis(char* txt, double sample_rate, double* freqAx, double* gainAx, int* interpMode, int* opMode);
/* cross-TU decls (destatic, signatures verbatim) */
bool global_init();
void global_unref();
void freeverb_process(auradsp_handle h, float* dst, int frames);
void apply_arbmag(auradsp_handle h);
void apply_bass(auradsp_handle h);
void apply_comp(auradsp_handle h);
void apply_convolver(auradsp_handle h);
void apply_crossfeed(auradsp_handle h);
void apply_eq(auradsp_handle h);
void apply_fx_gains(auradsp_handle h);
void apply_liveprog(auradsp_handle h);
void apply_params_locked(auradsp_handle h);
void apply_post(auradsp_handle h);
void apply_reverb(auradsp_handle h);
void apply_stereo(auradsp_handle h);
void apply_tube(auradsp_handle h);
void bassmono_process(auradsp_handle h, float* io, int frames);
void basspsycho_process(auradsp_handle h, float* io, int frames);
void compute_latency(auradsp_handle h, double* out_ms);
void emit_viz(auradsp_handle h);
void exciter_process(auradsp_handle h, float* io, int frames);
void filter_process(auradsp_handle h, float* io, int frames);
void filter_recalc(auradsp_handle h);
void fv_alloc(FvVoice& v, double sampleRate, int spread);
void fv_free(FvVoice& v);
void gate_process(auradsp_handle h, float* io, int frames);
void haas_process(auradsp_handle h, float* io, int frames);
auradsp_status load_ir_file(auradsp_handle h, const char* path);
void loudness_process(auradsp_handle h, float* io, int frames);
void lp_refresh_sliders(auradsp_handle h);
bool mx_downmix(auradsp_handle h, const float* in, float* stereo, int frames, int ch);
void mx_upmix(auradsp_handle h, float* out, const float* stereo, int frames, int ch);
void process_stereo_chain(auradsp_handle h, const float* src, float* dst, int frames);
char* read_text_file(auradsp_handle h, const char* path, long max_bytes, auradsp_status* st);
void rebuild_hann(auradsp_handle h, int n);
void shelf_process(auradsp_handle h, float* io, int frames);
void shelf_recalc(auradsp_handle h);
void viz_write(auradsp_handle h, const float* out, int frames);
void viz_write_eq_in(auradsp_handle h, const float* src, int frames);
