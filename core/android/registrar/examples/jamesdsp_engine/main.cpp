/*
 * main.cpp — libjdsp.so: full JamesDSP engine on the registrar core.
 *
 * Same three extern "C" exports as libspikeeq.so (HAL dlsym contract),
 * but the DSP backend is libjamesdsp (vendor-src/libjamesdsp) instead of
 * the biquad test engine.
 *
 * Impl UUID is fresh (JamesDSP engine); type UUID stays the standard
 * equalizer type used by the spike deployment. The device-side
 * audio_effects_config.xml must register the impl uuid below before
 * queryEffect/createEffect can reach this library.
 */
#include <registrar/Exports.h>

#include "JamesDspEngine.h"

using jamesdsp::registrar::RegistrarEntry;

/* Fresh impl uuid for the JamesDSP engine (do NOT reuse spike's). */
static const char* kImplUuid = "6d5d0f7a-3c1e-4a9b-8b2d-9f0a1c2d3e4f";
/* Standard equalizer effect type uuid (same as spike). */
static const char* kTypeUuid = "0bed4300-ddd6-11db-8f34-0002a5d5c51b";

static RegistrarEntry& entry() {
    static RegistrarEntry e(
            kImplUuid, kTypeUuid, "JamesDSP Full Engine", "JamesDSP Core",
            [] { return std::static_pointer_cast<jamesdsp::registrar::IAudioEngine>(
                         std::make_shared<jamesdsp::registrar::JamesDspEngine>()); });
    return e;
}

extern "C" JDSP_REGISTRAR_EXPORT binder_exception_t createEffect(
        const ::aidl::android::media::audio::common::AudioUuid* in_impl_uuid,
        std::shared_ptr<::aidl::android::hardware::audio::effect::IEffect>* instance_ptr) {
    return entry().createEffect(in_impl_uuid, instance_ptr);
}

extern "C" JDSP_REGISTRAR_EXPORT binder_exception_t destroyEffect(
        const std::shared_ptr<::aidl::android::hardware::audio::effect::IEffect>& in_handle) {
    return entry().destroyEffect(in_handle);
}

extern "C" JDSP_REGISTRAR_EXPORT binder_exception_t queryEffect(
        const ::aidl::android::media::audio::common::AudioUuid* in_impl_uuid,
        ::aidl::android::hardware::audio::effect::Descriptor* _aidl_return) {
    return entry().queryEffect(in_impl_uuid, _aidl_return);
}
