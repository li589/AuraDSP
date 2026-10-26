#pragma once
#include <cstdint>

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

/* 标准四对位掩码与首声道索引 (Pair 0: FL/FR, Pair 1: C/LFE, Pair 2: SL/SR, Pair 3: BL/BR) */
constexpr uint32_t kChMaskPair[4] = {0x03, 0x0C, 0x30, 0xC0};
constexpr int kChPairFirst[4] = {0, 2, 4, 6};

struct SpeakerLayout {
    int count;
    int fl, fr, c, lfe, sl, sr, bl, br; /* -1 = 不存在 */
};

inline SpeakerLayout layout_for(int ch) {
    SpeakerLayout l;
    l.count = ch;
    l.fl = 0;
    l.fr = 1;
    l.c = -1;
    l.lfe = -1;
    l.sl = -1;
    l.sr = -1;
    l.bl = -1;
    l.br = -1;
    if (ch == 4) {
        /* Quad 4.0 (ADR-003): FL(0), FR(1), BL(2), BR(3) */
        l.bl = 2;
        l.br = 3;
    } else if (ch >= 6) {
        /* 5.1 (6ch) / 7.1 (8ch) */
        l.c = 2;
        l.lfe = 3;
        l.sl = 4;
        l.sr = 5;
        if (ch >= 8) {
            l.bl = 6;
            l.br = 7;
        }
    }
    return l;
}
