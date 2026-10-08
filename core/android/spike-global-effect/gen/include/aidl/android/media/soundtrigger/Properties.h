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
class Properties {
public:
  typedef std::false_type fixed_size;
  static const char* descriptor;

  std::string implementor;
  std::string description;
  int32_t version = 0;
  std::string uuid;
  std::string supportedModelArch;
  int32_t maxSoundModels = 0;
  int32_t maxKeyPhrases = 0;
  int32_t maxUsers = 0;
  int32_t recognitionModes = 0;
  bool captureTransition = false;
  int32_t maxBufferMs = 0;
  bool concurrentCapture = false;
  bool triggerInEvent = false;
  int32_t powerConsumptionMw = 0;
  int32_t audioCapabilities = 0;

  binder_status_t readFromParcel(const AParcel* parcel);
  binder_status_t writeToParcel(AParcel* parcel) const;

  inline bool operator==(const Properties& _rhs) const {
    return std::tie(implementor, description, version, uuid, supportedModelArch, maxSoundModels, maxKeyPhrases, maxUsers, recognitionModes, captureTransition, maxBufferMs, concurrentCapture, triggerInEvent, powerConsumptionMw, audioCapabilities) == std::tie(_rhs.implementor, _rhs.description, _rhs.version, _rhs.uuid, _rhs.supportedModelArch, _rhs.maxSoundModels, _rhs.maxKeyPhrases, _rhs.maxUsers, _rhs.recognitionModes, _rhs.captureTransition, _rhs.maxBufferMs, _rhs.concurrentCapture, _rhs.triggerInEvent, _rhs.powerConsumptionMw, _rhs.audioCapabilities);
  }
  inline bool operator<(const Properties& _rhs) const {
    return std::tie(implementor, description, version, uuid, supportedModelArch, maxSoundModels, maxKeyPhrases, maxUsers, recognitionModes, captureTransition, maxBufferMs, concurrentCapture, triggerInEvent, powerConsumptionMw, audioCapabilities) < std::tie(_rhs.implementor, _rhs.description, _rhs.version, _rhs.uuid, _rhs.supportedModelArch, _rhs.maxSoundModels, _rhs.maxKeyPhrases, _rhs.maxUsers, _rhs.recognitionModes, _rhs.captureTransition, _rhs.maxBufferMs, _rhs.concurrentCapture, _rhs.triggerInEvent, _rhs.powerConsumptionMw, _rhs.audioCapabilities);
  }
  inline bool operator!=(const Properties& _rhs) const {
    return !(*this == _rhs);
  }
  inline bool operator>(const Properties& _rhs) const {
    return _rhs < *this;
  }
  inline bool operator>=(const Properties& _rhs) const {
    return !(*this < _rhs);
  }
  inline bool operator<=(const Properties& _rhs) const {
    return !(_rhs < *this);
  }

  static const ::ndk::parcelable_stability_t _aidl_stability = ::ndk::STABILITY_VINTF;
  inline std::string toString() const {
    std::ostringstream _aidl_os;
    _aidl_os << "Properties{";
    _aidl_os << "implementor: " << ::android::internal::ToString(implementor);
    _aidl_os << ", description: " << ::android::internal::ToString(description);
    _aidl_os << ", version: " << ::android::internal::ToString(version);
    _aidl_os << ", uuid: " << ::android::internal::ToString(uuid);
    _aidl_os << ", supportedModelArch: " << ::android::internal::ToString(supportedModelArch);
    _aidl_os << ", maxSoundModels: " << ::android::internal::ToString(maxSoundModels);
    _aidl_os << ", maxKeyPhrases: " << ::android::internal::ToString(maxKeyPhrases);
    _aidl_os << ", maxUsers: " << ::android::internal::ToString(maxUsers);
    _aidl_os << ", recognitionModes: " << ::android::internal::ToString(recognitionModes);
    _aidl_os << ", captureTransition: " << ::android::internal::ToString(captureTransition);
    _aidl_os << ", maxBufferMs: " << ::android::internal::ToString(maxBufferMs);
    _aidl_os << ", concurrentCapture: " << ::android::internal::ToString(concurrentCapture);
    _aidl_os << ", triggerInEvent: " << ::android::internal::ToString(triggerInEvent);
    _aidl_os << ", powerConsumptionMw: " << ::android::internal::ToString(powerConsumptionMw);
    _aidl_os << ", audioCapabilities: " << ::android::internal::ToString(audioCapabilities);
    _aidl_os << "}";
    return _aidl_os.str();
  }
};
}  // namespace soundtrigger
}  // namespace media
}  // namespace android
}  // namespace aidl
