// AuraAsioDriverGuid.h — AuraDSP 虚拟 ASIO 驱动 GUID 与标识定义
//
// 依据：docs/adr/ADR-008-asio-driver-identity-and-architecture.md
// 商标合规：驱动对外显示名严格遵循 Steinberg ASIO 使用指南，定名为 "AuraDSP Driver"。
#pragma once

#include <guiddef.h>
#include <cstdint>

// CLSID_AuraAsioDriver: {4B617572-6144-5350-4153-494F44727631}
// ASCII 语义说明：
//   Data1 = 0x4B617572 ("Kaur")
//   Data2 = 0x6144     ("aD")
//   Data3 = 0x5350     ("SP")
//   Data4 = { 0x41, 0x53, 0x49, 0x4F, 0x44, 0x72, 0x76, 0x31 } ("ASIODrv1")
DEFINE_GUID(CLSID_AuraAsioDriver,
    0x4B617572, 0x6144, 0x5350, 0x41, 0x53, 0x49, 0x4F, 0x44, 0x72, 0x76, 0x31);

constexpr const char* kAuraAsioDriverName = "AuraDSP Driver";
constexpr const char* kAuraAsioDriverRegKey = "AuraDSP Driver";
constexpr const char* kAuraAsioDriverDesc = "AuraDSP Driver";
constexpr const wchar_t* kAuraAsioClsidString = L"{4B617572-6144-5350-4153-494F44727631}";
constexpr const char* kAuraAsioClsidStringA = "{4B617572-6144-5350-4153-494F44727631}";

// Phase 2 扩展/诊断 Future 选择子（基于 'AUR*' 四字节私有空间）
constexpr long kAuraAsioFutureGetWasapiRenderedFrames = 0x41555201; // 'AUR\1'
constexpr long kAuraAsioFutureGetWasapiTargetRate      = 0x41555202; // 'AUR\2'
constexpr long kAuraAsioFutureIsWasapiOpen             = 0x41555203; // 'AUR\3'

// Phase 3 DSP 扩展/控制 Future 选择子
constexpr long kAuraAsioFutureIsDspLoaded              = 0x41555210; // 'AUR\x10': opt -> long* (1=loaded, 0=not)
constexpr long kAuraAsioFutureSetBypass                = 0x41555211; // 'AUR\x11': opt -> const long* (1=bypass, 0=dsp)
constexpr long kAuraAsioFutureGetBypass                = 0x41555212; // 'AUR\x12': opt -> long*
constexpr long kAuraAsioFutureSetParam                 = 0x41555213; // 'AUR\x13': opt -> const AuraAsioParamIo*
constexpr long kAuraAsioFutureGetParam                 = 0x41555214; // 'AUR\x14': opt -> AuraAsioParamIo*
constexpr long kAuraAsioFutureApplyParamsString        = 0x41555215; // 'AUR\x15': opt -> const char* ("id=val;...")
constexpr long kAuraAsioFutureGetDspProcessedFrames    = 0x41555216; // 'AUR\x16': opt -> uint64_t*
constexpr long kAuraAsioFutureCopyLastOutputBlock      = 0x41555217; // 'AUR\x17': opt -> AuraAsioBlockCopy*

struct AuraAsioParamIo {
    const char* id;
    void* value;
    uint32_t bytes;
};

struct AuraAsioBlockCopy {
    float* outL;
    float* outR;
    long maxSamples;
    long copiedSamples;
};

