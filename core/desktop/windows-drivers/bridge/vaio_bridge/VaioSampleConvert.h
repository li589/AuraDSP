#pragma once
// VaioSampleConvert.h — VAIO 共享环样本 → float32 的纯转换。
//
// 桥的泵与宿主门禁测试（test/smoke/smoke_vaio_formats.py）共用同一
// 实现（同 VirtualClock 的先例：真实代码宿主编译实跑，不测复刻品）。
// 本头无平台依赖，只用标准库。
//
// 格式模型（格式升级一期，2026-11-12；与 AuraVaioIpc.h 同步）：
//   kind          AURA_VAIO_FMT_PCM(1) / AURA_VAIO_FMT_FLOAT(2)；
//                 0 = 旧驱动未指定 → 按容器位深推断（32→float、16→PCM）。
//   containerBits 每样本容器位深：16 / 24（紧密 3 字节）/ 32。
//   validBits     有效位深，0 = 与容器相同；仅 PCM 容器格式有意义
//                 （24-in-32：容器 32、有效 24，样本居于高位）。
//
// 历史契约（2026-11-09 §1.2）保持：PCM16 = int16 × 1/32768；
// float32 = 原样直通。新增格式不改变这两条的数值口径。

#include <cstdint>
#include <cstring>

// 组合是否可转换。不支持的组合调用方走诚实失败路径，禁止猜测转换。
inline bool VaioRingFormatSupported(unsigned long kind,
                                    unsigned long containerBits,
                                    unsigned long validBits) {
    if (kind == 0) {  // 旧驱动：只有 16/32 两种历史格式
        return containerBits == 16 || containerBits == 32;
    }
    if (validBits != 0 && validBits > containerBits) return false;
    if (kind == 2) {  // IEEE float
        return containerBits == 32;
    }
    if (kind == 1) {  // PCM 整数
        if (containerBits == 16) return validBits == 0 || validBits == 16;
        if (containerBits == 24) return validBits == 0 || validBits == 24;
        if (containerBits == 32) return true;  // 有效位深 8..32 通式可解
    }
    return false;
}

// 把 frames×channels 个交织样本从环原始字节转换为 float32。
// 调用前应先以 VaioRingFormatSupported 校验组合；未校验的未知组合
// 按 float32 直通兜底（与一期之前的旧行为一致，仅限 kind 推断路径）。
inline void VaioConvertRingToFloat(const unsigned char* raw, float* dst,
                                   int frames, int channels,
                                   unsigned long kind,
                                   unsigned long containerBits,
                                   unsigned long validBits) {
    const int n = frames * channels;
    if (n <= 0) return;
    if (kind == 0) kind = (containerBits == 32) ? 2 : 1;  // 旧驱动推断
    if (validBits == 0 || validBits > containerBits) validBits = containerBits;

    if (kind == 2) {  // IEEE float32 直通
        std::memcpy(dst, raw, (size_t)n * sizeof(float));
        return;
    }
    // PCM 整数
    if (containerBits == 16) {
        const std::int16_t* s = reinterpret_cast<const std::int16_t*>(raw);
        for (int i = 0; i < n; ++i) dst[i] = (float)s[i] * (1.0f / 32768.0f);
    } else if (containerBits == 24) {  // 紧密 24 位：小端组装 + 符号扩展
        for (int i = 0; i < n; ++i) {
            const unsigned char* p = raw + (size_t)i * 3;
            std::int32_t v = (std::int32_t)((unsigned)p[0] |
                                            ((unsigned)p[1] << 8) |
                                            ((unsigned)p[2] << 16));
            if (v & 0x800000) v -= 0x1000000;
            dst[i] = (float)v * (1.0f / 8388608.0f);
        }
    } else {  // 32 位容器：样本居高位，取高 validBits 位
        const int shift = (int)(32 - validBits);
        const float scale = 1.0f / (float)(1u << (validBits - 1));
        const std::int32_t* s = reinterpret_cast<const std::int32_t*>(raw);
        for (int i = 0; i < n; ++i) dst[i] = (float)(s[i] >> shift) * scale;
    }
}
