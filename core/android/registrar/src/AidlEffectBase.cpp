/*
 * AidlEffectBase.cpp — AIDL effect skeleton (extracted from the verified
 * spike-global-effect implementation; see docs/Spike2-AIDL效果库验证报告.md).
 */
#define LOG_TAG "JDSP_Registrar"
#include <registrar/AidlEffectBase.h>

#include <aidl/android/media/audio/common/AudioConfig.h>
#include <aidl/android/media/audio/common/PcmType.h>
#include <utils/Log.h>

#include <cmath>
#include <cstring>

/* Constants aligned with system/audio_effects/aidl_effects_utils.h */
static constexpr uint32_t kEventFlagDataMqNotEmpty = 0x1 << 11;
/* Worker EventFlag wait timeout: bounds how long a worker can stay stuck in
 * wait() after mExit is set. AOSP relies on wake() alone; we add a timeout
 * as belt-and-braces (crash postmortem 2026-10-08: close() joined a worker
 * blocked in no-timeout wait -> audioserver TimeCheck timeout -> reboot). */
static constexpr int64_t kEfWaitTimeoutNs = 100'000'000;   // 100ms
/* Status MQ depth is 1; if the framework stops consuming status while audio
 * still flows, an unbounded writeBlocking would hold mMutex forever and
 * deadlock close(). Bound it and treat failure as best-effort. */
static constexpr int64_t kStatusWriteTimeoutNs = 50'000'000;  // 50ms

namespace jamesdsp::registrar {

using ::aidl::android::hardware::audio::effect::BassBoost;
using ::aidl::android::hardware::audio::effect::Equalizer;
using ::aidl::android::hardware::audio::effect::PresetReverb;

AidlEffectBase::AidlEffectBase(const Descriptor& desc, std::shared_ptr<IAudioEngine> engine)
    : mDescriptor(desc),
      mName(desc.common.name),
      mEngine(std::move(engine)) {}

AidlEffectBase::~AidlEffectBase() {
    /* Same ordering as close(): wake flags/worker first, join without
     * holding mMutex, then clean up. */
    {
        std::lock_guard tl(mThreadMutex);
        mStop = true;
        mExit = true;
    }
    mCv.notify_all();
    if (mEfGroup) mEfGroup->wake(kEventFlagDataMqNotEmpty);
    if (mThread.joinable()) mThread.join();
    std::lock_guard lg(mMutex);
    if (mEfGroup) {
        EventFlag::deleteEventFlag(&mEfGroup);
        mEfGroup = nullptr;
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

    /* 2x slack on both data MQs: room for a full buffer even when one cycle
     * is missed, so a transient stall self-heals on the next wake instead of
     * wedging (real root cause of the 2026-10-09 stall was the libfmq
     * bool-read conversion bug — see processOnce — slack is cheap insurance). */
    mStatusMQ = std::make_shared<StatusMQ>(1, true /* eventFlagWord */);
    mInputMQ = std::make_shared<DataMQ>(inFloats * 2);
    mOutputMQ = std::make_shared<DataMQ>(outFloats * 2);
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
    /* AOSP EffectImpl::close pattern (audio/aidl/default/EffectImpl.cpp):
     * 1. take mutex ONLY to flip state -> worker stops entering process;
     * 2. wake the EventFlag so a worker blocked in wait() can observe exit;
     * 3. set stop/exit + join WITHOUT holding mMutex (the worker takes
     *    mMutex inside processOnce — holding it here deadlocks, which is
     *    exactly the audioserver TimeCheck-reboot crash of 2026-10-08);
     * 4. retake mutex to release resources. */
    {
        std::lock_guard lg(mMutex);
        if (mState == State::INIT) {
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        }
        mState = State::INIT;
    }
    if (mEfGroup) mEfGroup->wake(kEventFlagDataMqNotEmpty);
    {
        std::lock_guard tl(mThreadMutex);
        mStop = true;
        mExit = true;
    }
    mCv.notify_all();
    if (mThread.joinable()) mThread.join();
    std::lock_guard lg(mMutex);
    if (mEfGroup) {
        EventFlag::deleteEventFlag(&mEfGroup);
        mEfGroup = nullptr;
    }
    mEngine->close();
    mStatusMQ.reset();
    mInputMQ.reset();
    mOutputMQ.reset();
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
                if (mEfGroup) mEfGroup->wake(kEventFlagDataMqNotEmpty);  // AOSP: notifyEventFlag
                mState = State::PROCESSING;
            }
            break;
        case CommandId::STOP:
            if (mState == State::PROCESSING || mState == State::DRAINING) {
                mStop = true;
                mState = State::IDLE;
                if (mEfGroup) mEfGroup->wake(kEventFlagDataMqNotEmpty);  // unstick wait()
            }
            break;
        case CommandId::RESET:
            if (mState != State::INIT) {
                mEngine->reset();
                if (mInputMQ) mInputMQ->read(mWorkBuffer.data(), mInputMQ->availableToRead());
                if (mOutputMQ) mOutputMQ->read(mWorkBuffer.data(), mOutputMQ->availableToRead());
                if (mState == State::PROCESSING) mState = State::IDLE;
                if (mEfGroup) mEfGroup->wake(kEventFlagDataMqNotEmpty);
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
        case Parameter::volumeStereo: {
            mVolumeStereo = in_param.get<Parameter::volumeStereo>();
            ALOGI("%s setParameter: volumeStereo L=%.3f R=%.3f (accepted, not routed)",
                  mName.c_str(), mVolumeStereo.left, mVolumeStereo.right);
            break;
        }
        case Parameter::deviceDescription:
            break;  // accepted, ignored
        default:
            return setParameterSpecific(in_param.get<Parameter::specific>());
    }
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus AidlEffectBase::setParameterSpecific(const Parameter::Specific& specific) {
    /* Translate standard AIDL effect parameters onto the engine's vendor
     * param protocol (VendorParamId in Engine.h). Our declared type UUID is
     * the standard equalizer type, so APPs may address us through the
     * stock android.media.audiofx.Equalizer/BassBoost/PresetReverb APIs. */
    using Tag = Parameter::Specific::Tag;
    switch (specific.getTag()) {
        case Tag::bassBoost: {
            const auto& bb = specific.get<Tag::bassBoost>();
            if (bb.getTag() != BassBoost::strengthPm) {
                return ::ndk::ScopedAStatus::ok();  /* vendor-only query, nothing to apply */
            }
            /* AIDL strength 0..1000 per-mille -> our 0..15 dB range. */
            const float db =
                    static_cast<float>(bb.get<BassBoost::strengthPm>()) / 1000.0f * 15.0f;
            const int32_t on = 1;
            mEngine->setVendorParam(VendorParamId::kBassBoostEnable, &on, sizeof(on));
            mEngine->setVendorParam(VendorParamId::kBassBoostGainDb, &db, sizeof(db));
            ALOGI("%s setParameter: bassBoost strengthPm=%d -> %.1f dB", mName.c_str(),
                  bb.get<BassBoost::strengthPm>(), db);
            return ::ndk::ScopedAStatus::ok();
        }
        case Tag::presetReverb: {
            const auto& pr = specific.get<Tag::presetReverb>();
            if (pr.getTag() != PresetReverb::preset) {
                return ::ndk::ScopedAStatus::ok();
            }
            int32_t jidx = -1;
            switch (pr.get<PresetReverb::preset>()) {
                using P = PresetReverb::Presets;
                case P::NONE:       jidx = -1; break;  /* disabled */
                case P::SMALLROOM:  jidx = 7;  break;  /* SF_REVERB_PRESET_SMALLROOM1 */
                case P::MEDIUMROOM: jidx = 9;  break;  /* SF_REVERB_PRESET_MEDIUMROOM1 */
                case P::LARGEROOM:  jidx = 11; break;  /* SF_REVERB_PRESET_LARGEROOM1 */
                case P::MEDIUMHALL: jidx = 3;  break;  /* SF_REVERB_PRESET_MEDIUMHALL1 */
                case P::LARGEHALL:  jidx = 5;  break;  /* SF_REVERB_PRESET_LARGEHALL1 */
                case P::PLATE:      jidx = 15; break;  /* SF_REVERB_PRESET_PLATEHIGH */
            }
            mEngine->setVendorParam(VendorParamId::kReverbPreset, &jidx, sizeof(jidx));
            ALOGI("%s setParameter: presetReverb=%d -> jdsp preset %d", mName.c_str(),
                  static_cast<int>(pr.get<PresetReverb::preset>()), jidx);
            return ::ndk::ScopedAStatus::ok();
        }
        case Tag::equalizer: {
            const auto& eq = specific.get<Tag::equalizer>();
            if (eq.getTag() == Equalizer::bandLevels) {
                /* First-cut mapping: lowest band (0) drives bass boost; the
                 * remaining bands are accepted but unmapped until the full
                 * MultimodalEqualizer axis table is wired (AxisInterpolation). */
                for (const auto& bl : eq.get<Equalizer::bandLevels>()) {
                    const float db = static_cast<float>(bl.levelMb) / 100.0f; /* mB -> dB */
                    if (bl.index == 0) {
                        const int32_t on = 1;
                        mEngine->setVendorParam(VendorParamId::kBassBoostEnable, &on, sizeof(on));
                        mEngine->setVendorParam(VendorParamId::kBassBoostGainDb, &db, sizeof(db));
                    }
                    ALOGI("%s setParameter: EQ band %d levelMb=%d (%.1f dB)%s", mName.c_str(),
                          bl.index, bl.levelMb, db,
                          bl.index == 0 ? " -> bass boost" : " (unmapped, accepted)");
                }
            } else if (eq.getTag() == Equalizer::preset) {
                ALOGI("%s setParameter: EQ preset=%d (accepted, unmapped)", mName.c_str(),
                      eq.get<Equalizer::preset>());
            } else {
                ALOGI("%s setParameter: EQ tag=%d (accepted, unmapped)", mName.c_str(),
                      static_cast<int>(eq.getTag()));
            }
            return ::ndk::ScopedAStatus::ok();
        }
        default:
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
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
    using IdTag = Parameter::Id::Tag;
    switch (id.getTag()) {
        case IdTag::bassBoostTag: {
            float db = 0.0f;
            mEngine->getVendorParam(VendorParamId::kBassBoostGainDb, &db, sizeof(db));
            BassBoost bb;
            bb.set<BassBoost::strengthPm>(
                    static_cast<int32_t>(std::lround(db / 15.0f * 1000.0f)));
            specific->set<Parameter::Specific::bassBoost>(bb);
            return ::ndk::ScopedAStatus::ok();
        }
        case IdTag::presetReverbTag: {
            int32_t jidx = -1;
            mEngine->getVendorParam(VendorParamId::kReverbPreset, &jidx, sizeof(jidx));
            PresetReverb::Presets p = PresetReverb::Presets::NONE;
            switch (jidx) {  /* inverse of setParameterSpecific's mapping */
                case 7:  p = PresetReverb::Presets::SMALLROOM;  break;
                case 9:  p = PresetReverb::Presets::MEDIUMROOM; break;
                case 11: p = PresetReverb::Presets::LARGEROOM;  break;
                case 3:  p = PresetReverb::Presets::MEDIUMHALL; break;
                case 5:  p = PresetReverb::Presets::LARGEHALL;  break;
                case 15: p = PresetReverb::Presets::PLATE;      break;
                default: p = PresetReverb::Presets::NONE;       break;
            }
            PresetReverb pr;
            pr.set<PresetReverb::preset>(p);
            specific->set<Parameter::Specific::presetReverb>(pr);
            return ::ndk::ScopedAStatus::ok();
        }
        default:
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
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
    /* Bounded wait (AOSP uses no-timeout + explicit wake; we add a timeout so
     * mExit is always observed within one cycle regardless of wake ordering). */
    if (!mEfGroup || ::android::OK != mEfGroup->wait(kEventFlagDataMqNotEmpty, &efState,
                                                     kEfWaitTimeoutNs, true /* retry */) ||
        !(efState & kEventFlagDataMqNotEmpty)) {
        static std::atomic<int> waitMiss{0};
        if (mState == State::PROCESSING && ++waitMiss % 100 == 1) {
            ALOGW("%s dataPlane: wait miss (flag not set) state=%d", mName.c_str(),
                  static_cast<int>(mState));
        }
        return;
    }
    if (mExit) return;

    std::lock_guard lg(mMutex);
    if (mState != State::PROCESSING && mState != State::DRAINING) return;
    if (!mInputMQ || !mOutputMQ || !mStatusMQ) return;

    const int ch = channelCount(mCommon.input.base.channelMask);
    const int safeCh = ch > 0 ? ch : 1;
    static std::atomic<int> dbgCount{0};
    const bool dbg = (dbgCount++ % 100 == 0);  // periodic data-plane trace
    if (dbg) {
        ALOGW("%s dataPlane: in=%zu outW=%zu", mName.c_str(),
              mInputMQ->availableToRead(), mOutputMQ->availableToWrite());
    }

    /* Drain loop: consume everything currently queued in the input MQ so the
     * framework's next write always finds full room. Steady state is one
     * write per wake, so consumed_total == floatsToWrite exactly (what the
     * framework validates). Partial leftover only in recovery, and with the
     * 2x MQ slack it re-syncs within a cycle.
     *
     * POSTMORTEM 2026-10-09: libfmq's read(T*, size_t)/write(const T*, size_t)
     * return BOOL, not element counts. The old code assigned them to size_t,
     * so every successful full-buffer read/write became "1 element" — engine
     * processed n/ch == 0 frames and Status reported fmqConsumed=1 forever,
     * wedging the framework ("FMQ consumed 1 (of 3840)" storm). The earlier
     * "output MQ exactly one buffer" theory was wrong; capacity was innocent. */
    size_t consumedTotal = 0;
    size_t producedTotal = 0;
    double inSq = 0.0, outSq = 0.0;  /* RMS diagnostic on dbg cycles */
    while (mState == State::PROCESSING || mState == State::DRAINING) {
        const size_t inAvailNow = mInputMQ->availableToRead();
        if (inAvailNow == 0) break;
        const size_t outRoomNow = mOutputMQ->availableToWrite();
        if (outRoomNow == 0) break;
        size_t chunk = std::min(inAvailNow, outRoomNow);
        /* whole frames only: engine processes chunk/ch frames in place */
        chunk -= chunk % static_cast<size_t>(safeCh);
        if (chunk == 0) break;
        if (!mInputMQ->read(mWorkBuffer.data(), chunk)) break;
        if (dbg)
            for (size_t i = 0; i < chunk; i++) {
                const float v = mWorkBuffer.data()[i];
                inSq += static_cast<double>(v) * v;
            }
        mEngine->process(mWorkBuffer.data(), mWorkBuffer.data(),
                         chunk / static_cast<size_t>(safeCh), safeCh);
        if (dbg)
            for (size_t i = 0; i < chunk; i++) {
                const float v = mWorkBuffer.data()[i];
                outSq += static_cast<double>(v) * v;
            }
        if (!mOutputMQ->write(mWorkBuffer.data(), chunk)) break;
        consumedTotal += chunk;
        producedTotal += chunk;
    }
    if (consumedTotal == 0) return;

    IEffect::Status status{};
    status.status = 0;  // STATUS_OK
    status.fmqConsumed = static_cast<int32_t>(consumedTotal);
    status.fmqProduced = static_cast<int32_t>(producedTotal);
    /* Bounded: a full status MQ (framework stopped consuming) must never hold
     * mMutex forever — that was the close()-deadlock that rebooted the phone. */
    if (!mStatusMQ->writeBlocking(&status, 1, kStatusWriteTimeoutNs)) {
        static std::atomic<int> stDrop{0};
        if (++stDrop % 20 == 1)
            ALOGW("%s dataPlane: status write TIMEOUT (framework not consuming)",
                  mName.c_str());
    } else if (dbg) {
        ALOGW("%s dataPlane: wrote status consumed=%zu produced=%zu", mName.c_str(),
              static_cast<size_t>(status.fmqConsumed), static_cast<size_t>(status.fmqProduced));
    }
    if (dbg && inSq > 0.0) {
        /* Engine-side A/B evidence: >0 dB means the DSP is actually altering
         * the stream; ~0 dB over many cycles means pass-through. */
        ALOGW("%s dataPlane: engine rmsDiff=%+.2f dB", mName.c_str(),
              10.0 * log10(outSq / inSq));
    }
}

}  // namespace jamesdsp::registrar
