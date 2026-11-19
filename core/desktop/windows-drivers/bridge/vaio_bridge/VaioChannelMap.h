// VaioChannelMap.h — VAIO 桥离散逐声道模式的流↔引擎声道位置映射。
//
// 第五十四轮定罪：离散截断原为纯顺序拷贝（r46 S2 实现），引擎
// 4ch 是 Quad（FL,FR,BL,BR，见 speaker_layout.h），在 7.1 流里
// BL/BR 位于第 7/8 声道（下标 6/7）、在 5.1 流里位于第 5/6 声道
// （SL/SR 位，下标 4/5）；顺序截断把引擎 BL/BR 对到流的第 3/4
// 声道（C/LFE），user 实机报告（2026-11-19）。APO 的
// StreamPosForCh 与 VB 的 BusChForSlot 在 r47 S2 已按此表映射，
// 本头把同一张表落到 VAIO 桥：映射规则逐字同表，不另立口径。
//
// 离散语义不变（r46 user 裁定）：映射位置之外的声道一律丢弃
// （gather 不取、scatter 不写且整帧清零），绝不折叠。
#pragma once

#include <cstring>

// 引擎声道 c 在 streamCh 宽的流中的位置。
inline int VaioEngChStreamPos(int engCh, int streamCh, int c) {
    if (engCh == 4 && c >= 2) {
        if (streamCh == 8) return c + 4;  // Quad 后置对 7.1 的 BL/BR
        if (streamCh == 6) return c + 2;  // Quad 后置对 5.1 的 SL/SR
    }
    return c;
}

// 离散 gather：流（streamCh 宽）→ 引擎缓冲（engCh 宽）。按位置
// 映射取声道；映射位置超出流宽的引擎槽清零。
inline void VaioTruncateGather(const float* src, int streamCh,
                               float* dst, int engCh, int frames) {
    for (int f = 0; f < frames; ++f) {
        for (int c = 0; c < engCh; ++c) {
            const int pos = VaioEngChStreamPos(engCh, streamCh, c);
            dst[f * engCh + c] =
                (pos < streamCh) ? src[f * streamCh + pos] : 0.0f;
        }
    }
}

// 离散 scatter：引擎缓冲（engCh 宽）→ 流（streamCh 宽）。整帧
// 先清零，只按位置映射回写引擎声道——未被引擎覆盖的流声道
// 保持静音（丢弃语义的写侧）。
inline void VaioTruncateScatter(const float* src, int engCh,
                                float* dst, int streamCh, int frames) {
    std::memset(dst, 0, (size_t)frames * streamCh * sizeof(float));
    for (int f = 0; f < frames; ++f) {
        for (int c = 0; c < engCh; ++c) {
            const int pos = VaioEngChStreamPos(engCh, streamCh, c);
            if (pos < streamCh) dst[f * streamCh + pos] = src[f * engCh + c];
        }
    }
}
