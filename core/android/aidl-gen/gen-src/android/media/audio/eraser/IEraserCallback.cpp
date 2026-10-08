/*
 * This file is auto-generated.  DO NOT MODIFY.
 * Using: D:\\myPrograms\\AndroidDevelop\\Android-SDK\\build-tools\\37.0.0\\aidl.exe --lang=ndk --structured --stability=vintf --version 4 --min_sdk_version=34 -o D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\gen-src -h D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\gen\\include -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\audio\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\android_hardware_interfaces\\common\\fmq\\aidl -ID:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\common\\Void.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Capability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Classification.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationConfig.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationMetadata.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassificationMetadataList.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\ClassifierCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Configuration.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\IEraserCallback.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\Mode.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\RemixerCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\SeparatorCapability.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\audio\\eraser\\SoundClassification.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\AudioCapabilities.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ConfidenceLevel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ModelParameter.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\ModelParameterRange.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Phrase.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseRecognitionEvent.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseRecognitionExtra.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\PhraseSoundModel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Properties.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionConfig.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionEvent.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionMode.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\RecognitionStatus.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\SoundModel.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\SoundModelType.aidl D:\\temp_desktop\\Proj\\JamesDSP\\core\\android\\spike-global-effect\\aidl-src\\platform_system_hardware_interfaces\\media\\aidl\\android\\media\\soundtrigger\\Status.aidl
 *
 * DO NOT CHECK THIS FILE INTO A CODE TREE (e.g. git, etc..).
 * ALWAYS GENERATE THIS FILE FROM UPDATED AIDL COMPILER
 * AS A BUILD INTERMEDIATE ONLY. THIS IS NOT SOURCE CODE.
 */
#include "aidl/android/media/audio/eraser/IEraserCallback.h"

#include <cstdint>
#include <android/binder_parcel.h>
#include <android/binder_parcel_utils.h>
#include <android/binder_status.h>
#include <aidl/android/media/audio/eraser/BnEraserCallback.h>
#include <aidl/android/media/audio/eraser/BpEraserCallback.h>

namespace aidl {
namespace android {
namespace media {
namespace audio {
namespace eraser {
static binder_status_t _aidl_android_media_audio_eraser_IEraserCallback_onTransact(AIBinder* _aidl_binder, transaction_code_t _aidl_code, const AParcel* _aidl_in, AParcel* _aidl_out) {
  (void)_aidl_in;
  (void)_aidl_out;
  binder_status_t _aidl_ret_status = STATUS_UNKNOWN_TRANSACTION;
  std::shared_ptr<BnEraserCallback> _aidl_impl = std::static_pointer_cast<BnEraserCallback>(::ndk::ICInterface::asInterface(_aidl_binder));
  switch (_aidl_code) {
    case (FIRST_CALL_TRANSACTION + 0 /*onClassifierUpdate*/): {
      int32_t in_soundSourceId;
      ::aidl::android::media::audio::eraser::ClassificationMetadataList in_metadata;

      _aidl_ret_status = ::ndk::AParcel_readData(_aidl_in, &in_soundSourceId);
      if (_aidl_ret_status != STATUS_OK) break;

      _aidl_ret_status = ::ndk::AParcel_readData(_aidl_in, &in_metadata);
      if (_aidl_ret_status != STATUS_OK) break;

      ::ndk::ScopedAStatus _aidl_status = _aidl_impl->onClassifierUpdate(in_soundSourceId, in_metadata);
      _aidl_ret_status = STATUS_OK;
      break;
    }
    case (FIRST_CALL_TRANSACTION + 16777214 /*getInterfaceVersion*/): {
      int32_t _aidl_return;

      ::ndk::ScopedAStatus _aidl_status = _aidl_impl->getInterfaceVersion(&_aidl_return);
      _aidl_ret_status = AParcel_writeStatusHeader(_aidl_out, _aidl_status.get());
      if (_aidl_ret_status != STATUS_OK) break;

      if (!AStatus_isOk(_aidl_status.get())) break;

      _aidl_ret_status = ::ndk::AParcel_writeData(_aidl_out, _aidl_return);
      if (_aidl_ret_status != STATUS_OK) break;

      break;
    }
  }
  return _aidl_ret_status;
}

static AIBinder_Class* get_g_aidl_android_media_audio_eraser_IEraserCallback_clazz() {
  static AIBinder_Class* clazz = ::ndk::ICInterface::defineClass(IEraserCallback::descriptor, _aidl_android_media_audio_eraser_IEraserCallback_onTransact, nullptr, 0);
  return clazz;
}

BpEraserCallback::BpEraserCallback(const ::ndk::SpAIBinder& binder) : BpCInterface(binder) {}
BpEraserCallback::~BpEraserCallback() {}

::ndk::ScopedAStatus BpEraserCallback::onClassifierUpdate(int32_t in_soundSourceId, const ::aidl::android::media::audio::eraser::ClassificationMetadataList& in_metadata) {
  binder_status_t _aidl_ret_status = STATUS_OK;
  ::ndk::ScopedAStatus _aidl_status;
  ::ndk::ScopedAParcel _aidl_in;
  ::ndk::ScopedAParcel _aidl_out;

  _aidl_ret_status = AIBinder_prepareTransaction(asBinderReference().get(), _aidl_in.getR());
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  _aidl_ret_status = ::ndk::AParcel_writeData(_aidl_in.get(), in_soundSourceId);
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  _aidl_ret_status = ::ndk::AParcel_writeData(_aidl_in.get(), in_metadata);
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  _aidl_ret_status = AIBinder_transact(
    asBinderReference().get(),
    (FIRST_CALL_TRANSACTION + 0 /*onClassifierUpdate*/),
    _aidl_in.getR(),
    _aidl_out.getR(),
    FLAG_ONEWAY
    #ifdef BINDER_STABILITY_SUPPORT
    | static_cast<int>(FLAG_PRIVATE_LOCAL)
    #endif  // BINDER_STABILITY_SUPPORT
    );
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  _aidl_error:
  _aidl_status.set(AStatus_fromStatus(_aidl_ret_status));
  return _aidl_status;
}
::ndk::ScopedAStatus BpEraserCallback::getInterfaceVersion(int32_t* _aidl_return) {
  binder_status_t _aidl_ret_status = STATUS_OK;
  ::ndk::ScopedAStatus _aidl_status;
  if (_aidl_cached_version != -1) {
    *_aidl_return = _aidl_cached_version;
    _aidl_status.set(AStatus_fromStatus(_aidl_ret_status));
    return _aidl_status;
  }
  ::ndk::ScopedAParcel _aidl_in;
  ::ndk::ScopedAParcel _aidl_out;

  _aidl_ret_status = AIBinder_prepareTransaction(asBinderReference().get(), _aidl_in.getR());
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  _aidl_ret_status = AIBinder_transact(
    asBinderReference().get(),
    (FIRST_CALL_TRANSACTION + 16777214 /*getInterfaceVersion*/),
    _aidl_in.getR(),
    _aidl_out.getR(),
    0
    #ifdef BINDER_STABILITY_SUPPORT
    | static_cast<int>(FLAG_PRIVATE_LOCAL)
    #endif  // BINDER_STABILITY_SUPPORT
    );
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  _aidl_ret_status = AParcel_readStatusHeader(_aidl_out.get(), _aidl_status.getR());
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  if (!AStatus_isOk(_aidl_status.get())) goto _aidl_status_return;
  _aidl_ret_status = ::ndk::AParcel_readData(_aidl_out.get(), _aidl_return);
  if (_aidl_ret_status != STATUS_OK) goto _aidl_error;

  _aidl_cached_version = *_aidl_return;
  _aidl_error:
  _aidl_status.set(AStatus_fromStatus(_aidl_ret_status));
  _aidl_status_return:
  return _aidl_status;
}
// Source for BnEraserCallback
BnEraserCallback::BnEraserCallback() {}
BnEraserCallback::~BnEraserCallback() {}
::ndk::SpAIBinder BnEraserCallback::createBinder() {
  AIBinder* binder = AIBinder_new(get_g_aidl_android_media_audio_eraser_IEraserCallback_clazz(), static_cast<void*>(this));
  #ifdef BINDER_STABILITY_SUPPORT
  AIBinder_markVintfStability(binder);
  #endif  // BINDER_STABILITY_SUPPORT
  return ::ndk::SpAIBinder(binder);
}
::ndk::ScopedAStatus BnEraserCallback::getInterfaceVersion(int32_t* _aidl_return) {
  *_aidl_return = IEraserCallback::version;
  return ::ndk::ScopedAStatus(AStatus_newOk());
}
// Source for IEraserCallback
const char* IEraserCallback::descriptor = "android.media.audio.eraser.IEraserCallback";
IEraserCallback::IEraserCallback() {}
IEraserCallback::~IEraserCallback() {}


std::shared_ptr<IEraserCallback> IEraserCallback::fromBinder(const ::ndk::SpAIBinder& binder) {
  if (!AIBinder_associateClass(binder.get(), get_g_aidl_android_media_audio_eraser_IEraserCallback_clazz())) {
    #if __ANDROID_API__ >= 31
    const AIBinder_Class* originalClass = AIBinder_getClass(binder.get());
    if (originalClass == nullptr) return nullptr;
    if (0 == strcmp(AIBinder_Class_getDescriptor(originalClass), descriptor)) {
      return ::ndk::SharedRefBase::make<BpEraserCallback>(binder);
    }
    #endif
    return nullptr;
  }
  std::shared_ptr<::ndk::ICInterface> interface = ::ndk::ICInterface::asInterface(binder.get());
  if (interface) {
    return std::static_pointer_cast<IEraserCallback>(interface);
  }
  return ::ndk::SharedRefBase::make<BpEraserCallback>(binder);
}

binder_status_t IEraserCallback::writeToParcel(AParcel* parcel, const std::shared_ptr<IEraserCallback>& instance) {
  return AParcel_writeStrongBinder(parcel, instance ? instance->asBinder().get() : nullptr);
}
binder_status_t IEraserCallback::readFromParcel(const AParcel* parcel, std::shared_ptr<IEraserCallback>* instance) {
  ::ndk::SpAIBinder binder;
  binder_status_t status = AParcel_readStrongBinder(parcel, binder.getR());
  if (status != STATUS_OK) return status;
  *instance = IEraserCallback::fromBinder(binder);
  return STATUS_OK;
}
::ndk::ScopedAStatus IEraserCallbackDefault::onClassifierUpdate(int32_t /*in_soundSourceId*/, const ::aidl::android::media::audio::eraser::ClassificationMetadataList& /*in_metadata*/) {
  ::ndk::ScopedAStatus _aidl_status;
  _aidl_status.set(AStatus_fromStatus(STATUS_UNKNOWN_TRANSACTION));
  return _aidl_status;
}
::ndk::ScopedAStatus IEraserCallbackDefault::getInterfaceVersion(int32_t* _aidl_return) {
  *_aidl_return = 0;
  return ::ndk::ScopedAStatus(AStatus_newOk());
}
::ndk::SpAIBinder IEraserCallbackDefault::asBinder() {
  return ::ndk::SpAIBinder();
}
bool IEraserCallbackDefault::isRemote() {
  return false;
}
}  // namespace eraser
}  // namespace audio
}  // namespace media
}  // namespace android
}  // namespace aidl
