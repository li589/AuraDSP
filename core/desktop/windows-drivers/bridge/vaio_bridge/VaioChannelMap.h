// VaioChannelMap.h — VAIO 桥离散逐声道适配（委托垫片）。
//
// 第五十四轮曾在此处落位位置映射表；第五十五轮起表体收编至
// engine/chain/channel_map.h（APO/VB/VAIO/ASIO 全宿主单一
// 真相），本头只保留 VAIO 侧函数名并逐一委托，数值行为由
// channel_map_test 守。离散语义不变（r46 user 裁定）：映射
// 位置之外的声道一律丢弃，绝不折叠。
#pragma once

#include "chain/channel_map.h"

// 引擎声道 c 在 streamCh 宽的流中的位置。
inline int VaioEngChStreamPos(int engCh, int streamCh, int c) {
    return chmap_stream_pos(engCh, streamCh, c);
}

// 离散 gather：流（streamCh 宽）→ 引擎缓冲（engCh 宽）。
inline void VaioTruncateGather(const float* src, int streamCh,
                               float* dst, int engCh, int frames) {
    chmap_gather_discrete(src, streamCh, dst, engCh, frames);
}

// 离散 scatter：引擎缓冲（engCh 宽）→ 流（streamCh 宽）。
inline void VaioTruncateScatter(const float* src, int engCh,
                                float* dst, int streamCh, int frames) {
    chmap_scatter_discrete(src, engCh, dst, streamCh, frames);
}
