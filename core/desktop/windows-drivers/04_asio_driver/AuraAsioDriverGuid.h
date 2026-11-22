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

