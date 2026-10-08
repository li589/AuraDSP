/*
 * SpikeEffect.h - AIDL-native spike effect for JamesDSP (Android 14+/16)
 *
 * Minimal IEffect implementation proving that a third-party DSP can attach
 * to the AIDL effects HAL chain on Android 16:
 *   - Effect V3 NDK backend, VINTF stability
 *   - FMQ data plane (status / input / output), float32 samples
 *   - Worker thread running a peaking biquad EQ (1 kHz +12 dB)
 *
 * Exports (extern "C", per AOSP EffectFactory ABI):
 *   createEffect / queryEffect / destroyEffect
 */
#pragma once

#include <aidl/android/hardware/audio/effect/BnEffect.h>
#include <aidl/android/media/audio/common/AudioUuid.h>
#include <fmq/AidlMessageQueue.h>
#include <fmq/EventFlag.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

namespace aidl::android::hardware::audio::effect {

/* Parse "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" into AudioUuid. */
::aidl::android::media::audio::common::AudioUuid makeUuid(const char* str);

class SpikeEffect : public BnEffect {
public:
    SpikeEffect() = default;
    ~SpikeEffect() override;

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

    static const Descriptor kDescriptor;
    static const ::aidl::android::media::audio::common::AudioUuid kImplUuid;

private:
    using StatusMQ = ::android::AidlMessageQueue<
            IEffect::Status, ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>;
    using DataMQ = ::android::AidlMessageQueue<
            float, ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>;
    using EventFlag = ::android::hardware::EventFlag;
    using AndroidStatus = ::android::status_t;

    void threadLoop();
    void processOnce();
    void resetBiquad();
    void biquadProcess(float* data, size_t frames, int channels);
    int channelCount(const ::aidl::android::media::audio::common::AudioChannelLayout& layout);

    std::mutex mMutex;
    State mState = State::INIT;

    Parameter::Common mCommon;
    // Common parameter storage for getParameter round-trips.
    int32_t mAudioMode = 0;
    int32_t mAudioSource = 0;
    Parameter::VolumeStereo mVolumeStereo;

    std::shared_ptr<StatusMQ> mStatusMQ;
    std::shared_ptr<DataMQ> mInputMQ;
    std::shared_ptr<DataMQ> mOutputMQ;
    ::android::hardware::EventFlag* mEfGroup = nullptr;
    std::vector<float> mWorkBuffer;

    std::thread mThread;
    std::mutex mThreadMutex;
    std::condition_variable mCv;
    std::atomic<bool> mStop{true};
    std::atomic<bool> mExit{false};

    // Peaking biquad (RBJ cookbook), per-channel state.
    double mCoefA0 = 1.0, mCoefA1 = 0.0, mCoefA2 = 0.0;
    double mCoefB0 = 1.0, mCoefB1 = 0.0, mCoefB2 = 0.0;
    float mX1[8] = {}, mX2[8] = {}, mY1[8] = {}, mY2[8] = {};
};

}  // namespace aidl::android::hardware::audio::effect
