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

// 诊断 Future 选择子（只读查询面，2026-11-22 审查 N5 裁定恢复）：
// 原 13 个私有选择子中，控制类（SetBypass/GetBypass/SetParam/
// GetParam/ApplyParamsString/SetChannels/GetChannels）与 S3/S4
// 参数块重复且语义冲突，已删除；下列六个纯诊断查询无生产替代
// 面（项目实机冒烟 smoke_asio_driver 的驱动探针在用），保留。
constexpr long kAuraAsioFutureGetWasapiRenderedFrames = 0x41555201; // 'AUR\1'
constexpr long kAuraAsioFutureGetWasapiTargetRate      = 0x41555202; // 'AUR\2'
constexpr long kAuraAsioFutureIsWasapiOpen             = 0x41555203; // 'AUR\3'
constexpr long kAuraAsioFutureIsDspLoaded              = 0x41555210; // 'AUR\x10': opt -> long* (1=loaded, 0=not)
constexpr long kAuraAsioFutureGetDspProcessedFrames    = 0x41555216; // 'AUR\x16': opt -> uint64_t*
constexpr long kAuraAsioFutureCopyLastOutputBlock      = 0x41555217; // 'AUR\x17': opt -> AuraAsioBlockCopy*

struct AuraAsioBlockCopy {
    float* outL;
    float* outR;
    long maxSamples;
    long copiedSamples;
};
