/*
 * Exports.h — extern "C" export factory for AIDL effect libraries.
 *
 * HAL dlsym contract (AOSP audio/aidl/default/include/effect-impl/EffectTypes.h):
 *   binder_exception_t createEffect(const AudioUuid*, std::shared_ptr<IEffect>*);
 *   binder_exception_t destroyEffect(const std::shared_ptr<IEffect>&);
 *   binder_exception_t queryEffect(const AudioUuid*, Descriptor*);
 *
 * Library wiring example (see examples/spike_eq/main.cpp):
 *
 *   static RegistrarEntry& entry() {
 *       static RegistrarEntry e("8e73f7a1-...", "0bed4300-ddd6-...", "MyEffect",
 *                               "MyCompany", [] { return std::make_shared<MyEngine>(); });
 *       return e;
 *   }
 *   extern "C" SPIKE_EXPORT binder_exception_t createEffect(const AudioUuid* u,
 *                                 std::shared_ptr<IEffect>* o) { return entry().createEffect(u, o); }
 *   ...
 */
#pragma once

#include <aidl/android/hardware/audio/effect/BnEffect.h>
#include <android/binder_status.h>

#include <functional>
#include <memory>
#include <string>

#include <registrar/AidlEffectBase.h>
#include <registrar/Engine.h>

#define JDSP_REGISTRAR_EXPORT __attribute__((visibility("default")))

namespace jamesdsp::registrar {

/* Parse "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" into an AIDL AudioUuid. */
::aidl::android::media::audio::common::AudioUuid makeUuid(const char* str);

class RegistrarEntry {
public:
    using EngineFactory = std::function<std::shared_ptr<IAudioEngine>()>;

    /* flags: pass 0 for defaults (INSERT / FIRST / VOLUME_CTRL). */
    RegistrarEntry(const char* implUuidStr, const char* typeUuidStr, const char* name,
                   const char* implementor, EngineFactory engineFactory);

    /* Free functions expected by the HAL dlsym contract. */
    binder_exception_t createEffect(
            const ::aidl::android::media::audio::common::AudioUuid* in_impl_uuid,
            std::shared_ptr<::aidl::android::hardware::audio::effect::IEffect>* instance_ptr);
    binder_exception_t destroyEffect(
            const std::shared_ptr<::aidl::android::hardware::audio::effect::IEffect>& in_handle);
    binder_exception_t queryEffect(
            const ::aidl::android::media::audio::common::AudioUuid* in_impl_uuid,
            ::aidl::android::hardware::audio::effect::Descriptor* _aidl_return);

    const ::aidl::android::media::audio::common::AudioUuid& implUuid() const { return mImplUuid; }

private:
    ::aidl::android::media::audio::common::AudioUuid mImplUuid;
    ::aidl::android::hardware::audio::effect::Descriptor mDescriptor;
    EngineFactory mEngineFactory;
};

}  // namespace jamesdsp::registrar
