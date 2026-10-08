/*
 * AidlEffectBase.h — Android-agnostic effect skeleton for AIDL HALs (Android 14+).
 *
 * Owns: state machine (INIT/IDLE/PROCESSING/DRAINING), FMQ data plane
 * (status/input/output), worker thread, common-parameter handling.
 * Delegates actual DSP to an IAudioEngine provided by the library.
 *
 * Library side only needs:
 *   1. an IAudioEngine implementation,
 *   2. one RegistrarEntry (see Exports.h) wired to the three extern "C" exports.
 */
#pragma once

#include <aidl/android/hardware/audio/effect/BnEffect.h>
#include <fmq/AidlMessageQueue.h>
#include <fmq/EventFlag.h>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <registrar/Engine.h>

namespace jamesdsp::registrar {

using ::aidl::android::hardware::audio::effect::BnEffect;
using ::aidl::android::hardware::audio::effect::CommandId;
using ::aidl::android::hardware::audio::effect::Descriptor;
using ::aidl::android::hardware::audio::effect::IEffect;
using ::aidl::android::hardware::audio::effect::Parameter;
using ::aidl::android::hardware::audio::effect::State;
using ::aidl::android::media::audio::common::AudioChannelLayout;
using ::aidl::android::media::audio::common::AudioUuid;
using ::aidl::android::hardware::common::fmq::SynchronizedReadWrite;

class AidlEffectBase : public BnEffect {
public:
    /* desc: descriptor returned by getDescriptor(); engine: DSP backend. */
    AidlEffectBase(const Descriptor& desc, std::shared_ptr<IAudioEngine> engine);
    ~AidlEffectBase() override;

    /* --- IEffect --- */
    ::ndk::ScopedAStatus open(const Parameter::Common& common,
                              const std::optional<Parameter::Specific>& specific,
                              OpenEffectReturn* _aidl_return) override;
    ::ndk::ScopedAStatus close() override;
    ::ndk::ScopedAStatus getDescriptor(Descriptor* _aidl_return) override;
    ::ndk::ScopedAStatus command(CommandId in_commandId) override;
    ::ndk::ScopedAStatus getState(State* _aidl_return) override;
    ::ndk::ScopedAStatus setParameter(const Parameter& in_param) override;
    ::ndk::ScopedAStatus getParameter(const Parameter::Id& in_paramId,
                                      Parameter* _aidl_return) override;
    ::ndk::ScopedAStatus reopen(OpenEffectReturn* _aidl_return) override;

    /* Subclass hook: respond to library-specific Parameter::Specific.
     * Default: EX_ILLEGAL_ARGUMENT. */
    virtual ::ndk::ScopedAStatus setParameterSpecific(const Parameter::Specific& specific);
    virtual ::ndk::ScopedAStatus getParameterSpecific(const Parameter::Id& id,
                                                      Parameter::Specific* specific);

    /* Log tag / instance label. */
    const char* effectName() const { return mName.c_str(); }

private:
    using StatusMQ = ::android::AidlMessageQueue<IEffect::Status, SynchronizedReadWrite>;
    using DataMQ = ::android::AidlMessageQueue<float, SynchronizedReadWrite>;
    using EventFlag = ::android::hardware::EventFlag;

    void threadLoop();
    void processOnce();
    int channelCount(const AudioChannelLayout& layout);

    const Descriptor mDescriptor;
    const std::string mName;
    std::shared_ptr<IAudioEngine> mEngine;

    std::mutex mMutex;
    State mState = State::INIT;

    Parameter::Common mCommon;
    int32_t mAudioMode = 0;
    int32_t mAudioSource = 0;
    Parameter::VolumeStereo mVolumeStereo;

    std::shared_ptr<StatusMQ> mStatusMQ;
    std::shared_ptr<DataMQ> mInputMQ;
    std::shared_ptr<DataMQ> mOutputMQ;
    EventFlag* mEfGroup = nullptr;
    std::vector<float> mWorkBuffer;

    std::thread mThread;
    std::mutex mThreadMutex;
    std::condition_variable mCv;
    std::atomic<bool> mStop{true};
    std::atomic<bool> mExit{false};
};

}  // namespace jamesdsp::registrar
