// channel_map.h — 流↔引擎声道适配的统一表（全平台单一真相）。
//
// 第五十五轮小量重构（user 裁定）：APO / VB / VAIO 三桥与 ASIO
// 驱动各自抄了一份声道位置映射与下混折叠表，历史上两次漂移
// （r47 修 APO/VB 时漏 VAIO 离散截断；r54 又发现 VAIO 矩阵
// 8→4 主次仍是旧表）。自本轮起表只存这一处，各宿主只留一行
// 委托；数值行为由 channel_map_test 宿主单测守。
//
// 声道序约定（与 speaker_layout.h 一致）：流序恒为标准序
// FL FR C LFE SL SR BL BR 的前 streamCh 位；引擎声道序按宽度
// 取布局——2=FL,FR；4=Quad（FL,FR,BL,BR）；6=FL,FR,C,LFE,SL,SR；
// 8=7.1 全序。故引擎 4ch 的 BL/BR 在 8 宽流里位于第 7/8 声道
// （下标 6/7）、在 6 宽流里位于第 5/6 声道（SL/SR 位）。
//
// 分层注记：引擎核心的 mx_downmix/mx_upmix（engine_chain.cpp）
// 是 DSP 链内部的立体声矩阵级（LFE 留存旁路、与上混回填成
// 对），与本头的「宿主适配」是两层，不在此合并。
#pragma once

#include <cstring>

#include "chain/speaker_layout.h"

/* 折叠系数：标准 -3 dB（1/sqrt(2)）。 */
constexpr float kChmapFoldK = 0.70710678f;

/* 引擎声道 c 在 streamCh 宽的流中的位置（离散映射表）。
 * 仅 engCh==4 分叉：后置对（c>=2）在 8 宽流取 +4、6 宽流
 * 取 +2；其余宽对恒等。 */
inline int chmap_stream_pos(int engCh, int streamCh, int c) {
    if (engCh == 4 && c >= 2) {
        if (streamCh == 8) return c + 4;
        if (streamCh == 6) return c + 2;
    }
    return c;
}

/* 矩阵下混一帧：srcCh 宽流帧 → dstCh 宽（dstCh < srcCh）。
 * 折叠口径（r46/r47 裁定）：除无处可去的 LFE 外不丢内容；
 * 被折入声道乘 kChmapFoldK、驻留声道保持 1.0；目标布局的
 * 驻留环绕为主——8→4 时 BL/BR 为主、SL/SR 折入（引擎 Quad
 * 序，r47 S2 修正主次）；8→6 时 SL/SR 为主、BL/BR 折入。
 * →2 用 layout_for 位置泛化（4/6/7/8 宽与逐项表等价），3/5
 * 宽按无 LFE 的 3.0/5.0 序（C 居 2、环绕居 3/4）折入。
 * 其余无表组合（奇宽→4/6 等）回落顺序截断。 */
inline void chmap_fold_frame(const float* in, int srcCh,
                             float* out, int dstCh) {
    const float k = kChmapFoldK;
    if (dstCh == 2 && srcCh > 2) {
        float l = in[0];
        float r = in[1];
        if (srcCh == 3) {  // 3.0：FL FR C
            const float c = in[2] * k;
            l += c;
            r += c;
        } else if (srcCh == 5) {  // 5.0：FL FR C SL SR
            const float c = in[2] * k;
            l += c + in[3] * k;
            r += c + in[4] * k;
        } else {
            const SpeakerLayout ly = layout_for(srcCh);
            if (ly.c >= 0) {
                const float c = in[ly.c] * k;
                l += c;
                r += c;
            }
            if (ly.sl >= 0) l += in[ly.sl] * k;
            if (ly.sr >= 0) r += in[ly.sr] * k;
            if (ly.bl >= 0) l += in[ly.bl] * k;
            if (ly.br >= 0) r += in[ly.br] * k;
        }
        out[0] = l;
        out[1] = r;
        return;
    }
    if (srcCh == 8 && dstCh == 6) {
        out[0] = in[0];
        out[1] = in[1];
        out[2] = in[2];
        out[3] = in[3];
        out[4] = in[4] + in[6] * k;
        out[5] = in[5] + in[7] * k;
        return;
    }
    if (srcCh == 8 && dstCh == 4) {
        const float c = in[2] * k;
        out[0] = in[0] + c;
        out[1] = in[1] + c;
        out[2] = in[6] + in[4] * k;  // BL 为主、SL 折入
        out[3] = in[7] + in[5] * k;  // BR 为主、SR 折入
        return;
    }
    if (srcCh == 6 && dstCh == 4) {
        const float c = in[2] * k;
        out[0] = in[0] + c;
        out[1] = in[1] + c;
        out[2] = in[4];  // SL 落 BL 位（原量）
        out[3] = in[5];  // SR 落 BR 位（原量）
        return;
    }
    // 无表组合：顺序截断（同宽时即直通拷贝）。
    const int n = dstCh < srcCh ? dstCh : srcCh;
    for (int c = 0; c < n; ++c) out[c] = in[c];
    for (int c = n; c < dstCh; ++c) out[c] = 0.0f;
}

/* 矩阵下混（交织多帧）：逐帧 chmap_fold_frame。 */
inline void chmap_fold(const float* src, int srcCh,
                       float* dst, int dstCh, int frames) {
    for (int f = 0; f < frames; ++f) {
        chmap_fold_frame(src + (size_t)f * srcCh, srcCh,
                         dst + (size_t)f * dstCh, dstCh);
    }
}

/* 离散 gather：流（streamCh 宽）→ 引擎缓冲（engCh 宽），按
 * chmap_stream_pos 取声道，映射外声道丢弃、超宽引擎槽清零。 */
inline void chmap_gather_discrete(const float* src, int streamCh,
                                  float* dst, int engCh, int frames) {
    for (int f = 0; f < frames; ++f) {
        for (int c = 0; c < engCh; ++c) {
            const int pos = chmap_stream_pos(engCh, streamCh, c);
            dst[(size_t)f * engCh + c] =
                (pos < streamCh) ? src[(size_t)f * streamCh + pos] : 0.0f;
        }
    }
}

/* 离散 scatter：引擎缓冲（engCh 宽）→ 流（streamCh 宽）。整帧
 * 先清零，只按 chmap_stream_pos 回写——同时充当「窄→宽」的
 * 布局放置（上扩）：未被引擎覆盖的流声道保持静音。 */
inline void chmap_scatter_discrete(const float* src, int engCh,
                                   float* dst, int streamCh, int frames) {
    std::memset(dst, 0, (size_t)frames * streamCh * sizeof(float));
    for (int f = 0; f < frames; ++f) {
        for (int c = 0; c < engCh; ++c) {
            const int pos = chmap_stream_pos(engCh, streamCh, c);
            if (pos < streamCh) {
                dst[(size_t)f * streamCh + pos] = src[(size_t)f * engCh + c];
            }
        }
    }
}
