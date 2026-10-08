/*
 * SpikeExports.cpp - extern "C" exports consumed by the effects HAL
 * (AOSP EffectFactory ABI, audio/aidl/default/include/effect-impl/EffectTypes.h):
 *
 *   binder_exception_t createEffect(const AudioUuid*, std::shared_ptr<IEffect>*);
 *   binder_exception_t destroyEffect(const std::shared_ptr<IEffect>&);
 *   binder_exception_t queryEffect(const AudioUuid*, Descriptor*);
 */
#define LOG_TAG "AHAL_SpikeEQ"

#include <aidl/android/hardware/audio/effect/IEffect.h>
#include <aidl/android/media/audio/common/AudioUuid.h>
#include <android/binder_status.h>
#include <utils/Log.h>

#include "SpikeEffect.h"

using ::aidl::android::hardware::audio::effect::Descriptor;
using ::aidl::android::hardware::audio::effect::IEffect;
using ::aidl::android::hardware::audio::effect::SpikeEffect;
using ::aidl::android::media::audio::common::AudioUuid;

#define SPIKE_EXPORT __attribute__((visibility("default")))

extern "C" SPIKE_EXPORT binder_exception_t createEffect(const AudioUuid* in_impl_uuid,
                                                        std::shared_ptr<IEffect>* instance_ptr) {
    if (!in_impl_uuid || *in_impl_uuid != SpikeEffect::kImplUuid) {
        ALOGE("createEffect: unsupported uuid");
        return EX_ILLEGAL_ARGUMENT;
    }
    if (!instance_ptr) {
        ALOGE("createEffect: null out param");
        return EX_ILLEGAL_ARGUMENT;
    }
    *instance_ptr = ::ndk::SharedRefBase::make<SpikeEffect>();
    ALOGI("createEffect: SpikeEQ instance %p created", instance_ptr->get());
    return EX_NONE;
}

extern "C" SPIKE_EXPORT binder_exception_t destroyEffect(const std::shared_ptr<IEffect>& in_handle) {
    if (!in_handle) {
        return EX_ILLEGAL_ARGUMENT;
    }
    ALOGI("destroyEffect: releasing SpikeEQ instance");
    in_handle->close();
    return EX_NONE;
}

extern "C" SPIKE_EXPORT binder_exception_t queryEffect(const AudioUuid* in_impl_uuid,
                                          Descriptor* _aidl_return) {
    if (!in_impl_uuid || *in_impl_uuid != SpikeEffect::kImplUuid) {
        ALOGE("queryEffect: unsupported uuid");
        return EX_ILLEGAL_ARGUMENT;
    }
    if (!_aidl_return) {
        return EX_ILLEGAL_ARGUMENT;
    }
    *_aidl_return = SpikeEffect::kDescriptor;
    ALOGI("queryEffect: SpikeEQ descriptor returned");
    return EX_NONE;
}
