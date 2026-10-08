/*
 * AidlEffectBase.cpp — AIDL effect skeleton (extracted from the verified
 * spike-global-effect implementation; see docs/Spike2-AIDL效果库验证报告.md).
 */
#define LOG_TAG "JDSP_Registrar"
#include <registrar/AidlEffectBase.h>

#include <aidl/android/media/audio/common/AudioConfig.h>
#include <aidl/android/media/audio/common/PcmType.h>
#include <utils/Log.h>

#include <cstring>

/* Constants aligned with system/audio_effects/aidl_effects_utils.h */
static constexpr uint32_t kEventFlagDataMqNotEmpty = 0x1 << 11;

namespace jamesdsp::registrar {

AidlEffectBase::AidlEffectBase(const Descriptor& desc, std::shared_ptr<IAudioEngine> engine)
    : mDescriptor(desc),
      mName(desc.common.name),
      mEngine(std::move(engine)) {}

AidlEffectBase::~AidlEffectBase() {
    std::lock_guard lg(mMutex);
    if (mState != State::INIT) {
        mStop = true;
        mExit = true;
        mCv.notify_all();
        if (mThread.joinable()) mThread.join();
        if (mEfGroup) {
            EventFlag::deleteEventFlag(&mEfGroup);
            mEfGroup = nullptr;
        }
    }
}

int AidlEffectBase::channelCount(const AudioChannelLayout& layout) {
    switch (layout.getTag()) {
        case AudioChannelLayout::indexMask:
            return __builtin_popcount(
                    static_cast<uint32_t>(layout.get<AudioChannelLayout::indexMask>()));
        case AudioChannelLayout::layoutMask:
            return __builtin_popcount(
                    static_cast<uint32_t>(layout.get<AudioChannelLayout::layoutMask>()));
        default:
            return 2;
    }
}

::ndk::ScopedAStatus AidlEffectBase::open(const Parameter::Common& common,
                                          const std::optional<Parameter::Specific>& specific,
                                          OpenEffectReturn* ret) {
    std::lock_guard lg(mMutex);
    if (mState != State::INIT) {
        ALOGW("%s open: already open, state=%d", mName.c_str(), static_cast<int>(mState));
        return ::ndk::ScopedAStatus::ok();
    }
    using ::aidl::android::media::audio::common::PcmType;
    if (common.input.base.format.pcm != PcmType::FLOAT_32_BIT ||
        common.output.base.format.pcm != PcmType::FLOAT_32_BIT) {
        ALOGE("%s open: only float32 supported", mName.c_str());
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }

    mCommon = common;
    const size_t inFrames =
            static_cast<size_t>(common.input.frameCount > 0 ? common.input.frameCount : 1024);
    const size_t outFrames =
            static_cast<size_t>(common.output.frameCount > 0 ? common.output.frameCount : 1024);
    const int inCh = channelCount(common.input.base.channelMask);
    const int outCh = channelCount(common.output.base.channelMask);
    const size_t inFloats = inFrames * static_cast<size_t>(inCh);
    const size_t outFloats = outFrames * static_cast<size_t>(outCh);
    ALOGI("%s open: sr=%d inF=%zu(ch%d) outF=%zu(ch%d)", mName.c_str(),
          common.input.base.sampleRate, inFrames, inCh, outFrames, outCh);

    mStatusMQ = std::make_shared<StatusMQ>(1, true /* eventFlagWord */);
    mInputMQ = std::make_shared<DataMQ>(inFloats);
    mOutputMQ = std::make_shared<DataMQ>(outFloats);
    if (!mStatusMQ->isValid() || !mInputMQ->isValid() || !mOutputMQ->isValid()) {
        ALOGE("%s open: invalid FMQ status=%d in=%d out=%d", mName.c_str(),
              mStatusMQ->isValid(), mInputMQ->isValid(), mOutputMQ->isValid());
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    }
    if (EventFlag::createEventFlag(mStatusMQ->getEventFlagWord(), &mEfGroup) != ::android::OK ||
        !mEfGroup) {
        ALOGE("%s open: EventFlag creation failed", mName.c_str());
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    }

    mWorkBuffer.resize(std::max(inFloats, outFloats));

    if (!mEngine->open(common.input.base.sampleRate, inCh, inFrames)) {
        ALOGE("%s open: engine rejected config", mName.c_str());
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }

    if (specific.has_value()) {
        auto st = setParameterSpecific(specific.value());
        if (!st.isOk()) return st;
    }

    ret->statusMQ = mStatusMQ->dupeDesc();
    ret->inputDataMQ = mInputMQ->dupeDesc();
    ret->outputDataMQ = mOutputMQ->dupeDesc();

    mState = State::IDLE;

    if (mThread.joinable()) mThread.join();
    mExit = false;
    mStop = true;
    mThread = std::thread(&AidlEffectBase::threadLoop, this);

    ALOGI("%s open: OK, effect attached", mName.c_str());
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus AidlEffectBase::close() {
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
    mEngine->close();
    mStatusMQ.reset();
    mInputMQ.reset();
    mOutputMQ.reset();
    mState = State::INIT;
    ALOGI("%s close: OK", mName.c_str());
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus AidlEffectBase::getDescriptor(Descriptor* _aidl_return) {
    *_aidl_return = mDescriptor;
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus AidlEffectBase::command(CommandId in_commandId) {
    std::lock_guard lg(mMutex);
    ALOGI("%s command: %d (state=%d)", mName.c_str(), static_cast<int>(in_commandId),
          static_cast<int>(mState));
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
                mEngine->reset();
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

::ndk::ScopedAStatus AidlEffectBase::getState(State* _aidl_return) {
    std::lock_guard lg(mMutex);
    *_aidl_return = mState;
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus AidlEffectBase::setParameter(const Parameter& in_param) {
    std::lock_guard lg(mMutex);
    switch (in_param.getTag()) {
        case Parameter::common:
            mCommon = in_param.get<Parameter::common>();
            ALOGI("%s setParameter: common sr=%d frameCount=%lld", mName.c_str(),
                  mCommon.input.base.sampleRate,
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
            return setParameterSpecific(in_param.get<Parameter::specific>());
    }
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus AidlEffectBase::setParameterSpecific(const Parameter::Specific& specific) {
    (void)specific;
    return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

::ndk::ScopedAStatus AidlEffectBase::getParameter(const Parameter::Id& in_paramId,
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
        default: {
            Parameter::Specific specific;
            auto st = getParameterSpecific(in_paramId, &specific);
            if (!st.isOk()) return st;
            _aidl_return->set<Parameter::specific>(specific);
            break;
        }
    }
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus AidlEffectBase::getParameterSpecific(const Parameter::Id& id,
                                                          Parameter::Specific* specific) {
    (void)id;
    (void)specific;
    return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

::ndk::ScopedAStatus AidlEffectBase::reopen(OpenEffectReturn* _aidl_return) {
    std::lock_guard lg(mMutex);
    if (mState == State::INIT || !mStatusMQ || !mInputMQ || !mOutputMQ) {
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    _aidl_return->statusMQ = mStatusMQ->dupeDesc();
    _aidl_return->inputDataMQ = mInputMQ->dupeDesc();
    _aidl_return->outputDataMQ = mOutputMQ->dupeDesc();
    return ::ndk::ScopedAStatus::ok();
}

void AidlEffectBase::threadLoop() {
    pthread_setname_np(pthread_self(), "JdspEffectWorker");
    while (!mExit) {
        {
            std::unique_lock l(mThreadMutex);
            mCv.wait(l, [&] { return mExit || !mStop.load(); });
        }
        if (mExit) return;
        processOnce();
    }
}

void AidlEffectBase::processOnce() {
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
    const int safeCh = ch > 0 ? ch : 1;
    const size_t samples = std::min(mInputMQ->availableToRead(), mOutputMQ->availableToWrite());
    if (samples == 0) return;

    const size_t n = mInputMQ->read(mWorkBuffer.data(), samples);
    if (n == 0) return;
    mEngine->process(mWorkBuffer.data(), mWorkBuffer.data(), n / static_cast<size_t>(safeCh),
                     safeCh);
    const size_t produced = mOutputMQ->write(mWorkBuffer.data(), n);

    IEffect::Status status{};
    status.status = 0;  // STATUS_OK
    status.fmqConsumed = static_cast<int32_t>(n);
    status.fmqProduced = static_cast<int32_t>(produced);
    mStatusMQ->writeBlocking(&status, 1);
}

}  // namespace jamesdsp::registrar
