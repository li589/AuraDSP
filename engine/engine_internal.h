/* P2: shared internals (moved verbatim; zero logic change). */

#pragma once

#include "auradsp_engine.h"
#include "plugin_host.h"
#include "dsp/dsp_oversample.h"
#include "dsp/dsp_lookahead_limiter.h"
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
#include "legacy/jdsp/jdsp_header.h"
#include "legacy/jdsp/Effects/eel2/fft.h"
}

/* legacy liveprogWrapper.c 的错误码转文案（未在头文件声明，全局符号） */
extern "C" const char* checkErrorCode(int errCode);
/* legacy 离线重采样（nseel-compiler.c 定义，无头文件声明） */
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

/* 8 声道位掩码定义 (对齐 WAVEFORMATEX / 驱动拓扑声道序) */
constexpr uint32_t kChMaskFL    = (1u << 0); /* 0x01: Front Left */
constexpr uint32_t kChMaskFR    = (1u << 1); /* 0x02: Front Right */
constexpr uint32_t kChMaskC     = (1u << 2); /* 0x04: Center */
constexpr uint32_t kChMaskLFE   = (1u << 3); /* 0x08: Low Frequency Effect */
constexpr uint32_t kChMaskSL    = (1u << 4); /* 0x10: Surround Left */
constexpr uint32_t kChMaskSR    = (1u << 5); /* 0x20: Surround Right */
constexpr uint32_t kChMaskBL    = (1u << 6); /* 0x40: Back Left */
constexpr uint32_t kChMaskBR    = (1u << 7); /* 0x80: Back Right */
constexpr uint32_t kChMaskAll   = 0xFF;      /* 0xFF: 全声道 (255) */
constexpr uint32_t kChMaskNoLfe = 0xF7;      /* 0xF7: 排除 LFE (247) */

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
std::atomic<float>    stereo_mix{0.5f};     /* [0,1] 中性档 0.5（C3 统一单源，2026-10-19） */
    /* 2026-10-16 口径决策：UI 为真。以下默认值必须与 Dart ParamDefaults
     * （app/auradsp_app/lib/core/state.dart L64-171）逐项一致，改动需同步两侧
     * 并跑 flutter test（D1 监察）+ smoke。 */
    std::atomic<int32_t>  stereo_enable{0};   /* 默认关（UI 为真，原 1） */
    std::atomic<int32_t>  eq_enable{0};
    std::atomic<int32_t>  limiter_enable{1};  /* 默认开（UI 为真，原 0） */
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
    std::atomic<float>    tube_gain{4.5f};      /* dB [-3, 12] 驱动度（UI 为真，原 0.0） */
    std::atomic<int32_t>  tube_style{0};       /* P-011: 0 Triode / 1 Pentode / 2 Tape */
    std::atomic<float>    tube_mix{1.0f};       /* P-011: 湿比 [0, 1] */
    std::atomic<float>    tube_compensation{0.0f}; /* P-011: 输出补偿 dB [-12, 12] */
    std::atomic<int32_t>  tube_oversample{1};   /* 0=1x节能 1=2x高精抗混叠过采样 */
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
    /* 空间音效 L1（参数化 HRTF + 早期反射；Dolby 房默认，详见 dsp_spatial.cpp 头注） */
    std::atomic<int32_t>  spatial_enable{0};
    std::atomic<int32_t>  spatial_style{0};   /* 0=Dolby 房 1=DTS 定位 2=中性（下发即联动 room/width/center） */
    std::atomic<float>    spatial_room{0.7f};  /* [0,1] 早期反射电平+时间缩放 */
    std::atomic<float>    spatial_width{1.0f}; /* [0.5,1.5] 摆位张角缩放 */
    std::atomic<float>    spatial_center{0.8f};/* [0,1] 中置聚焦 */
    std::atomic<float>    spatial_outgain{0.0f}; /* dB [-12,6] */
    std::atomic<int32_t>  spatial_autogain{0};
    std::atomic<float>    spatial_mix{1.0f};       /* [0,1] 空间化干湿比 */
    std::atomic<float>    spatial_elevation{0.0f}; /* 度 [-30,30] 虚拟舞台高度 */
    std::atomic<int32_t>  spatial_binaural{0};     /* 1=6/8ch→2ch 双耳虚拟环绕 */
    std::atomic<int32_t>  spatial_fdn{0};          /* 1=FDN 晚期混响（替代 freeverb） */
    std::atomic<float>    spatial_late{0.25f};     /* [0,1] FDN 晚期送量 */
    /* 头跟踪：headazim 始终作为手动/外部朝向消费；headtrack 仅表示外部源
     * （OpenTrack UDP）是否开启，DSP 不区分来源。 */
    std::atomic<float>    spatial_headazim{0.0f}; /* 度 [-180,180] 头部偏航 */
    std::atomic<int32_t>  spatial_headtrack{0};  /* 0=关闭 1=跟随 */
    /* 激励器（HPF 取高频 + tanh 谐波混回；drive 固定，只暴露 amount/hifreq） */
    std::atomic<int32_t>  exciter_enable{0};
    std::atomic<float>    exciter_amount{0.3f};  /* [0,1] */
    std::atomic<float>    exciter_hifreq{5000.0f}; /* Hz [3000,10000] */
    std::atomic<int32_t>  exciter_oversample{1}; /* 0=1x节能 1=2x高精抗混叠过采样 */
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
    std::atomic<float>    gate_hysteresis{3.0f};  /* dB [0,12] 迟滞缓冲带 */
    std::atomic<float>    gate_range{-60.0f};     /* dB [-80,0] 关门衰减地板（P-4：对齐 Dart ParamDefaults.gateRange=-60） */
    std::atomic<float>    gate_hold_ms{10.0f};    /* ms [0,500] 跌落后保持时长 */
    std::atomic<int32_t>  gate_autogain{0};
    std::atomic<int32_t>  deesser_enable{0};
    std::atomic<float>    deesser_freq{6000.0f};  /* Hz [2000,10000] */
    std::atomic<float>    deesser_amount{0.5f};   /* [0,1] */
    /* 响度补偿（信号自适应等响度：静音段按简化 ISO226 补低+高） */
    std::atomic<int32_t>  loudness_enable{0};
    std::atomic<float>    loudness_amount{0.5f};  /* [0,1] */
    /* 心理声学低音（谐波合成；频带 = LP(cutoff) − LP(subfreq)） */
    std::atomic<float>    bass_harmonics{0.45f};  /* [0,1] 谐波量 */
    std::atomic<float>    bass_harmonicblend{0.5f}; /* [0,1] 谐波混合 */
    std::atomic<float>    bass_subfreq{25.0f};    /* Hz [10,40] 谐波下限 */
    std::atomic<float>    bass_cutoff_f{120.0f};  /* Hz [30,300] 谐波上限 */
    std::atomic<int32_t>  bass_oversample{1};     /* 0=1x节能 1=2x高精抗混叠过采样 */
    /* 独立滤波器（RBJ biquad：HP/LP/BP，链头 gate 之后） */
    std::atomic<int32_t>  filter_enable{0};
    std::atomic<int32_t>  filter_type{0};     /* 0=HP 1=LP 2=BP */
    std::atomic<float>    filter_freq{80.0f}; /* Hz [20,20000] */
    std::atomic<float>    filter_q{0.707f};   /* [0.3,10] */
    /* 全参数动态EQ（3 段：Low shelf / Mid bell / High shelf；pre-vendor 音色修整）。
     * 每段：静态 gain（常时）+ range/threshold（超阈后最大附加衰减）；各频段支持独立 attack/release。 */
    std::atomic<int32_t>  dyneq_enable{0};
    std::atomic<float>    dyneq_attack{2.0f};     /* ms [0.1,100] 全局广播 */
    std::atomic<float>    dyneq_release{120.0f};  /* ms [10,1000] 全局广播 */
    std::atomic<float>    dyneq_b1_attack{20.0f};   /* Low band [0.1, 100] */
    std::atomic<float>    dyneq_b1_release{120.0f}; /* Low band [10, 1000]（P-4：对齐 Dart ParamDefaults.dyneqB1Release=120） */
    std::atomic<float>    dyneq_b2_attack{10.0f};   /* Mid band [0.1, 100] */
    std::atomic<float>    dyneq_b2_release{100.0f}; /* Mid band [10, 1000] */
    std::atomic<float>    dyneq_b3_attack{2.0f};    /* High band [0.1, 100] */
    std::atomic<float>    dyneq_b3_release{120.0f}; /* High band [10, 1000]（P-4：对齐 Dart ParamDefaults.dyneqB3Release=120） */
    std::atomic<int32_t>  dyneq_l_enable{0};
    std::atomic<float>    dyneq_l_freq{120.0f};  /* Hz [20,500] */
    std::atomic<float>    dyneq_l_q{0.707f};     /* shelf 斜率 S [0.5,2] */
    std::atomic<float>    dyneq_l_gain{0.0f};    /* dB [-12,12] 静态 */
    std::atomic<float>    dyneq_l_range{6.0f};   /* dB [0,24] 最大动态衰减 */
    std::atomic<float>    dyneq_l_threshold{-30.0f}; /* dBFS [-60,0] */
    std::atomic<int32_t>  dyneq_m_enable{0};
    std::atomic<float>    dyneq_m_freq{1000.0f}; /* Hz [200,8000] */
    std::atomic<float>    dyneq_m_q{1.0f};       /* bell Q [0.3,10] */
    std::atomic<float>    dyneq_m_gain{0.0f};
    std::atomic<float>    dyneq_m_range{6.0f};
    std::atomic<float>    dyneq_m_threshold{-30.0f};
    std::atomic<int32_t>  dyneq_h_enable{0};
    std::atomic<float>    dyneq_h_freq{6000.0f}; /* Hz [2000,20000] */
    std::atomic<float>    dyneq_h_q{0.707f};
    std::atomic<float>    dyneq_h_gain{0.0f};
    std::atomic<float>    dyneq_h_range{6.0f};
    std::atomic<float>    dyneq_h_threshold{-30.0f};
    /* M5-c：参数化混响（Freeverb，T2 档） */
    std::atomic<int32_t>  fv_enable{0};
    std::atomic<float>    fv_decay{0.5f};       /* 0..1 → feedback 0.7..0.98 */
    std::atomic<float>    fv_damp{0.5f};        /* 0..1 */
    std::atomic<float>    fv_wet{0.35f};        /* 0..1（UI 为真，原 0.3） */
    std::atomic<float>    fv_dry{1.0f};         /* 0..1 */
    std::atomic<float>    fv_roomsize{1.2f};    /* 0.5..2.5（UI 为真，原 1.0；旧注释自相矛盾已删） */
    std::atomic<float>    fv_width{1.0f};       /* 0.2..2.0 wet 声 M/S 加宽 */
    /* 输入门控（钉死在链路最前端；全通道总增益 + 8通道单控平衡比例） */
    std::atomic<float>    input_gain{0.0f};     /* dB [-15,15] 默认 0.0 */
    std::atomic<float>    input_ch_gain[8];     /* 各声道单控比例 [0.0, 2.0]，默认 1.0 (100%) */
    /* 动态压限器（Compressor / FFTCompander） */
    std::atomic<int32_t>  comp_enable{0};
    std::atomic<float>    comp_timeconstant{0.14f};  /* 秒 [0.02, 0.5] */
    std::atomic<int32_t>  comp_granularity{1};       /* [0, 4] 频带颗粒度 */
    std::atomic<int32_t>  comp_tfresolution{1};      /* [0, 3] 时频模式: 1=标准, 3=Gammatone零延迟 */
    std::atomic<float>    comp_freq[7];              /* 7频段频率(Hz) [20, 20000] */
    std::atomic<float>    comp_gain[7];              /* 7频段压限数值 [-1.2, 1.2]，负=压缩，正=扩展 */
    /* 任意响应均衡器（ArbMag / AutoEq GraphicEQ） */
    std::atomic<int32_t>  arbmag_enable{0};
    std::atomic<int32_t>  arbmag_ready{0};
    std::atomic<int32_t>  arbmag_nodes{0};
    std::atomic<float>    arbmag_outgain{0.0f};
    std::atomic<int32_t>  arbmag_autogain{0};
    /* 多声道独立处理声道掩码 (Category A) */
    std::atomic<int32_t>  filter_channels{0xFF};
    std::atomic<int32_t>  shelf_channels{0xFF};
    std::atomic<int32_t>  eq_channels{0xFF};
    std::atomic<int32_t>  dyneq_channels{0xF7};
    std::atomic<int32_t>  tube_channels{0xFF};
    std::atomic<int32_t>  exciter_channels{0xF7};
    std::atomic<int32_t>  loudness_channels{0xFF};
    std::atomic<int32_t>  limiter_channels{0xFF};
    std::atomic<int32_t>  gate_channels{0xFF};
    std::atomic<int32_t>  comp_channels{0xFF};
    std::atomic<int32_t>  arbmag_channels{0xFF};
    /* Modern Lookahead Limiter 参数（P2.3 新增；向后兼容，不破坏 ABI） */
    std::atomic<float>    limiter_release_ms{100.0f}; /* ms [10, 500]：释放时间常数 */
    std::atomic<float>    limiter_threshold{-0.1f};    /* dBFS [-24, 0]：限幅门限（P-4：对齐 Dart ParamDefaults.limiterThreshold=-0.1；0 = 0dBFS 绝对防护为历史口径，不再作默认） */
    std::atomic<int32_t>  limiter_link{1};            /* 0=各声道独立限幅 1=全声道增益联动保持声像 */
    std::atomic<int32_t>  limiter_lookahead{0};       /* 0=0ms 实时零延迟模式 1=1.5ms 高精母带前瞻模式 */
};


/* ---- M5-c Freeverb（Schroeder-Moorer：8 comb + 4 allpass / 声道）----
 * 经典 tuning（@44.1k）按 fs 缩放；create 分配、destroy 释放，RT 零分配。
 * 参数换算沿用 classic freeverb：feedback = 0.7+decay*0.28，damp=damp*0.4。
 * 右声道施加 +23 采样点经典立体声扩展（Stereo Spread），产生自然空间去相关。 */
constexpr int kFvCombs = 8, kFvAllpasses = 4;
constexpr int kFvCombTuning[kFvCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
constexpr int kFvAllpTuning[kFvAllpasses] = {556, 441, 341, 225};
constexpr int kFvStereoSpread = 23;
// roomsize 预分配上限（× tuning）：运行时只改有效长度 combLen/apLen，绝不重
// 分配——RT 读到的永远是已分配区间的子集，无越界、无需等待、无需锁。
constexpr double kFvRoomMax = 2.5;
/* Freeverb 经典梳/全通长度标定在 44.1kHz（1116/556 等即该采样率下的采样数）。
 * 比例必须按**实际** fs 计算，不能写死 48/44.1 —— 写死意味着在 44.1k 或
 * 96k 设备上混响音调与衰减时间整体偏移（旧实现在非 48k 下必然失准）。 */
constexpr double kFvTuningRefRate = 44100.0;

struct FvVoice {
    float* combBuf[kFvCombs];
    int    combSize[kFvCombs];   // 分配长度（roomsize 上限，不变）
    int    combLen[kFvCombs];    // 有效长度（RT 读这个；控制线程改）
    int    combIdx[kFvCombs];
    float  filterstore[kFvCombs];   /* 8 个 comb 独立阻尼状态，杜绝互调串扰 */
    float  damp1 = 0, damp2 = 1;
    float* apBuf[kFvAllpasses];
    int    apSize[kFvAllpasses];  // 分配长度（不变）
    int    apLen[kFvAllpasses];   // 有效长度（RT 读这个）
    int    apIdx[kFvAllpasses];
};


/* 每样本：返回湿信号（Schroeder-Moorer 架构：8 并联 Comb 累加后串联 4 全通做扩散） */
inline float fv_voice_process(FvVoice& v, float in, float feedback) {
    float out = 0.0f;
    for (int i = 0; i < kFvCombs; ++i) {
        // 有效长度（控制线程改 roomsize 时写；读到新旧值都不越界，
        // 越界下标就地归零，无需锁）。
        const int len = v.combLen[i] > 0 ? v.combLen[i] : v.combSize[i];
        int idx = v.combIdx[i];
        if (idx >= len) idx = 0;
        const float y = v.combBuf[i][idx];
        v.filterstore[i] = y * v.damp2 + v.filterstore[i] * v.damp1;
        /* 截断次正常数 (subnormal float)，防止静音时 CPU 触发微码异常陷阱 */
        if (fabsf(v.filterstore[i]) < 1e-15f) v.filterstore[i] = 0.0f;
        v.combBuf[i][idx] = in + v.filterstore[i] * feedback;
        if (++idx >= len) idx = 0;
        v.combIdx[i] = idx;
        out += y;
    }
    /* 全通扩散层：以 Comb 累加输出为输入，逐级全通相位扩散 */
    for (int i = 0; i < kFvAllpasses; ++i) {
        const int len = v.apLen[i] > 0 ? v.apLen[i] : v.apSize[i];
        int idx = v.apIdx[i];
        if (idx >= len) idx = 0;
        const float bufout = v.apBuf[i][idx];
        const float input2 = out + bufout * 0.5f;
        v.apBuf[i][idx] = input2;
        if (++idx >= len) idx = 0;
        v.apIdx[i] = idx;
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
constexpr LatencyItem kLatSpatial  {1, 1.0f};  /* 直达径 ITD 最大 0.65ms 取整；
    * 早期反射/混响尾是并行能量不计入（与 reverb 30ms 名义口径一致） */
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
    /* 自研效果器实时本级输出线性峰值（RT 线程每块就地扫描，emit_viz 填入 stage_levels 对应槽位） */
    float  stage_peak_l[AURADSP_STAGE_MAX] = {};
    float  stage_peak_r[AURADSP_STAGE_MAX] = {};

    /* Liveprog 状态 */
    float* lp_slider_ptr[8] = {};     /* slider1..8 的 VM 寄存器指针（代码加载后刷新） */
    int    lp_status = 0;             /* 0=无代码 1=编译成功 <0=LiveProgStringParser 错误码 */
    char*  lp_code = nullptr;         /* 已下发代码副本（get_param 回读用） */
    size_t lp_code_len = 0;
    /* 字符串回读副本（预设 §8.1 / 调研 §1：存原始串而非重序列化，避免格式漂移；析构释放） */
    char*  eq_curve = nullptr;        /* 已下发 eq.curve 原串副本（get_param 回读用） */
    size_t eq_curve_len = 0;
    char*  arbmag_string = nullptr;   /* 已下发 arbmag.string 原串副本（get_param 回读用） */
    size_t arbmag_string_len = 0;

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
    float  fv_g_sm = 1.0f;     /* 混响输出总增益一阶平滑状态（2ms 时间常数） */

    /* M5-b：低频搁架 biquad（系数原子写防撕裂；状态仅 RT 线程触碰；支持 8 声道） */
    struct ShelfBiquad {
        std::atomic<double> b0{1}, b1{0}, b2{0}, a1{0}, a2{1};
        double z1[kMxMaxChannels] = {};
        double z2[kMxMaxChannels] = {};
    } shelf;
    /* 独立滤波器 biquad（同 shelf 模式：控制线程重算系数，RT 只读；支持 8 声道） */
    struct FilterBiquad {
        std::atomic<double> b0{1}, b1{0}, b2{0}, a1{0}, a2{1};
        double z1[kMxMaxChannels] = {};
        double z2[kMxMaxChannels] = {};
    } filter;
    /* B5 后续：arbmag 逐声道池（8×FFTConvolver1x1，IR 与主 arbMag.conv 同源）。
     * 生命周期：句柄级 new[]/delete[]（create 分配、destroy 释放，RT 零分配）；
     * 内容：控制线程在 set_arbmag_string 生效路径重建/重载（带上 blockSize；
     * 注意 jdsp 块长重分配的 Refresh 钩子只刷新主 conv，池另行同步见
     * arbmag_pool_reload）；RT 线程只读指针，无跨线程释放。 */
    struct ArbmagPool {
        FFTConvolver1x1* conv[kMxMaxChannels] = {};
        unsigned int     loaded_block = 0;  /* 上次成功 Load/Refresh 的 blockSize */
        int              loaded = 0;        /* IR 是否已装载（0=空池，直通） */
    } arbmag_pool;
    /* BassMono one-pole 状态（RT 独占；系数值每块现算，天然跟随 rate/freq） */
    float bm_lp_l = 0.0f, bm_lp_r = 0.0f;
    /* 噪声门/Deesser 状态（RT 独占；支持 8 声道） */
    float gate_gain[kMxMaxChannels] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
    float gate_state[kMxMaxChannels] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
    int   gate_hold_cnt[kMxMaxChannels] = {};
    float gate_env[kMxMaxChannels] = {};
    float gate_ds_lp[kMxMaxChannels] = {};
    float gate_ds_env[kMxMaxChannels] = {};
    double gate_ag_in = 0.0, gate_ag_out = 0.0, gate_ag_comp = 1.0;
    float  gate_ag_g_sm = 1.0f; /* 门控自动增益补偿一阶平滑状态（2ms 时间常数） */
    /* 全参数动态EQ状态（RT 独占；系数每块现算，无原子系数表；支持 8 声道）。
     * 检波：单声道侧链 bell + 峰值包络；
     * 施加：串联 bell/shelf（DF2T 8 声道独立状态）。 */
    struct DyneqBand {
        double det_z1[kMxMaxChannels] = {};
        double det_z2[kMxMaxChannels] = {};
        double env[kMxMaxChannels] = {};
        double z1[kMxMaxChannels] = {};
        double z2[kMxMaxChannels] = {};
    } dyneq_b[3];
    /* 心理声学低音 one-pole 状态（RT 独占；系数值每块现算） */
    float psy_lp_l = 0.0f, psy_lp_r = 0.0f;   /* cutoff LP */
    float psy_sub_l = 0.0f, psy_sub_r = 0.0f; /* subfreq LP */
    /* 响度补偿状态（RT 独占；支持 8 声道） */
    float loud_lp[kMxMaxChannels] = {};
    float loud_hp[kMxMaxChannels] = {};
    double loud_level = 0.0;                      /* 慢速电平跟随（~0.5s） */
    /* Modern Lookahead Limiter 状态（RT 独占；P2.3）
     * 前瞻环形缓冲：每声道 kLimLookaheadMax 样本（上限 3ms @ 192kHz = 576 采样点）
     * 存储延迟音频，同时在环上维护前向极小增益包络 */
    static constexpr int kLimLookaheadMax = 576; // ceil(0.003 * 192000)
    float mc_limiter_la_buf[kMxMaxChannels][kLimLookaheadMax] = {};   /* 前瞻音频延迟线 */
    float mc_limiter_gain_buf[kMxMaxChannels][kLimLookaheadMax] = {}; /* 前瞻增益延迟线 */
    float mc_limiter_la_env[kMxMaxChannels] = {};  /* 起音平滑包络（初始 = 1.0f 满增益 = 未压限） */
    int   mc_limiter_la_pos[kMxMaxChannels] = {};  /* 前瞻环读写指针 */
    int   mc_limiter_la_len = 72;  /* 实际使用长度（create/init 时按 fs 计算，默认 72@48k） */
    /* PF-2：LA 前瞻增益环形窗口最小值（单调 deque）。原实现每样本对
     * gain_buf 全窗 O(la_len) 扫描（8ch LA ≈576 iters/帧），这里换成
     * 摊销 O(1) 的滑动窗口最小：dq 存 gain_buf 的环形位置，所指引值
     * 从头到尾单调非降，队首即窗口最小。la_len 变化时整体重置。 */
    int   mc_limiter_dq[kMxMaxChannels][kLimLookaheadMax] = {};
    int   mc_limiter_dq_head[kMxMaxChannels] = {};
    int   mc_limiter_dq_count[kMxMaxChannels] = {};
    int   mc_limiter_dq_len = 0;  /* deque 生效的 la_len；不等即失效重置 */
    /* 释放包络平滑增益（每声道；初始 1.0 = 无压限） */
    float mc_limiter_env[kMxMaxChannels] = {};
    /* 历史输入样本，用于 4x ISP Cubic Hermite 插值（每声道保留上 2 个样本） */
    float mc_limiter_prev[kMxMaxChannels][2] = {};
    /* GR 计量（Gain Reduction）原子变量：每块更新，UI 线程读取（dB，恒 >= 0） */
    std::atomic<float> gr_limiter{0.0f};
    std::atomic<float> gr_comp{0.0f};
    std::atomic<float> gr_gate{0.0f};
    std::atomic<float> gr_dyneq[3] = {};
    /* Haas 右声道延迟环（RT 独占；create 时按 25ms 上限分配并清零） */
    float* haas_ring = nullptr;
    int    haas_ring_len = 0;
    int    haas_pos = 0;
    /* 空间音效 RT 状态（全固定数组，handle 随体分配，RT 零分配） */
    static constexpr int kSpatSpk = 8;      // 立体声 5 + 多声道 8 的上限
    static constexpr int kSpatItdLen = 256; // 远耳 ITD 线（0.8ms@192k=154 < 256）
    static constexpr int kSpatHistLen = 32768; // 早期反射历史（110ms@192k=21120 < 32768）
    float  spat_ring[kSpatSpk][kSpatItdLen]; // 各扬声器远耳延迟线（mono）
    int    spat_ring_pos[kSpatSpk];
    float  spat_lp[kSpatSpk];             // 各扬声器远耳头影低通状态
    float  spat_hist[kSpatHistLen];       // 早期反射历史（输入 mono 下混）
    int    spat_hist_pos = 0;
    float  spat_pinna[2][2][4];           // [stage][ch] 反射总线 pinna 双 biquad
    float  spat_src_pinna[kSpatSpk][2][2][4]; // [源][耳][stage] 方向 pinna 状态
    /* B3b：早期反射 L/R 全通扩散器（2 耳 × 2 级；4.1ms@192k=788 < 1024） */
    static constexpr int kSpatApMax = 1024;
    float  spat_ap_buf[2][2][kSpatApMax]; // [耳][级] 全通延迟线
    int    spat_ap_pos[2][2];             // [耳][级] 写指针
    float  spat_lfe_lp = 0.0f;            // LFE 120Hz 低通状态
    /* FDN 晚期混响（8 线 Hadamard；固定上限，reset 时按 fs 设长度） */
    static constexpr int kFdnLines = 8;
    static constexpr int kFdnMax = 16384;
    float  fdn_buf[kFdnLines][kFdnMax];
    int    fdn_pos[kFdnLines];
    int    fdn_len[kFdnLines];
    float  fdn_lp[kFdnLines];
    float  fdn_fb[kFdnLines];
    float  fdn_damp = 0.0f;
    float  fdn_room_last = -1.0f;
    double spat_ag_in = 0.0, spat_ag_out = 0.0, spat_ag_comp = 1.0; // 自动增益跟随
    float  spat_g_sm = 1.0f;    /* 空间音效输出增益一阶平滑状态（2ms 时间常数） */
    float  spat_mix_sm = 1.0f;  /* 空间化干湿比平滑状态（2ms 时间常数） */
    float  spat_headazim_sm = 0.0f; /* 头跟踪方位角块级平滑状态（~15ms） */
    /* 激励器 one-pole HP 状态（RT 独占；系数值每块现算；支持 8 声道） */
    float exc_lp[kMxMaxChannels] = {};
    /* 2x 多相半带过采样器实例（RT 独占，静态预分配零分配） */
    auradsp::HalfbandOversampler2x exc_os[kMxMaxChannels];
    auradsp::HalfbandOversampler2x tube_os[kMxMaxChannels];
    auradsp::HalfbandOversampler2x psycho_os[2];

    float* shelf_scratch = nullptr;   /* max_block*2，vendor 链前置处理用 */
    float* conv_scratch = nullptr;    /* max_block*2，卷积干湿比（P-005）用 */

    /* M1 插件宿主引擎与双声道平面工作区 */
    std::unique_ptr<auradsp::PluginHostManager> plugin_host;
    float* plugin_buf_l = nullptr;
    float* plugin_buf_r = nullptr;
    float* plugin_out_l = nullptr;
    float* plugin_out_r = nullptr;

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
void dyneq_process(auradsp_handle h, float* io, int frames);
void emit_viz(auradsp_handle h);
void exciter_process(auradsp_handle h, float* io, int frames);
void filter_process(auradsp_handle h, float* io, int frames);
void filter_recalc(auradsp_handle h);
void fv_alloc(FvVoice& v, double sampleRate, int spread);
void fv_free(FvVoice& v);
// 控制线程：按 room 缩放重算有效长度 + 清缓冲（RT 侧只读 Len/Buf，无需停泵；
// 并发瞬间最多一个 click 级伪影，无崩溃可能）。spread 与 alloc 时一致。
void fv_retune(struct auradsp_handle_s* h, double room);
void gate_process(auradsp_handle h, float* io, int frames);
void haas_process(auradsp_handle h, float* io, int frames);
auradsp_status load_ir_file(auradsp_handle h, const char* path);
void loudness_process(auradsp_handle h, float* io, int frames);
void lp_refresh_sliders(auradsp_handle h);
bool mx_downmix(auradsp_handle h, const float* in, float* stereo, int frames, int ch);
void mx_upmix(auradsp_handle h, float* out, const float* stereo, int frames, int ch);
void process_stereo_chain(auradsp_handle h, const float* src, float* dst,
                          int frames, bool skip_spatial = false);
char* read_text_file(auradsp_handle h, const char* path, long max_bytes, auradsp_status* st);
void rebuild_hann(auradsp_handle h, int n);
void shelf_process(auradsp_handle h, float* io, int frames);
void shelf_recalc(auradsp_handle h);
void spatial_reset(auradsp_handle h);
void spatial_process(auradsp_handle h, float* io, int frames);
void spatial_binaural_process(auradsp_handle h, const float* in, float* stereo,
                              int frames, int ch);
void viz_write(auradsp_handle h, const float* out, int frames);
void viz_write_eq_in(auradsp_handle h, const float* src, int frames);
void gate_process_mc(auradsp_handle h, float* io, int frames, int ch);
void filter_process_mc(auradsp_handle h, float* io, int frames, int ch);
void shelf_process_mc(auradsp_handle h, float* io, int frames, int ch);
void dyneq_process_mc(auradsp_handle h, float* io, int frames, int ch);
void tube_process_mc(auradsp_handle h, float* io, int frames, int ch);
void exciter_process_mc(auradsp_handle h, float* io, int frames, int ch);
void loudness_process_mc(auradsp_handle h, float* io, int frames, int ch);
void limiter_process_mc(auradsp_handle h, float* io, int frames, int ch);
/* B5 后续：arbmag 逐声道池（控制线程建/载/释，RT 只读）。
 * IR 与主 arbMag.conv 同源（GetFilter 同一份 eqFil）；loaded 为 0 时直通。
 * process_strided：处理交织缓冲中任一单声道（mask 位=1 且 enable/ready/loaded
 * 才生效，否则原样直通）；mono 连续化用 h->shelf_scratch 前 frames 个 float，
 * 调用方须保证该 scratch 当前空闲（Category B 段1 与 3b 段用法均满足）。 */
void arbmag_pool_alloc(auradsp_handle h);
void arbmag_pool_free(auradsp_handle h);
void arbmag_pool_reload(auradsp_handle h);
void arbmag_pool_process_strided(auradsp_handle h, float* io, int frames,
                                 int nch, int ch_idx);
void process_multichannel_chain(auradsp_handle h, const float* src, float* dst, int frames, int ch);

