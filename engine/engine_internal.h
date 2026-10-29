/* Shared engine internals (P2 split; Phase 3 plugin state moved to PluginEngineState). */

#pragma once

#include "auradsp_engine.h"
#include "plugins/integration/plugin_engine_state.h"
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
/* ABI v2（2026-10-24，Phase B 多声道电平）：auradsp_viz_frame 尾部追加
 * channel_count + channel_levels[8] + stage_ch_levels[32][8]（536B→1596B）。
 * 追加式布局保旧读者兼容，但 Dart Struct 定长读必须同版本——加载时
 * auradsp_abi() 强校验（见 auradsp_ffi.dart）。 */
#define AURADSP_ABI 2

/* ABI 版本与帧尺寸联动哨兵：改 auradsp_viz_frame 尺寸必须同步升 ABI 号，
 * 否则 Dart 侧 kExpectedAbi 校验会放行错位绑定（定长 Struct 全字段静默错位）。
 * 放在 engine_internal.h 而非公共头：此处 ABI 宏与结构体定义同时可见。 */
static_assert(AURADSP_ABI == 2 && sizeof(auradsp_viz_frame) == 1600,
              "AURADSP_ABI version and auradsp_viz_frame size must bump together");

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

/* [WP8 M-8/M-11] 8 声道位掩码与音箱布局定义（SpeakerLayout / layout_for / kChMask*） */
#include "chain/speaker_layout.h"

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
    /* WP0 脚手架（多声道重构 2026-10-25）：混响边界参数。默认保持旧行为，
     * WP1/WP2 才消费；reverb.engine 是只读诊断参数（见 engine_param_table.h）。 */
    std::atomic<float>    reverb_predelay{0.0f}; /* ms [0,100] */
    std::atomic<int32_t>  reverb_lfe{0};         /* 1=LFE 入 MC FDN（120Hz LP + -6dB） */
    std::atomic<float>    stereo_mix{0.5f};     /* [0,1] 中性档 0.5（C3 统一单源，2026-10-19） */
    /* 2026-10-16 口径决策：UI 为真。以下默认值必须与 Dart ParamDefaults
     * （app/auradsp_app/lib/core/state.dart L64-171）逐项一致，改动需同步两侧
     * 并跑 flutter test（D1 监察）+ smoke。 */
    std::atomic<int32_t>  stereo_enable{0};   /* 默认关（UI 为真，原 1） */
    std::atomic<int32_t>  eq_enable{0};
    std::atomic<int32_t>  limiter_enable{1};  /* 默认开（UI 为真，原 0） */
    std::atomic<float>    post_gain{0.0f};      /* dB [-15,15] */
    /* WP0 脚手架：逐声道输出补偿（dB，[-15,15]，默认 0）。WP5 消费；
     * c0..c7 对应 FL/FR/C/LFE/SL/SR/BL/BR。 */
    std::atomic<float>    post_gain_ch[8];
    /* latency_mode 已由 ADR-006 移除：延迟改为纯测量，不再有档位准入。 */
    std::atomic<int32_t>  channels_mode{0};     /* 0=stereo（Phase A，ADR-003） */
    /* WP0 脚手架：channels.count 的纯状态载体（0=自动/1=手动，同 bass.mode
     * 模式，不参与 DSP 计算，仅保证 UI 选择可回读）。 */
    std::atomic<int32_t>  channels_count_mode{0};
    /* Liveprog（EEL2 实时可编程 DSP；vendor 补丁 P-001 提供 slider1..8） */
    std::atomic<int32_t>  lp_enable{0};
    std::atomic<float>    lp_param[64];         /* slider1..64（C++20 值初始化 = 0） */
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
    /* WP0 脚手架：标准四对多选（bit0=FL/FR bit1=C/LFE bit2=SL/SR
     * bit3=BL/BR，默认仅 FL/FR）。每对独立平均；merge=1 时再全局合并。
     * WP4 消费，本阶段只存值。 */
    std::atomic<int32_t>  bassmono_pairs{0x01};
    std::atomic<int32_t>  bassmono_merge{0};
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
    std::atomic<int32_t>  spatial_fdn{0};          /* deprecated（WP1 移除）：旧会话写别名 */
    std::atomic<float>    spatial_late{0.25f};     /* deprecated（WP1 移除）：旧会话写别名 */
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
     * reverb 落 vendor fx 槽 5（立体声路径）/ MC FDN（离散多声道）。 */
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
    /* [PATCHED-AuraDSP P-032] ViPER 三模式（0=自然低音 1=纯净低音 2=超重低音）
     * 是**UI 侧谐波配方宏**（setBassMode 写 bass.harmonics/harmonicblend），
     * 引擎侧此前没有对应参数 → 回读 getIntNullable('bass.mode') 恒为 null，
     * isolate 兜底成 0 后无条件覆盖 UI → 用户选任何模式都被弹回"自然低音"。
     * 这里补一个纯状态载体参数：让回读返回用户真实选择（值域 0..2），
     * 不参与任何 DSP 计算。 */
    std::atomic<int32_t>  bass_mode{0};
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
    /* M5-c：混响自定义参数（freeverb.* 为 ABI 兼容名；
     * 立体声路径映射 vendor Progenitor2，离散多声道路径驱动 MC FDN）。 */
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
    /* 多声道独立处理声道掩码 (Category A)
     * 初始默认：dyneq/exciter = kChMaskNoLfe (0xF7，排除 LFE)，其余 = kChMaskAll (0xFF)。
     * X-6（2026-10-26 修复）：channels.count 切换时 dyneq/exciter 的默认掩码随布局
     * 平移（ch_mask_no_lfe_for：2/8ch→0xF7、4ch→0x0F、6ch→0x37），仅当仍为旧布局
     * 默认值才改写，用户自定义掩码保留；其余效果 0xFF 在所有布局下均含全部有效声道，
     * 无需平移。 */
    std::atomic<int32_t>  filter_channels{(int32_t)kChMaskAll};
    std::atomic<int32_t>  shelf_channels{(int32_t)kChMaskAll};
    std::atomic<int32_t>  eq_channels{(int32_t)kChMaskAll};
    std::atomic<int32_t>  dyneq_channels{(int32_t)kChMaskNoLfe};
    std::atomic<int32_t>  tube_channels{(int32_t)kChMaskAll};
    std::atomic<int32_t>  exciter_channels{(int32_t)kChMaskNoLfe};
    std::atomic<int32_t>  loudness_channels{(int32_t)kChMaskAll};
    std::atomic<int32_t>  limiter_channels{(int32_t)kChMaskAll};
    std::atomic<int32_t>  gate_channels{(int32_t)kChMaskAll};
    std::atomic<int32_t>  comp_channels{(int32_t)kChMaskAll};
    /* WP0 脚手架：comp 逐对/逐声道模式（0=逐声道 8 实例，1=逐对降级）。
     * WP3 消费；本阶段只存值。 */
    std::atomic<int32_t>  comp_mode{0};
    std::atomic<int32_t>  arbmag_channels{(int32_t)kChMaskAll};
    /* Modern Lookahead Limiter 参数（P2.3 新增；向后兼容，不破坏 ABI） */
    std::atomic<float>    limiter_release_ms{100.0f}; /* ms [10, 500]：释放时间常数 */
    std::atomic<float>    limiter_threshold{-0.1f};    /* dBFS [-24, 0]：限幅门限（P-4：对齐 Dart ParamDefaults.limiterThreshold=-0.1；0 = 0dBFS 绝对防护为历史口径，不再作默认） */
    std::atomic<int32_t>  limiter_link{1};            /* 0=各声道独立限幅 1=全声道增益联动保持声像 */
    std::atomic<int32_t>  limiter_lookahead{0};       /* 0=0ms 实时零延迟模式 1=1.5ms 高精母带前瞻模式 */
};


/* ---- WP1：离散多声道 FDN 混响 ------------------------------------------
 * 8 条延迟线 + 8x8 Hadamard 反馈 + N×8 输入 / 8×N 输出矩阵。
 * 只在 channels.mode==1 且非双耳路径运行；立体声/矩阵/双耳路径使用 vendor
 * Progenitor2。自研 Freeverb 已于 WP1 退役，freeverb.* 仅作为自定义参数名
 * （ABI 兼容）保留。
 *
 * 内存：8×32768×4 ≈ 1.0MB + 8 路预延迟 8×19200×4 ≈ 0.6MB。
 * 预延迟按声道独立（不是文档 §3.3 的“单环”估算），因为输入矩阵需要保留
 * 每声道的独立内容；多出的 ~0.5MB 仍在 §6 的每 handle 预算内。
 */
struct McReverbState {
    static constexpr int kLines = 8;
    /* 170.6ms @192k；roomScale 上限 2.0 时最长 147.8ms，留 1 帧守卫。 */
    static constexpr int kMax = 32768;
    /* 100ms @192k。 */
    static constexpr int kPreMax = 19200;

    float buf[kLines][kMax] = {};
    int   pos[kLines] = {};
    int   len[kLines] = {};       /* 当前有效长度（按 roomScale 缩放，不重分配） */
    float lp[kLines] = {};        /* 每线一阶阻尼状态 */
    float fb[kLines] = {};        /* 每线反馈增益 */
    float damp = 0.0f;            /* 每线阻尼系数（每块算一次） */
    float rt60 = 2.5f;
    float room_scale = 1.0f;

    /* 每声道预延迟（同一长度；读指针共享，写指针每声道独立）。 */
    float pre_buf[kLines][kPreMax] = {};
    int   pre_pos = 0;
    float pre_len_sm = 0.0f;      /* 平滑后的延迟样本数（支持分数延迟） */
    bool  pre_init = false;       /* reset 后首块直接对齐目标，避免从 0 扫过去 */

    /* LFE 入/出 120Hz 一阶低通状态（只有 6/8ch 且 reverb.lfe=1 时使用）。 */
    float lfe_in_lp = 0.0f;
    float lfe_out_lp = 0.0f;

    /* 重置请求（控制线程写、RT 线程消费）。直接清 1MB 延迟线会让湿声
     * 瞬间归零形成爆音；RT 侧先做 5ms 湿声淡出，再清状态。 */
    std::atomic<int32_t> reset_req{0};
    float fade = 1.0f;            /* 湿声淡出系数（1=正常，0=静音） */
    bool  fading_out = false;
};

/* 各效果引入的近似附加延迟。
 * ADR-006：延迟档硬约束已撤销，本表只用于「如实测量并上报」，
 * 不参与任何准入判定（kTierBudget / over_guard 一并删除）。
 * tier 字段保留为文档性标注，供 graph.effects 输出与 UI 排障参考。
 *
 * D1（2026-10-24）：本表原来是"一律存 ms"，但其中至少两项的**物理量其实是
 * 帧数**，只在 48k 成立。故拆成两个字段：frames > 0 表示结构性帧数延迟，
 * frames == 0 表示名义毫秒值（与采样率无关的听感标注）。换算统一走
 * LatencyMs()，禁止在调用点手写 `/1000`。
 *
 * D7（2026-10-24）：D1 的两条前提都不对，一并纠正——
 *   ① **帧数所属的采样率域是工作域 jdsp->fs，不是设备采样率**。引擎在非常见
 *      采样率（96k/192k/88.2k…）下先 ASRC 到 48k/44.1k 再跑 DSP
 *      （JamesDSPInit：enableASRC=1、fs=48000），所有结构性帧数（comp 的
 *      重叠相加、arbmag 的块卷积）都活在**48k 域**。D1 用 h->sample_rate
 *      （设备率）换算，96k 下把 74.67ms 报成 42.67ms —— 方向和"修前写死
 *      85ms"正好相反，等于换了个错法。实测佐证：96k/blk=1024 的脉冲位移
 *      是 7168 帧 = 2×3584，与 48k/blk=512 的 3584 帧**同为 74.67ms**。
 *   ② **comp 不是固定 4096 帧**。FFTCompander 的延迟 = fftLen − ovpLen，
 *      随 tfresolution 变（脉冲响应法实测，48k/96k/192k 三种设备率结果一致，
 *      均为工作域帧数）：
 *        tf=0 STFT   (2048/256) → 1792 帧（48k 37.33ms）
 *        tf=1 CWT    (4096/512) → 3584 帧（48k 74.67ms）  ← 出厂默认
 *        tf=2 CWT↔STFT(4096/512)→ 2048 帧（48k 42.67ms）
 *        tf=3 Gammatone 时域    → 0 帧（无 STFT）
 *      4096 是 FFTSIZE_DRS/2，从来不是运行时延迟量。故 comp 移出本表，
 *      改按 kCompLatProfile[tf] 查表（见下）。
 * 换算统一走 LatencyMs()，禁止在调用点手写 `/1000`。 */
struct LatencyItem {
    int tier;
    int frames;  /* 结构性延迟帧数，**工作采样率域**（jdsp->fs）；0 = 用 ms 字段 */
    float ms;    /* 名义毫秒值（frames == 0 时生效；与采样率无关的听感标注） */
};
constexpr LatencyItem kLatReverb   {2, 0, 30.0f};
constexpr LatencyItem kLatConvolver{2, 0, 10.0f};    /* 保守下限，IR 长度另计 */
/* arbmag 刻意**不进本表**：它的附加延迟是"单块帧数"（分块 FFT 卷积按
 * jdsp->blockSize 加载 IR），随驱动块长变，写任何常量都是错的——原表的
 * 2.67ms 只是「128 帧 @48k」的巧合值，1024 帧块下低估 8 倍。由 compute_latency
 * 直接按块长换算。表里留一条"定义却不用"的占位比缺失更危险。
 * comp 同理进不了本表，见 kCompLatProfile。 */
constexpr LatencyItem kLatCrossfeed{1, 0, 3.0f};
constexpr LatencyItem kLatSpatial  {1, 0, 1.0f};  /* 直达径 ITD 最大 0.65ms 取整；
    * 早期反射/混响尾是并行能量不计入（与 reverb 30ms 名义口径一致） */
constexpr LatencyItem kLatDdc      {1, 0, 6.0f};
/* limiter 刻意**不进本表**（D7）：它有两种模式，延迟差 1.5ms ——
 *   · limiter.lookahead == 0（**出厂默认**）：0ms 实时零延迟模式，不加任何
 *     环形缓冲，实测脉冲位移 0 帧；
 *   · limiter.lookahead == 1：前瞻环形缓冲，延迟线实占 la_len-1 帧，
 *     la_len = int(1.5ms × fs + 0.5)（上限 kLimLookaheadMax=576）。
 * 故时间恒 ≈1.5ms、与采样率无关（实测 48k 71 帧 = 1.479ms、44.1k 65 帧
 * = 1.474ms，均为 la_len-1）。
 * 原表写死 `{0, 0, 2.0f}` 名义值：默认配置下**高估 2ms**（真实 0ms），
 * 开前瞻时低估 0.5ms —— 两种模式都错，且"恒定 2ms"这个性质本身不存在。 */

/* FFTCompander 的 STFT 结构延迟剖面（D7 实测标定，B1-d 修正块长口径）。
 *
 * ovpLen = fftLen / ovpCount 是 hop（每攒满这么多样本才产出一块输出）。
 *     实测推翻过一版结论：ovpLen **不是**「攒不满就整块直通、延迟为 0」的门槛。
 *     把脉冲放到第 50 块之后测，48k/blk=256 位移 3840 帧、blk=512 位移 3584 帧
 *     ——块小不但不直通，反而**多**出一点延迟。旧断言之所以判"0ms"，是因为
 *     脉冲放在第 8 帧（首块内），测到的是首个 hop 的启动段。
 *
 * 真实口径：延迟 = frames + D，D = CompressorStartupDeficit(ovpLen, workBlk)
 *     = ovpLen - gcd(ovpLen, workBlk)（workBlk 是完整工作域块长，不裁到 hop）。
 *     · 块长整除 hop（512/1024/2048）→ D = 0，延迟 = fftLen-ovpLen；
 *     · 否则 D > 0（256→256、128→384、480→480、441→511），是 hop 与块长
 *       相位不齐导致管线必须永久落后的量，实测与模型逐块一致。
 *     B1-d 之前这段落后表现为**原声直通**（未处理的输入留在输出里）且周期性
 *     复发；B1-d 之后改为启动时以静音交付，延迟因此确定可测。
 * 实测例（tf=1）：48k/blk=256 → 3840 帧 = 80.00ms；48k/blk=512 → 3584 帧
 *     = 74.67ms；96k/blk=1024（ASRC 后工作块 512）→ 7168 设备域帧 = 3584 工作域帧。 */
struct CompLatencyProfile {
    int tf;
    int fftLen;
    int ovpLen;   /* 0 = 时域路径，无 STFT */
    int frames;   /* 工作域帧数 = fftLen - ovpLen，不含启动缺额 D */
};
constexpr CompLatencyProfile kCompLatProfile[4] = {
    {0, 2048, 256, 1792},   /* STFT */
    {1, 4096, 512, 3584},   /* CWT（默认） */
    {2, 4096, 512, 2048},   /* CWT ↔ STFT 反变换 */
    {3,    0,   0,    0},   /* Gammatone 时域多带 */
};

/* ASRC 附加延迟（D7）。
 *
 * 实测（脉冲响应法 + 三点抛物线亚样本插值）：96k −0.0064ms、192k −0.0278ms、
 * 88.2k −0.0071ms —— 多相 FIR 的群延迟被重采样的相位对齐抵消到测量噪声内。
 * 真实存在且可解释的是中转环形缓冲的结构量
 * IntegerASRCHandler.calculatedLatencyWholeSystem = ceil(inFs / fs) 个**输入域**
 * 样本（DoASRC_bwd 用 RingBufferingStereo 攒够才吐一块）：96k→48k = 2 帧
 * = 0.0208ms。这里如实计入这 0.02ms，不用"可忽略"糊过去；多相 FIR 部分
 * 实测为负（轻微提前），按 0 计。 */

/* 帧数 → 毫秒。采样率未初始化（<=0）时按 48k 名义口径兜底，绝不返回 inf/负值。 */
inline double FramesToMs(double frames, double sample_rate) {
    if (!(sample_rate > 0.0)) sample_rate = 48000.0;
    return frames * 1000.0 / sample_rate;
}

/* 取一项延迟的毫秒值（frames 优先，否则用名义 ms）。 */
inline double LatencyMs(const LatencyItem& it, double sample_rate) {
    if (it.frames > 0) return FramesToMs((double)it.frames, sample_rate);
    return (double)it.ms;
}

/* ASRC 中转环形缓冲的附加延迟（D7）。帧数与采样率同为**输入域**，故直接用
 * 输入域采样率换算。见上方 ASRC 注释块。 */
inline double AsrcRingLatencyMs(double in_fs, double work_fs) {
    if (!(in_fs > 0.0) || !(work_fs > 0.0)) return 0.0;
    const double ring_frames = std::ceil(in_fs / work_fs);
    return FramesToMs(ring_frames, in_fs);
}


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
    std::atomic<int> viz_interval{1600};             /* 产出间隔（帧）= fs/30，约 33ms */
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
    /* [Phase B 多声道电平] per-stage per-channel 线性峰值（RT 线程每块扫描）。
     * 与 stage_peak_l/r 的关系：stereo 路径只写 l/r（逐位不变）；MC 路径由
     * sample_stage_peak_mc 同时写两组（l/r 列取 ch0/ch1，修复 MC 下
     * stage_levels 遥测 stale）。stage 语义同 stage_levels_* 槽位表。 */
    float  stage_peak_ch[AURADSP_STAGE_MAX][AURADSP_CH_MAX] = {};
    /* 最终输出（auradsp_process 的 out 缓冲）per-channel 线性峰值，
     * 由 viz_write 按块 stride 同一趟扫描记录（stereo 时 [0]/[1] 与
     * viz_lvl_l/r 同源）。emit_viz 转 dBFS 填 channel_levels。 */
    float  ch_out_peak[AURADSP_CH_MAX] = {};
    /* RT 线程每块记录的声道数（2/6/8），emit_viz 填 channel_count；0=尚无块。 */
    int    last_block_ch = 0;
    /* [P2 静音门控] 输入连续静音 ≥ hold 且本链输出残余 < -120 dBFS 时，
     * 跳过整条效果链、直出零（省 CPU/降功耗）；输入一旦有信号当块退出，
     * 无淡入淡出。仅 RT 线程读写；AURADSP_GATE=0 关闭，AURADSP_GATE_DB
     * 覆盖阈值（默认 -90 dBFS）。 */
    bool   gate_enabled = true;
    bool   gate_active = false;
    int    gate_silent_frames = 0;   /* 连续静音帧数（封顶 hold，防溢出） */
    int    gate_hold_frames = 0;     /* = 2000ms × fs（create 时按实际 fs 定） */
    float  gate_peak_thresh = 3.16227766e-5f; /* -90 dBFS 线性 */
    float  gate_resid_thresh = 1e-6f;         /* -120 dBFS 线性 */
    int    gate_idle_frames = 0;     /* gated 连续帧数（诊断/桥侧读数） */

    /* [Phase B] stage 级 per-channel 电平的**有效列数**（emit_viz 用它门控
     * stage_ch_levels 的 c 循环）。语义：最近一次跑过的链能提供 per-channel
     * stage 数据的声道数——
     *   process_multichannel_chain 入口置 ch（离散 MC 链，全声道逐级处理）；
     *   process_stereo_chain 入口置 2（矩阵/双耳/stereo 走的都是立体声链，
     *   stage 级只有 L/R 两列有意义）。
     * 必须与 last_block_ch 分开：矩阵模式下设备是 6/8 声道（last_block_ch=8，
     * channel_levels 经 mx_upmix 后全列有效），但 stage 链是立体声，若沿用
     * last_block_ch 门控就会读到上一次 MC 模式的陈旧 stage_peak_ch。 */
    int    stage_ch_active = 2;

    /* Liveprog 状态 */
    float* lp_slider_ptr[64] = {};    /* slider1..64 的 VM 寄存器指针（代码加载后刷新） */
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

    /* WP1：离散多声道 FDN 混响（RT 独占；结构体内静态分配，无堆分配） */
    McReverbState mc_rev;
    /* 混响自动增益补偿平滑状态（RT 独占；vendor 与 MC FDN 共用） */
    double rev_ag_in = 0.0, rev_ag_out = 0.0, rev_ag_comp = 1.0;
    float  rev_g_sm = 1.0f;    /* 混响输出总增益一阶平滑状态（2ms 时间常数） */

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
        int              loaded = 0;        /* IR 是否已装载（0=空池，直通） */
    } arbmag_pool;
    /* [PATCHED-AuraDSP P-035] eq 逐声道池（8×FFTConvolver1x1，IR 与主 mEQ.instance.coeffGen 同源但按设备采样率生成）。
     * 解决 MC 路径下 eq.channels 逐声道独立处理以及 96k/192k 下 S-6 频偏问题。
     * 线程契约：alloc/free/reload 全部控制线程；RT 线程只读池指针与 loaded 标志。 */
    struct EqPool {
        FFTConvolver1x1* conv[kMxMaxChannels] = {};
        int              loaded = 0;        /* IR 是否已装载（0=空池，直通） */
        float            ir_rate = 0.0f;    /* 装载时的采样率 */
    } eq_pool;
    /* WP4: BassMono one-pole 状态（RT 独占；支持 8 声道；bm_reinit 为一次性平滑重初始化标志） */
    float bm_lp[8] = {0.0f};
    std::atomic<int> bm_reinit{0};
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

    auradsp::PluginEngineState plugin;

    /* [ADR-003 Phase A] 多声道矩阵工作区 */
    std::atomic<int> channel_count{2};   /* 驱动层交织缓冲的声道数（2=立体声） */
    float* mx_scratch = nullptr;         /* max_block*kMxMaxChannels，留存各声道 */
    float* mx_stereo = nullptr;          /* max_block*2，下混后的立体声链输出 */

    /* WP5: post_gain 逐声道输出平滑状态（一阶平滑 10ms，RT 独占） */
    float post_gain_sm[8] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};

    /* WP7: 防递归标志（hook_spatial_style 写 room/width/center 时不重置 style 为 3） */
    bool spatial_style_applying = false;

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
/* WP1：离散多声道 FDN 混响（N 进 N 出；LFE 可选入/出）。 */
void mc_reverb_process_mc(auradsp_handle h, float* io, int frames, int ch);
/* WP1：清 8 线 + 预延迟 + 平滑状态；通道数/模式/预设切换时调用。 */
void mc_reverb_reset(auradsp_handle h);
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
/* WP0 脚手架：混响路径判定（0=vendor 立体声，1=MC FDN）。
 * 只读参数 reverb.engine 与 WP1 的 apply_reverb 共用同一判定。 */
int reverb_path_kind(auradsp_handle h);
/* WP0 脚手架：拓扑变化时的统一状态清理入口（当前为空实现，
 * 逐模块清单见函数体注释；WP6 落地）。 */
void reset_channel_state(auradsp_handle h);
void apply_stereo(auradsp_handle h);
void apply_tube(auradsp_handle h);
void bassmono_process(auradsp_handle h, float* io, int frames);
void bassmono_process_mc(auradsp_handle h, float* io, int frames, int ch);
void basspsycho_process(auradsp_handle h, float* io, int frames);
void compute_latency(auradsp_handle h, double* out_ms);
void dyneq_process(auradsp_handle h, float* io, int frames);
void emit_viz(auradsp_handle h);
void exciter_process(auradsp_handle h, float* io, int frames);
void filter_process(auradsp_handle h, float* io, int frames);
void filter_recalc(auradsp_handle h);
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
void viz_write(auradsp_handle h, const float* out, int frames, int ch);
/* [Phase B] 矩阵模式的 per-channel 输出电平实测（不动频谱历史）。 */
void viz_scan_out_peak(auradsp_handle h, const float* out, int frames, int ch);
void viz_write_eq_in(auradsp_handle h, const float* src, int frames);
void gate_process_mc(auradsp_handle h, float* io, int frames, int ch);
void filter_process_mc(auradsp_handle h, float* io, int frames, int ch);
void shelf_process_mc(auradsp_handle h, float* io, int frames, int ch);
void dyneq_process_mc(auradsp_handle h, float* io, int frames, int ch);
void tube_process_mc(auradsp_handle h, float* io, int frames, int ch);
void exciter_process_mc(auradsp_handle h, float* io, int frames, int ch);
void loudness_process_mc(auradsp_handle h, float* io, int frames, int ch);
void limiter_process_mc(auradsp_handle h, float* io, int frames, int ch);
void post_gain_process_mc(auradsp_handle h, float* io, int frames, int ch);
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
/* [PATCHED-AuraDSP P-035] eq 逐声道池（控制线程建/载/释，RT 只读） */
void eq_pool_alloc(auradsp_handle h);
void eq_pool_free(auradsp_handle h);
void eq_pool_reload(auradsp_handle h);
void eq_pool_process_strided(auradsp_handle h, float* io, int frames,
                             int nch, int ch_idx);
void eq_process_mc(auradsp_handle h, float* dst, int frames, int ch);
/* [PATCHED-AuraDSP P-034] 动态范围压缩器离散多声道处理（支持 8 声道独立与成对模式） */
void comp_process_mc(auradsp_handle h, float* dst, int frames, int ch);
void process_multichannel_chain(auradsp_handle h, const float* src, float* dst, int frames, int ch);

