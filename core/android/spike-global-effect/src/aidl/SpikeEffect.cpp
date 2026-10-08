/*
 * SpikeEffect.cpp - AIDL-native spike effect implementation.
 * Structure mirrors AOSP audio/aidl/default (EffectImpl/EffectContext/EffectThread)
 * but is self-contained: no dependency on libbase/libcutils/libutils beyond the
 * small stubs compiled into this .so.
 */
#define LOG_TAG "AHAL_SpikeEQ"
#include "SpikeEffect.h"

#include <aidl/android/hardware/audio/effect/Descriptor.h>
#include <aidl/android/media/audio/common/AudioChannelLayout.h>
#include <aidl/android/media/audio/common/AudioConfig.h>
#include <aidl/android/media/audio/common/PcmType.h>
#include <fmq/AidlMessageQueue.h>
#include <utils/Log.h>

#include <cmath>
#include <cstring>

using ::aidl::android::hardware::audio::effect::CommandId;
using ::aidl::android::hardware::audio::effect::Descriptor;
using ::aidl::android::hardware::audio::effect::IEffect;
using ::aidl::android::hardware::audio::effect::Parameter;
using ::aidl::android::hardware::audio::effect::SpikeEffect;
using ::aidl::android::hardware::audio::effect::State;
using ::aidl::android::media::audio::common::AudioChannelLayout;
using ::aidl::android::media::audio::common::AudioUuid;
using ::aidl::android::media::audio::common::PcmType;

/* Constants aligned with system/audio_effects/aidl_effects_utils.h */
static constexpr uint32_t kEventFlagDataMqNotEmpty = 0x1 << 11;
static constexpr int32_t kReopenSupportedVersion = 2;

/* JamesDSP spike implementation UUID (matches deploy xml + phase-1 spike). */
static const char* kImplUuidStr = "8e73f7a1-3c92-4f6b-9d5e-7a1b2c3d4e5f";

const Descriptor SpikeEffect::kDescriptor = {
        .common = {.id = {.type = makeUuid(Descriptor::EFFECT_TYPE_UUID_EQUALIZER),
                          .uuid = makeUuid(kImplUuidStr)},
                   .flags = {.type = ::aidl::android::hardware::audio::effect::Flags::Type::INSERT,
                             .insert =
                                     ::aidl::android::hardware::audio::effect::Flags::Insert::FIRST,
                             .volume =
                                     ::aidl::android::hardware::audio::effect::Flags::Volume::CTRL},
                   .name = "SpikeEQ Aidl",
                   .implementor = "JamesDSP Spike"},
};

namespace {

/* Peaking EQ: f0=1000 Hz, Q=1.0, gain=+12 dB (RBJ cookbook). */
constexpr double kPeakF0 = 1000.0;
constexpr double kPeakQ = 1.0;
constexpr double kPeakGainDb = 12.0;

}  // namespace

namespace aidl::android::hardware::audio::effect {

AudioUuid makeUuid(const char* str) {
    AudioUuid u{};
    uint32_t v[5] = {0};
    unsigned node[6] = {0};
    /* sscanf format: 4-2-2-2-6 hex groups */
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

const AudioUuid SpikeEffect::kImplUuid = makeUuid(kImplUuidStr);

SpikeEffect::~SpikeEffect() {
    std::lock_guard lg(mMutex);
    command(CommandId::STOP);  // best effort; ignores its own locking
    if (mThread.joinable()) {
        mExit = true;
        mStop = false;
        mCv.notify_all();
        mThread.join();
    }
    if (mEfGroup) {
        EventFlag::deleteEventFlag(&mEfGroup);
        mEfGroup = nullptr;
    }
}

int SpikeEffect::channelCount(const AudioChannelLayout& layout) {
    switch (layout.getTag()) {
        case AudioChannelLayout::indexMask: {
            uint32_t mask = static_cast<uint32_t>(layout.get<AudioChannelLayout::indexMask>());
            return __builtin_popcount(mask);
        }
        case AudioChannelLayout::layoutMask: {
            uint32_t mask = static_cast<uint32_t>(layout.get<AudioChannelLayout::layoutMask>());
            return __builtin_popcount(mask);
        }
        default:
            return 2;  // spike fallback: stereo
    }
}

void SpikeEffect::resetBiquad() {
    const double sampleRate = mCommon.input.base.sampleRate > 0
                                      ? static_cast<double>(mCommon.input.base.sampleRate)
                                      : 48000.0;
    const double A = std::pow(10.0, kPeakGainDb / 40.0);
    const double w0 = 2.0 * M_PI * kPeakF0 / sampleRate;
    const double alpha = std::sin(w0) / (2.0 * kPeakQ);

    double b0 = 1.0 + alpha * A;
    double b1 = -2.0 * std::cos(w0);
    double b2 = 1.0 - alpha * A;
    double a0 = 1.0 + alpha / A;
    double a1 = -2.0 * std::cos(w0);
    double a2 = 1.0 - alpha / A;

    mCoefB0 = b0 / a0;
    mCoefB1 = b1 / a0;
    mCoefB2 = b2 / a0;
    mCoefA0 = 1.0;
    mCoefA1 = a1 / a0;
    mCoefA2 = a2 / a0;

    for (int c = 0; c < 8; c++) {
        mX1[c] = mX2[c] = mY1[c] = mY2[c] = 0.0f;
    }
    ALOGI("SpikeEQ biquad: fs=%.0f b=[%.6f %.6f %.6f] a=[1 %.6f %.6f]", sampleRate, mCoefB0,
          mCoefB1, mCoefB2, mCoefA1, mCoefA2);
}

void SpikeEffect::biquadProcess(float* data, size_t frames, int channels) {
    if (channels > 8) channels = 8;
    for (size_t i = 0; i < frames; i++) {
        for (int c = 0; c < channels; c++) {
            float x = data[i * channels + c];
            float y = static_cast<float>(mCoefB0 * x + mCoefB1 * mX1[c] + mCoefB2 * mX2[c] -
                                         mCoefA1 * mY1[c] - mCoefA2 * mY2[c]);
            mX2[c] = mX1[c];
            mX1[c] = x;
            mY2[c] = mY1[c];
            mY1[c] = y;
            data[i * channels + c] = y;
        }
    }
}

::ndk::ScopedAStatus SpikeEffect::open(const Parameter::Common& common,
                                       const std::optional<Parameter::Specific>& specific,
                                       OpenEffectReturn* ret) {
    std::lock_guard lg(mMutex);
    if (mState != State::INIT) {
        ALOGW("open: already open, state=%d", static_cast<int>(mState));
        return ::ndk::ScopedAStatus::ok();  // per spec: no-op on opened instance
    }
    if (common.input.base.format.pcm != PcmType::FLOAT_32_BIT ||
        common.output.base.format.pcm != PcmType::FLOAT_32_BIT) {
        ALOGE("open: only float32 supported, in=%d out=%d",
              static_cast<int>(common.input.base.format.pcm),
              static_cast<int>(common.output.base.format.pcm));
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }

    mCommon = common;
    const size_t inFrames = static_cast<size_t>(
            common.input.frameCount > 0 ? common.input.frameCount : 1024);
    const size_t outFrames = static_cast<size_t>(
            common.output.frameCount > 0 ? common.output.frameCount : 1024);
    const int inCh = channelCount(common.input.base.channelMask);
    const int outCh = channelCount(common.output.base.channelMask);
    const size_t inFloats = inFrames * static_cast<size_t>(inCh);
    const size_t outFloats = outFrames * static_cast<size_t>(outCh);
    ALOGI("open: sr=%d inF=%zu(ch%d) outF=%zu(ch%d)", common.input.base.sampleRate, inFrames, inCh,
          outFrames, outCh);

    mStatusMQ = std::make_shared<StatusMQ>(1 /* statusDepth */, true /* eventFlagWord */);
    mInputMQ = std::make_shared<DataMQ>(inFloats);
    mOutputMQ = std::make_shared<DataMQ>(outFloats);
    if (!mStatusMQ->isValid() || !mInputMQ->isValid() || !mOutputMQ->isValid()) {
        ALOGE("open: invalid FMQ status=%d in=%d out=%d", mStatusMQ->isValid(),
              mInputMQ->isValid(), mOutputMQ->isValid());
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    }
    if (::android::hardware::EventFlag::createEventFlag(mStatusMQ->getEventFlagWord(),
                                                        &mEfGroup) != ::android::OK ||
        !mEfGroup) {
        ALOGE("open: EventFlag creation failed");
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    }

    mWorkBuffer.resize(std::max(inFloats, outFloats));
    resetBiquad();

    ret->statusMQ = mStatusMQ->dupeDesc();
    ret->inputDataMQ = mInputMQ->dupeDesc();
    ret->outputDataMQ = mOutputMQ->dupeDesc();

    mState = State::IDLE;

    // Start worker thread (paused until START command).
    if (mThread.joinable()) mThread.join();
    mExit = false;
    mStop = true;
    mThread = std::thread(&SpikeEffect::threadLoop, this);

    ALOGI("open: OK, effect attached");
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus SpikeEffect::close() {
    std::lock_guard lg(mMutex);
    if (mState == State::INIT) {
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    mStop = true;
    mExit = true;
    mCv.notify_all();
    if (mThread.joinable()) mThread.join();
    if (mEfGroup) {
        EventFlag::deleteEventFlag(&mEfGroup);
        mEfGroup = nullptr;
    }
    mStatusMQ.reset();
    mInputMQ.reset();
    mOutputMQ.reset();
    mState = State::INIT;
    ALOGI("close: OK");
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus SpikeEffect::getDescriptor(Descriptor* _aidl_return) {
    *_aidl_return = kDescriptor;
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus SpikeEffect::command(CommandId in_commandId) {
    std::lock_guard lg(mMutex);
    ALOGI("command: %d (state=%d)", static_cast<int>(in_commandId), static_cast<int>(mState));
    switch (in_commandId) {
        case CommandId::START:
            if (mState == State::IDLE || mState == State::DRAINING) {
                {
                    std::lock_guard tl(mThreadMutex);
                    mStop = false;
                }
                mCv.notify_all();
                mState = State::PROCESSING;
            }
            break;
        case CommandId::STOP:
            if (mState == State::PROCESSING || mState == State::DRAINING) {
                mStop = true;
                mState = State::IDLE;
            }
            break;
        case CommandId::RESET:
            if (mState != State::INIT) {
                resetBiquad();
                if (mInputMQ) mInputMQ->read(mWorkBuffer.data(), mInputMQ->availableToRead());
                if (mOutputMQ) mOutputMQ->read(mWorkBuffer.data(), mOutputMQ->availableToRead());
                if (mState == State::PROCESSING) mState = State::IDLE;
            }
            break;
        default:
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus SpikeEffect::getState(State* _aidl_return) {
    std::lock_guard lg(mMutex);
    *_aidl_return = mState;
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus SpikeEffect::setParameter(const Parameter& in_param) {
    std::lock_guard lg(mMutex);
    switch (in_param.getTag()) {
        case Parameter::common:
            mCommon = in_param.get<Parameter::common>();
            ALOGI("setParameter: common sr=%d frameCount=%lld", mCommon.input.base.sampleRate,
                  static_cast<long long>(mCommon.input.frameCount));
            break;
        case Parameter::mode:
            mAudioMode = static_cast<int32_t>(in_param.get<Parameter::mode>());
            break;
        case Parameter::source:
            mAudioSource = static_cast<int32_t>(in_param.get<Parameter::source>());
            break;
        case Parameter::volumeStereo:
            mVolumeStereo = in_param.get<Parameter::volumeStereo>();
            break;
        case Parameter::deviceDescription:
            break;  // accepted, ignored
        default:
            ALOGW("setParameter: unsupported tag %d", static_cast<int>(in_param.getTag()));
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus SpikeEffect::getParameter(const Parameter::Id& in_paramId,
                                               Parameter* _aidl_return) {
    std::lock_guard lg(mMutex);
    switch (in_paramId.getTag()) {
        case Parameter::Id::commonTag: {
            switch (in_paramId.get<Parameter::Id::commonTag>()) {
                case Parameter::common:
                    _aidl_return->set<Parameter::common>(mCommon);
                    break;
                case Parameter::mode:
                    _aidl_return->set<Parameter::mode>(
                            static_cast<::aidl::android::media::audio::common::AudioMode>(
                                    mAudioMode));
                    break;
                case Parameter::source:
                    _aidl_return->set<Parameter::source>(
                            static_cast<::aidl::android::media::audio::common::AudioSource>(
                                    mAudioSource));
                    break;
                case Parameter::volumeStereo:
                    _aidl_return->set<Parameter::volumeStereo>(mVolumeStereo);
                    break;
                default:
                    return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
            }
            break;
        }
        default:
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus SpikeEffect::reopen(OpenEffectReturn* _aidl_return) {
    std::lock_guard lg(mMutex);
    if (mState == State::INIT || !mStatusMQ || !mInputMQ || !mOutputMQ) {
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    _aidl_return->statusMQ = mStatusMQ->dupeDesc();
    _aidl_return->inputDataMQ = mInputMQ->dupeDesc();
    _aidl_return->outputDataMQ = mOutputMQ->dupeDesc();
    return ::ndk::ScopedAStatus::ok();
}

void SpikeEffect::threadLoop() {
    pthread_setname_np(pthread_self(), "SpikeEQWorker");
    while (!mExit) {
        {
            std::unique_lock l(mThreadMutex);
            mCv.wait(l, [&] { return mExit || !mStop.load(); });
        }
        if (mExit) return;
        processOnce();
    }
}

void SpikeEffect::processOnce() {
    uint32_t efState = 0;
    if (!mEfGroup || ::android::OK != mEfGroup->wait(kEventFlagDataMqNotEmpty, &efState,
                                                     0 /* no timeout */, true /* retry */) ||
        !(efState & kEventFlagDataMqNotEmpty)) {
        return;
    }

    std::lock_guard lg(mMutex);
    if (mState != State::PROCESSING && mState != State::DRAINING) return;
    if (!mInputMQ || !mOutputMQ || !mStatusMQ) return;

    const int ch = channelCount(mCommon.input.base.channelMask);
    const size_t samples = std::min(mInputMQ->availableToRead(), mOutputMQ->availableToWrite());
    if (samples == 0) return;

    const size_t n = mInputMQ->read(mWorkBuffer.data(), samples);
    if (n == 0) return;
    biquadProcess(mWorkBuffer.data(), n / static_cast<size_t>(ch ? ch : 1),
                  ch > 0 ? ch : 1);
    const size_t produced = mOutputMQ->write(mWorkBuffer.data(), n);

    IEffect::Status status{};
    status.status = 0;  // STATUS_OK (binder)
    status.fmqConsumed = static_cast<int32_t>(n);
    status.fmqProduced = static_cast<int32_t>(produced);
    mStatusMQ->writeBlocking(&status, 1);
}

}  // namespace aidl::android::hardware::audio::effect
