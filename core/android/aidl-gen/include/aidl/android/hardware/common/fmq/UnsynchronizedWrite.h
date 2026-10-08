/*
 * This file is auto-generated.  DO NOT MODIFY.
 * Using: D:\\myPrograms\\AndroidDevelop\\Android-SDK\\build-tools\\37.0.0\\aidl.exe --lang=ndk --structured --stability=vintf --version 1 --min_sdk_version=34 -o D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\gen-src -h D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\include -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\audio\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl\\android\\hardware\\common\\fmq\\GrantorDescriptor.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl\\android\\hardware\\common\\fmq\\MQDescriptor.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl\\android\\hardware\\common\\fmq\\SynchronizedReadWrite.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl\\android\\hardware\\common\\fmq\\UnsynchronizedWrite.aidl
 *
 * DO NOT CHECK THIS FILE INTO A CODE TREE (e.g. git, etc..).
 * ALWAYS GENERATE THIS FILE FROM UPDATED AIDL COMPILER
 * AS A BUILD INTERMEDIATE ONLY. THIS IS NOT SOURCE CODE.
 */
#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <android/binder_enums.h>
#ifdef BINDER_STABILITY_SUPPORT
#include <android/binder_stability.h>
#endif  // BINDER_STABILITY_SUPPORT

namespace aidl {
namespace android {
namespace hardware {
namespace common {
namespace fmq {
enum class UnsynchronizedWrite : int8_t {
  EMPTY = 0,
};

}  // namespace fmq
}  // namespace common
}  // namespace hardware
}  // namespace android
}  // namespace aidl
namespace aidl {
namespace android {
namespace hardware {
namespace common {
namespace fmq {
[[nodiscard]] static inline std::string toString(UnsynchronizedWrite val) {
  switch(val) {
  case UnsynchronizedWrite::EMPTY:
    return "EMPTY";
  default:
    return std::to_string(static_cast<int8_t>(val));
  }
}
}  // namespace fmq
}  // namespace common
}  // namespace hardware
}  // namespace android
}  // namespace aidl
namespace ndk {
namespace internal {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc++17-extensions"
template <>
constexpr inline std::array<aidl::android::hardware::common::fmq::UnsynchronizedWrite, 1> enum_values<aidl::android::hardware::common::fmq::UnsynchronizedWrite> = {
  aidl::android::hardware::common::fmq::UnsynchronizedWrite::EMPTY,
};
#pragma clang diagnostic pop
}  // namespace internal
}  // namespace ndk
