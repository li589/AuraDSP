/*
 * Exports.cpp — RegistrarEntry implementation + shared uuid helper.
 */
#define LOG_TAG "JDSP_Registrar"
#include <registrar/Exports.h>

#include <aidl/android/hardware/audio/effect/Flags.h>
#include <utils/Log.h>

#include <cstdio>
#include <cstring>

namespace jamesdsp::registrar {

using ::aidl::android::hardware::audio::effect::Descriptor;
using ::aidl::android::hardware::audio::effect::Flags;
using ::aidl::android::hardware::audio::effect::IEffect;
using ::aidl::android::media::audio::common::AudioUuid;

AudioUuid makeUuid(const char* str) {
    AudioUuid u{};
    uint32_t v[4] = {0};
    unsigned node[6] = {0};
    if (std::sscanf(str, "%8x-%4x-%4x-%4x-%2x%2x%2x%2x%2x%2x", &v[0], &v[1], &v[2], &v[3],
                    &node[0], &node[1], &node[2], &node[3], &node[4], &node[5]) == 10) {
        u.timeLow = static_cast<int32_t>(v[0]);
        u.timeMid = static_cast<int32_t>(v[1]);
        u.timeHiAndVersion = static_cast<int32_t>(v[2]);
        u.clockSeq = static_cast<int32_t>(v[3]);
        for (int i = 0; i < 6; i++) u.node.push_back(static_cast<uint8_t>(node[i]));
    }
    return u;
}

RegistrarEntry::RegistrarEntry(const char* implUuidStr, const char* typeUuidStr,
                               const char* name, const char* implementor,
                               EngineFactory engineFactory)
    : mImplUuid(makeUuid(implUuidStr)), mEngineFactory(std::move(engineFactory)) {
    Descriptor& d = mDescriptor;
    d.common.id.type = makeUuid(typeUuidStr);
    d.common.id.uuid = mImplUuid;
    d.common.flags.type = Flags::Type::INSERT;
    d.common.flags.insert = Flags::Insert::FIRST;
    d.common.flags.volume = Flags::Volume::CTRL;
    d.common.name = name;
    d.common.implementor = implementor;
}

binder_exception_t RegistrarEntry::createEffect(
        const AudioUuid* in_impl_uuid, std::shared_ptr<IEffect>* instance_ptr) {
    if (!in_impl_uuid || *in_impl_uuid != mImplUuid) {
        ALOGE("%s createEffect: unsupported uuid", mDescriptor.common.name.c_str());
        return EX_ILLEGAL_ARGUMENT;
    }
    if (!instance_ptr) {
        ALOGE("%s createEffect: null out param", mDescriptor.common.name.c_str());
        return EX_ILLEGAL_ARGUMENT;
    }
    *instance_ptr = ::ndk::SharedRefBase::make<AidlEffectBase>(mDescriptor, mEngineFactory());
    ALOGI("%s createEffect: instance %p created", mDescriptor.common.name.c_str(),
          instance_ptr->get());
    return EX_NONE;
}

binder_exception_t RegistrarEntry::destroyEffect(const std::shared_ptr<IEffect>& in_handle) {
    if (!in_handle) {
        return EX_ILLEGAL_ARGUMENT;
    }
    ALOGI("destroyEffect: releasing effect instance");
    in_handle->close();
    return EX_NONE;
}

binder_exception_t RegistrarEntry::queryEffect(const AudioUuid* in_impl_uuid,
                                               Descriptor* _aidl_return) {
    if (!in_impl_uuid || *in_impl_uuid != mImplUuid) {
        ALOGE("queryEffect: unsupported uuid");
        return EX_ILLEGAL_ARGUMENT;
    }
    if (!_aidl_return) {
        return EX_ILLEGAL_ARGUMENT;
    }
    *_aidl_return = mDescriptor;
    ALOGI("queryEffect: %s descriptor returned", mDescriptor.common.name.c_str());
    return EX_NONE;
}

}  // namespace jamesdsp::registrar
