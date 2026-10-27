/* P2 split: moved verbatim from auradsp_engine.cpp (pure move, no logic change). */
#include "engine_internal.h"



/* 频谱历史写入（RT 线程，每个 process 块都必须调用！）。
 *
 * 教训：旧实现把"写历史"放在 emit_viz 里，而 emit_viz 只每 kVizInterval 帧触发
 * 一次 → 两次发射之间的音频块从未进窗，环形历史是"每两块丢一块"的梳状采样
 * 信号（= 信号 × 50% 占空比方波），频谱全是混叠假峰。这就是"低音区几根柱子
 * 不显示 / 频段间距怪"的真正根因（自 1024-FFT 版本起就存在）。
 *
 * [Phase B 多声道电平] ch 参数：块的实际 stride。除历史与 L/R 峰值（仍取
 * ch0/ch1，行为不变）外，同一趟顺带记录 ch_out_peak[0..ch-1]——与 viz_lvl_l/r
 * 同源同趟，保证 channel_levels[0]/[1] 与 level_l/r_dbfs 逐位一致。
 * [ch..7] 清零：声道数动态变化时杜绝跨块残留（如 MC8→stereo 切换）。 */
void viz_write(auradsp_handle h, const float* out, int frames, int ch) {
    const int mask = h->viz_fft_size.load(std::memory_order_relaxed) - 1;
    /* 历史写入与块峰值合并为一趟遍历：旧实现分两趟，等于把 out 多读一遍
     *（2048 帧块 = 多读 16KB）。两趟访问的下标序列完全一致，合并安全。 */
    float lvl_l = 0.0f, lvl_r = 0.0f;
    float pk_ch[AURADSP_CH_MAX] = {};
    for (int i = 0; i < frames; ++i) {
        const float l = out[i * ch];
        const float r = out[i * ch + 1];
        h->viz_hist[h->viz_hist_pos * 2]     = l;
        h->viz_hist[h->viz_hist_pos * 2 + 1] = r;
        h->viz_hist_pos = (h->viz_hist_pos + 1) & mask;
        const float a = fabsf(l), b = fabsf(r);
        if (a > lvl_l) lvl_l = a;
        if (b > lvl_r) lvl_r = b;
        for (int c = 0; c < ch && c < AURADSP_CH_MAX; ++c) {
            const float ac = fabsf(out[i * ch + c]);
            if (ac > pk_ch[c]) pk_ch[c] = ac;
        }
    }
    h->viz_lvl_l = lvl_l > 1e-6f ? 20.0f * log10f(lvl_l) : -120.0f;
    h->viz_lvl_r = lvl_r > 1e-6f ? 20.0f * log10f(lvl_r) : -120.0f;
    for (int c = 0; c < AURADSP_CH_MAX; ++c) h->ch_out_peak[c] = (c < ch) ? pk_ch[c] : 0.0f;
}


/* [EQ tap] 记录 vendor 链入口（= 均衡器输入）的环形历史。
 *
 * 位置选在 processFloatMultiplexed 之前：此时已过 pre-DSP / 前置插件 /
 * 低架提升，但还没进 EQ，与"均衡器看到的信号"语义一致。
 *
 * 与 viz_write 分开而不是复用：那条写的是整链输出，两者必须独立，
 * 否则「输入 = 输出 × EQ 响应」的合成关系就不成立。
 * 本函数不做峰值统计（那条只服务于输出电平表）。 */
void viz_write_eq_in(auradsp_handle h, const float* src, int frames) {
    if (!h->eq_in_hist) return;
    const int mask = h->viz_fft_size.load(std::memory_order_relaxed) - 1;
    for (int i = 0; i < frames; ++i) {
        h->eq_in_hist[h->eq_in_hist_pos * 2]     = src[i * 2];
        h->eq_in_hist[h->eq_in_hist_pos * 2 + 1] = src[i * 2 + 1];
        h->eq_in_hist_pos = (h->eq_in_hist_pos + 1) & mask;
    }
}


/* [Phase B 多声道电平] 只扫 per-channel 输出峰值，不碰频谱历史。
 *
 * 用途：矩阵模式（channels.mode=0）的频谱仍取下混立体声（mx_stereo，
 * ADR-003 既存语义，刻意不改），但 per-channel 电平应反映 mx_upmix 之后
 * 真实写进设备的 out 缓冲——否则 channel_levels[2..N-1] 会恒 -120，
 * 让多声道用户的默认路径上 6 根柱永久假死（违反 G5 诚实显示）。
 * 与 viz_write 分开调用：同一块内先 viz_write(mx_stereo,2) 再本函数，
 * 后者覆盖 ch_out_peak[0..ch-1] 为 out 实测值。 */
void viz_scan_out_peak(auradsp_handle h, const float* out, int frames, int ch) {
    float pk[AURADSP_CH_MAX] = {};
    for (int i = 0; i < frames; ++i) {
        const float* row = out + (size_t)i * ch;
        for (int c = 0; c < ch && c < AURADSP_CH_MAX; ++c) {
            const float a = fabsf(row[c]);
            if (a > pk[c]) pk[c] = a;
        }
    }
    for (int c = 0; c < AURADSP_CH_MAX; ++c) h->ch_out_peak[c] = (c < ch) ? pk[c] : 0.0f;
}


/* 频谱帧产出（RT 线程；只做 FFT + 带划分 + push，历史写入已由 viz_write 完成）。
 *
 * 关键：调用方块长可变（WASAPI 共享模式轮询下常见 200~1100 帧），
 * 绝不能要求单块 >= kVizFftSize，否则只有首个大块产出一次、之后永久静止。
 * 因此维护 kVizFftSize 帧的 L/R 环形历史窗（create 预分配，无 RT 分配），
 * 每次对"最近 kVizFftSize 帧"做汉宁窗实数 FFT。
 */
/* 把一条 tap 的环形历史窗变成 32 段频带。两条 tap（整链输出 / EQ 输入）
 * 共用这段逻辑，保证 kBandEdges、DC blocker、汉宁窗、归一化口径完全一致——
 * 任何一处不一致都会让 UI 合成出的 EQ 输出谱出现系统性偏差。
 *
 * scratch 为 kN floats 的工作区（两条 tap 在 emit_viz 里**顺序**使用，不重叠）。
 * dc_in / dc_out 为该 tap 私有的 DC blocker 递推状态，函数内就地更新。 */
static void compute_bands(auradsp_handle h, const float* hist, int pos, int kN,
                          float* scratch, float* dc_in, float* dc_out,
                          float* out_bands) {
    const int mask = kN - 1;
    const int half = kN / 2;
    const int nmag = half < 2048 ? half : 2048;

    /* 1) 按时间序提取整窗 + 汉宁窗（L 声道） */
    for (int i = 0; i < kN; ++i) {
        const int idx = (pos + i) & mask;   /* pos 即最旧帧 */
        scratch[i] = hist[idx * 2] * h->hann[i];
    }

    /* DC/次声泄漏抑制：先一阶高通（DC blocker）再去窗内均值，再 FFT。
     * 只做均值去直流不足以压住最低频带——窗旁瓣仍会把残余低频能量泄进
     * band0（实测放宽显示下限时 band0 达 0.319，触发 smoke_viz_lowfreq
     * 的 DC 泄漏红线）。高通截止取 ~30Hz，略高于 band0 上界 25Hz，
     * 对可听频段与所有对数频带读数无影响。 */
    {
        constexpr float kDcR = 0.995f;   /* 截止 ≈ fs/(2π)·(1-R) */
        float prevIn = *dc_in;
        float prevOut = *dc_out;
        for (int i = 0; i < kN; ++i) {
            const float x = scratch[i];
            const float y = x - prevIn + kDcR * prevOut;
            prevIn = x; prevOut = y;
            scratch[i] = y;
        }
        *dc_in = prevIn;
        *dc_out = prevOut;
    }

    double wmean = 0.0;
    for (int i = 0; i < kN; ++i) wmean += scratch[i];
    wmean /= kN;
    for (int i = 0; i < kN; ++i) scratch[i] -= (float)wmean;
    WDL_real_fft(scratch, kN, 0);

    /* WDL 实 FFT：输出 kN/2 个复数，按 WDL_fft_permute(kN/2) 顺序存放 */
    const int32_t* perm = WDL_fft_permute_tab(half);
    static thread_local float mag[2048];
    for (int i = 0; i < nmag; ++i) {
        const int pi = perm ? perm[i] : i;
        const float re = scratch[pi * 2];
        const float im = scratch[pi * 2 + 1];
        mag[i] = sqrtf(re * re + im * im);
    }
    const float bin_hz = h->sample_rate / (float)kN;

    /* 4) 32 对数带：幅度归一（汉宁相干增益 0.5 × 单边 2）→ dBFS → [0,1] */
    const float amp_scale = 4.0f / (float)kN;
    for (int b = 0; b < AURADSP_VIZ_BANDS; ++b) {
        const int lo = (int)(kBandEdges[b] / bin_hz);
        int hi = (int)(kBandEdges[b + 1] / bin_hz);
        /* 窄于单个 FFT bin 的频带必须至少占一个 bin，否则被结构性丢弃。
         * 4096@48kHz 时 bin_hz≈11.72Hz，而 25–31Hz 的 band1 只有 6Hz 宽：
         * lo==hi==2 → 原先直接判 0，白噪音下第二根柱子永远不显示、
         * 低频整体缺频。向上取整到 lo+1 让它与相邻带共享该 bin。 */
        if (hi <= lo) hi = lo + 1;
        if (lo >= nmag) { out_bands[b] = 0; continue; }
        const int hb = hi > nmag ? nmag : hi;
        float m = 0;
        for (int i = lo; i < hb; ++i) if (mag[i] > m) m = mag[i];
        const float amp = m * amp_scale;
        /* -75..0 dBFS → 0..1。
         * 上游一阶 DC blocker 已压掉直流/次声；-75 是「显示下限」与
         * 「窗口旁瓣红线」的折中：纯 60Hz 正弦在 band0 的汉宁窗旁瓣实测约
         * -70 dBFS，映射后 0.061，仍满足 smoke_viz_lowfreq 的 <0.1 断言；
         * 而 -60 会把它直接钳成 0，频谱只剩零零散散几根柱、读不出连续性。
         * 不要为了"更好看"再放宽 —— 那会让旁瓣顶破红线。 */
        float v = 0.0f;
        if (amp > 1e-7f) v = (20.0f * log10f(amp) + 75.0f) * (1.0f / 75.0f);
        out_bands[b] = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    }
}


void emit_viz(auradsp_handle h) {
    const int kN = h->viz_fft_size.load(std::memory_order_relaxed);

    auradsp_viz_frame f;
    memset(&f, 0, sizeof(f));
    f.seq = ++h->viz_seq;
    f.timestamp_ms =
        f.seq * (h->viz_interval.load(std::memory_order_relaxed) * 1000.0 / h->sample_rate);

    /* 2) 两条 tap 各自出 32 带：整链最终输出 + vendor 链入口（EQ 输入）。
     * 顺序执行，共用同一块 fft_scratch（互不重叠，无 RT 分配）。 */
    compute_bands(h, h->viz_hist, h->viz_hist_pos, kN, h->fft_scratch,
                  &h->dc_prev_in, &h->dc_prev_out, f.spectrum);
    if (h->eq_in_hist) {
        compute_bands(h, h->eq_in_hist, h->eq_in_hist_pos, kN, h->fft_scratch,
                      &h->eq_dc_prev_in, &h->eq_dc_prev_out, f.eq_in_spectrum);
    }

    /* 3) 峰值电平（最近块，dBFS；由 viz_write 记录） */
    f.level_l_dbfs = h->viz_lvl_l;
    f.level_r_dbfs = h->viz_lvl_r;

    /* 5) [M3.5-c / 全量电平补齐] 处理链各 stage 的输出峰值转 dBFS。
     * 0..11: vendor 12 级链
     * 12: gate 输入电平 (input_lvl_in)
     * 13: gate 本级输出电平
     * 14: dyneq 动态均衡
     * 15: filter 独立滤波
     * 16: bassmono 低频单声道
     * 17: haas 差分环绕
     * 18: exciter 高频激励
     * 19: loudness 响度补偿
     * 20: spatial 空间音效
     * 21..23: 预留槽位（恒 -120 dBFS）
     * 24: Limiter GR (dB)
     * 25: Compressor GR (dB)
     * 26: Noise Gate GR (dB)
     * 27: Dyneq Low GR (dB)
     * 28: Dyneq Mid GR (dB)
     * 29: Dyneq High GR (dB)
     * 30..31: 预留槽位（恒 -120 dBFS） */
    for (int i = 0; i < AURADSP_STAGE_MAX; ++i) {
        if (i < AURADSP_VENDOR_STAGES) {
            const float pl = h->jdsp.stagePeakL[i];
            const float pr = h->jdsp.stagePeakR[i];
            f.stage_levels_l[i] = pl > 1e-6f ? 20.0f * log10f(pl) : -120.0f;
            f.stage_levels_r[i] = pr > 1e-6f ? 20.0f * log10f(pr) : -120.0f;
        } else if (i == 12) {
            /* [Input Gate Tap] 输入门控本级 IN 电平 (L/R) */
            f.stage_levels_l[i] = h->input_lvl_in_l;
            f.stage_levels_r[i] = h->input_lvl_in_r;
        } else if (i >= 13 && i <= 20) {
            /* 自研 8 级 stage 输出峰值转 dBFS */
            const float pl = h->stage_peak_l[i];
            const float pr = h->stage_peak_r[i];
            f.stage_levels_l[i] = pl > 1e-6f ? 20.0f * log10f(pl) : -120.0f;
            f.stage_levels_r[i] = pr > 1e-6f ? 20.0f * log10f(pr) : -120.0f;
        } else if (i == 24) {
            f.stage_levels_l[i] = f.stage_levels_r[i] = h->gr_limiter.load(std::memory_order_relaxed);
        } else if (i == 25) {
            f.stage_levels_l[i] = f.stage_levels_r[i] = h->gr_comp.load(std::memory_order_relaxed);
        } else if (i == 26) {
            f.stage_levels_l[i] = f.stage_levels_r[i] = h->gr_gate.load(std::memory_order_relaxed);
        } else if (i == 27) {
            f.stage_levels_l[i] = f.stage_levels_r[i] = h->gr_dyneq[0].load(std::memory_order_relaxed);
        } else if (i == 28) {
            f.stage_levels_l[i] = f.stage_levels_r[i] = h->gr_dyneq[1].load(std::memory_order_relaxed);
        } else if (i == 29) {
            f.stage_levels_l[i] = f.stage_levels_r[i] = h->gr_dyneq[2].load(std::memory_order_relaxed);
        } else {
            f.stage_levels_l[i] = -120.0f;
            f.stage_levels_r[i] = -120.0f;
        }
    }
    h->input_lvl_out_l = f.stage_levels_l[13];
    h->input_lvl_out_r = f.stage_levels_r[13];
    /* [Phase B 多声道电平] per-channel 字段填充（ABI v2 追加段）。
     * 统一裁决点：c >= last_block_ch 一律 -120（不信任任何跨块残留），
     * c < 2 与 stage_levels_l/r 同源（stereo 逐位不变），
     * vendor 段 0..11 与 GR 段 24..29 仅 [0]/[1] 或全 -120（作用域语义）。 */
    const int blkCh = h->last_block_ch;
    f.channel_count = (uint32_t)(blkCh > 0 ? blkCh : 0);
    for (int c = 0; c < AURADSP_CH_MAX; ++c) {
        f.channel_levels[c] = (c < blkCh && h->ch_out_peak[c] > 1e-6f)
            ? 20.0f * log10f(h->ch_out_peak[c]) : -120.0f;
    }
    for (int i = 0; i < AURADSP_STAGE_MAX; ++i) {
        for (int c = 0; c < AURADSP_CH_MAX; ++c) {
            if (i < AURADSP_VENDOR_STAGES) {
                /* vendor：MC 下只作用于 FL/FR 对（ADR-003 Category B），其余声道 -120 */
                f.stage_ch_levels[i][c] = (c == 0) ? f.stage_levels_l[i]
                                        : (c == 1) ? f.stage_levels_r[i] : -120.0f;
            } else if (i >= 24 && i <= 29) {
                f.stage_ch_levels[i][c] = -120.0f;   /* GR 单值计量，per-channel 无意义 */
            } else if (c < 2) {
                /* 自研效果器段 L/R 列与 stage_levels_l/r 同源（stereo 逐位不变） */
                f.stage_ch_levels[i][c] = (c == 0) ? f.stage_levels_l[i] : f.stage_levels_r[i];
            } else if (c < h->stage_ch_active) {
                const float p = h->stage_peak_ch[i][c];
                f.stage_ch_levels[i][c] = p > 1e-6f ? 20.0f * log10f(p) : -120.0f;
            } else {
                f.stage_ch_levels[i][c] = -120.0f;
            }
        }
    }
    h->viz_emitted.store(true, std::memory_order_relaxed);
    h->viz.push(f);
}
