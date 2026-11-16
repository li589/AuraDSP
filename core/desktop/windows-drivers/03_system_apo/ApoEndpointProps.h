// ApoEndpointProps.h — 端点级属性集（第四十一轮，APO 多端点 v2）。
//
// 每个渲染端点在注册表 MMDevices\...\FxProperties 下有自己的属性
// 存储；APO 实例初始化时经 IAudioSystemEffects 的初始化数据拿到
// 本端点存储的 IPropertyStore（pAPOEndpointProperties）。本属性集
// 是 App 侧（apo_config 附加/设置路径）与 APO 实例之间的端点级通
// 道：身份令牌让实例自证所服务端的端点，声道族覆写让每端点的引
// 擎配置互不影响——参数块保持全局单值（见立项计划 §4.1/§4.2）。
//
// 属性集 fmtid {A5C3D21E-9B47-4F1A-8E6D-2F5B7C904E31}：
//   pid 2  IdentityToken  VT_LPWSTR  端点自身的 MMDevice id 全串
//   pid 3  ChannelsMode   VT_UI4     channels.mode 覆写（0 矩阵/1 离散）
//   pid 4  UpmixFill      VT_UI4     channels.upmix_fill 覆写（0/1）
//   pid 5  OverrideFlags  VT_UI4     bit0: mode 有效；bit1: fill 有效
// 注册表值名形如 "{a5c3d21e-9b47-4f1a-8e6d-2f5b7c904e31},2"（与
// PKEY_FX_Association 等既有 FX 值同构）。
#pragma once

#include <guiddef.h>
#include <propkeydef.h>

inline const GUID& AuraEndpointPropsSetGuid() {
    static const GUID g = {0xA5C3D21E, 0x9B47, 0x4F1A,
                           {0x8E, 0x6D, 0x2F, 0x5B, 0x7C, 0x90, 0x4E, 0x31}};
    return g;
}

constexpr unsigned long kAuraPropPidToken = 2;
constexpr unsigned long kAuraPropPidMode = 3;
constexpr unsigned long kAuraPropPidFill = 4;
constexpr unsigned long kAuraPropPidFlags = 5;

constexpr unsigned long kAuraOverrideModeValid = 0x1;
constexpr unsigned long kAuraOverrideFillValid = 0x2;

inline PROPERTYKEY AuraEndpointPropKey(unsigned long pid) {
    PROPERTYKEY k;
    k.fmtid = AuraEndpointPropsSetGuid();
    k.pid = pid;
    return k;
}

// FNV-1a 64（UTF-16LE 字节流）：端点 id → telemetry 分块名/座位键。
// 与 App 侧实现必须同算法同输入（端点 id 的 UTF-16 串，含花括号）。
inline unsigned long long AuraEndpointIdHash(const wchar_t* id) {
    unsigned long long h = 1469598103934665603ull;
    if (!id) return h;
    for (const wchar_t* p = id; *p; ++p) {
        const unsigned short w = (unsigned short)*p;
        h ^= (w & 0xFF);
        h *= 1099511628211ull;
        h ^= (w >> 8);
        h *= 1099511628211ull;
    }
    return h;
}
