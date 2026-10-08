/*
 * This file is auto-generated.  DO NOT MODIFY.
 * Using: D:\\myPrograms\\AndroidDevelop\\Android-SDK\\build-tools\\37.0.0\\aidl.exe --lang=ndk --structured --stability=vintf --version 4 --min_sdk_version=34 -o D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\gen-src -h D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\include -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\audio\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\common\\Void.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Capability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Classification.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationConfig.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationMetadata.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationMetadataList.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassifierCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Configuration.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\IEraserCallback.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Mode.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\RemixerCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\SeparatorCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\SoundClassification.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\AudioCapabilities.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ConfidenceLevel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ModelParameter.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ModelParameterRange.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Phrase.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseRecognitionEvent.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseRecognitionExtra.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseSoundModel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Properties.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionConfig.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionEvent.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionMode.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionStatus.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\SoundModel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\SoundModelType.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Status.aidl
 *
 * DO NOT CHECK THIS FILE INTO A CODE TREE (e.g. git, etc..).
 * ALWAYS GENERATE THIS FILE FROM UPDATED AIDL COMPILER
 * AS A BUILD INTERMEDIATE ONLY. THIS IS NOT SOURCE CODE.
 */
#pragma once

#include "aidl/android/media/audio/eraser/IEraserCallback.h"

#include <android/binder_ibinder.h>
#include <cassert>

#ifndef __BIONIC__
#ifndef __assert2
#define __assert2(a,b,c,d) ((void)0)
#endif
#endif

namespace aidl {
namespace android {
namespace media {
namespace audio {
namespace eraser {
class BnEraserCallback : public ::ndk::BnCInterface<IEraserCallback> {
public:
  BnEraserCallback();
  virtual ~BnEraserCallback();
  ::ndk::ScopedAStatus getInterfaceVersion(int32_t* _aidl_return) final;
protected:
  ::ndk::SpAIBinder createBinder() override;
private:
};
class IEraserCallbackDelegator : public BnEraserCallback {
public:
  explicit IEraserCallbackDelegator(const std::shared_ptr<IEraserCallback> &impl) : _impl(impl) {
     int32_t _impl_ver = 0;
     if (!impl->getInterfaceVersion(&_impl_ver).isOk()) {;
        __assert2(__FILE__, __LINE__, __PRETTY_FUNCTION__, "Delegator failed to get version of the implementation.");
     }
     if (_impl_ver != IEraserCallback::version) {
        __assert2(__FILE__, __LINE__, __PRETTY_FUNCTION__, "Mismatched versions of delegator and implementation is not allowed.");
     }
  }

  ::ndk::ScopedAStatus onClassifierUpdate(int32_t in_soundSourceId, const ::aidl::android::media::audio::eraser::ClassificationMetadataList& in_metadata) override {
    return _impl->onClassifierUpdate(in_soundSourceId, in_metadata);
  }
protected:
private:
  std::shared_ptr<IEraserCallback> _impl;
};

}  // namespace eraser
}  // namespace audio
}  // namespace media
}  // namespace android
}  // namespace aidl
