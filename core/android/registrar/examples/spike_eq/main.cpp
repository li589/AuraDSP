/*
 * main.cpp — SpikeEQ library built on the JamesDSP registrar core.
 * Produces libspikeeq.so with the exact three extern "C" exports the
 * effects HAL dlsym's. UUIDs match the deployed audio_effects_config.xml.
 */
#include <registrar/Exports.h>

#include "SpikeEqEngine.h"

using jamesdsp::registrar::RegistrarEntry;

/* Same impl uuid as the spike deployment (xml already registers it). */
static const char* kImplUuid = "8e73f7a1-3c92-4f6b-9d5e-7a1b2c3d4e5f";
/* Standard equalizer effect type uuid. */
static const char* kTypeUuid = "0bed4300-ddd6-11db-8f34-0002a5d5c51b";

static RegistrarEntry& entry() {
    static RegistrarEntry e(
            kImplUuid, kTypeUuid, "SpikeEQ Core", "JamesDSP Core",
            [] { return std::static_pointer_cast<jamesdsp::registrar::IAudioEngine>(
                         std::make_shared<jamesdsp::examples::SpikeEqEngine>()); });
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
