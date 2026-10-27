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

/* 按布局返回"除 LFE 外全部有效声道"的默认掩码（dyneq/exciter 默认随
 * channels.count 平移时使用）：
 *   2ch: 0xF7  保持 ABI 初始默认不变；有效位 0x03 = FL/FR，无 LFE 可排
 *   4ch: 0x0F  Quad 无 LFE：FL/FR/BL/BR 全开（0xF7 的 bit3 在 4ch 是 BR，
 *              直接用 0xF7 会默认跳过 BR——即本次修复点）
 *   6ch: 0x37  排除 LFE：FL/FR/C/SL/SR
 *   8ch: 0xF7  排除 LFE：全声道
 * 非标准声道数回落 kChMaskNoLfe。 */
inline uint32_t ch_mask_no_lfe_for(int ch) {
    switch (ch) {
        case 4:  return 0x0F;  /* 1|2|4|8 */
        case 6:  return 0x37;  /* 1|2|4|16|32 */
        default: return kChMaskNoLfe;  /* 2ch/8ch 及未知：0xF7 */
    }
}

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
