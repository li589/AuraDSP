/*
 * This file is auto-generated.  DO NOT MODIFY.
 * Using: D:\\myPrograms\\AndroidDevelop\\Android-SDK\\build-tools\\37.0.0\\aidl.exe --lang=ndk --structured --stability=vintf --version 4 --min_sdk_version=34 -o D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\gen-src -h D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\include -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\audio\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\common\\Void.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Capability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Classification.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationConfig.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationMetadata.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationMetadataList.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassifierCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Configuration.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\IEraserCallback.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Mode.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\RemixerCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\SeparatorCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\SoundClassification.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\AudioCapabilities.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ConfidenceLevel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ModelParameter.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ModelParameterRange.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Phrase.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseRecognitionEvent.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseRecognitionExtra.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseSoundModel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Properties.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionConfig.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionEvent.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionMode.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionStatus.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\SoundModel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\SoundModelType.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Status.aidl
 *
 * DO NOT CHECK THIS FILE INTO A CODE TREE (e.g. git, etc..).
 * ALWAYS GENERATE THIS FILE FROM UPDATED AIDL COMPILER
 * AS A BUILD INTERMEDIATE ONLY. THIS IS NOT SOURCE CODE.
 */
#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <android/binder_interface_utils.h>
#include <android/binder_parcelable_utils.h>
#include <android/binder_to_string.h>
#ifdef BINDER_STABILITY_SUPPORT
#include <android/binder_stability.h>
#endif  // BINDER_STABILITY_SUPPORT

namespace aidl {
namespace android {
namespace media {
namespace soundtrigger {
class Phrase {
public:
  typedef std::false_type fixed_size;
  static const char* descriptor;

  int32_t id = 0;
  int32_t recognitionModes = 0;
  std::vector<int32_t> users;
  std::string locale;
  std::string text;

  binder_status_t readFromParcel(const AParcel* parcel);
  binder_status_t writeToParcel(AParcel* parcel) const;

  inline bool operator==(const Phrase& _rhs) const {
    return std::tie(id, recognitionModes, users, locale, text) == std::tie(_rhs.id, _rhs.recognitionModes, _rhs.users, _rhs.locale, _rhs.text);
  }
  inline bool operator<(const Phrase& _rhs) const {
    return std::tie(id, recognitionModes, users, locale, text) < std::tie(_rhs.id, _rhs.recognitionModes, _rhs.users, _rhs.locale, _rhs.text);
  }
  inline bool operator!=(const Phrase& _rhs) const {
    return !(*this == _rhs);
  }
  inline bool operator>(const Phrase& _rhs) const {
    return _rhs < *this;
  }
  inline bool operator>=(const Phrase& _rhs) const {
    return !(*this < _rhs);
  }
  inline bool operator<=(const Phrase& _rhs) const {
    return !(_rhs < *this);
  }

  static const ::ndk::parcelable_stability_t _aidl_stability = ::ndk::STABILITY_VINTF;
  inline std::string toString() const {
    std::ostringstream _aidl_os;
    _aidl_os << "Phrase{";
    _aidl_os << "id: " << ::android::internal::ToString(id);
    _aidl_os << ", recognitionModes: " << ::android::internal::ToString(recognitionModes);
    _aidl_os << ", users: " << ::android::internal::ToString(users);
    _aidl_os << ", locale: " << ::android::internal::ToString(locale);
    _aidl_os << ", text: " << ::android::internal::ToString(text);
    _aidl_os << "}";
    return _aidl_os.str();
  }
};
}  // namespace soundtrigger
}  // namespace media
}  // namespace android
}  // namespace aidl
