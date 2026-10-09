/*
 * JamesDspEngine.cpp — libjamesdsp IAudioEngine implementation.
 *
 * Engine lifecycle mapping:
 *   process-global : JamesDSPGlobalMemoryAllocation()   (once, refcounted here)
 *   per instance   : JamesDSPInit(jdsp, blockSizeMax, sampleRate)
 *   per instance   : JamesDSPFree(jdsp)
 *   process-global : JamesDSPGlobalMemoryDeallocation() (not called; .so-lifetime)
 *
 * Stereo interleaved float buffers are handed straight to
 * jdsp->processFloatMultiplexd(jdsp, x, y, n); libjamesdsp reads x fully
 * into its internal scratch before writing y, so in-place (x==y) is safe.
 * For non-stereo configs we pass audio through untouched.
 */
#include "JamesDspEngine.h"

#include <android/log.h>

#include <cstring>
#include <new>

extern "C" {
#include "jdsp/jdsp_header.h"
}

#define LOG_TAG "JamesDspEngine"
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace jamesdsp::registrar {

namespace {

/* Refcount for the engine's process-global init (NSEEL JIT runtime). */
std::mutex gGlobalMutex;
int gGlobalRefCount = 0;

bool globalInit() {
    std::lock_guard<std::mutex> lk(gGlobalMutex);
    if (gGlobalRefCount == 0) {
        JamesDSPGlobalMemoryAllocation();
        ALOGI("JamesDSPGlobalMemoryAllocation done (first engine instance)");
    }
    ++gGlobalRefCount;
    return true;
}

void globalUnref() {
    std::lock_guard<std::mutex> lk(gGlobalMutex);
    if (gGlobalRefCount > 0) --gGlobalRefCount;
    /* Intentionally never call JamesDSPGlobalMemoryDeallocation():
     * NSEEL teardown at arbitrary dlcose time is riskier than leaking
     * until process exit for a HAL-spawned library. */
}

/* Apply persisted vendor params to a freshly initialized engine.
 * (implemented as private member; see header) */

}  // namespace

JamesDspEngine::~JamesDspEngine() {
    close();
}

bool JamesDspEngine::open(int sampleRate, int channels, size_t framesPerBuffer) {
    std::lock_guard<std::mutex> lk(mEngineMutex);
    if (mJdsp) return true;  // already open
    if (sampleRate < 8000 || sampleRate > 192000) {
        ALOGE("reject sampleRate=%d", sampleRate);
        return false;
    }
    /* libjamesdsp's multiplexed path is hardwired 2-channel interleaved. */
    if (channels != 2) {
        ALOGE("reject channels=%d (only stereo supported)", channels);
        return false;
    }
    if (framesPerBuffer == 0 || framesPerBuffer > 16384) {
        ALOGE("reject frames=%zu", framesPerBuffer);
        return false;
    }

    globalInit();

    mJdsp = new (std::nothrow) JamesDSPLib;
    if (!mJdsp) return false;
    JamesDSPInit(mJdsp, static_cast<int>(framesPerBuffer), static_cast<float>(sampleRate));
    mSampleRate = sampleRate;
    mChannels = channels;
    mFrames = framesPerBuffer;

    applyParamsLocked();
    ALOGI("open ok: sr=%d ch=%d frames=%zu, bass=%s(%.1fdB) reverb=%d stereo=%.2f eq=%d",
          sampleRate, channels, framesPerBuffer,
          mBassEnabled.load() ? "on" : "off", mBassGainDb.load(),
          mReverbPreset.load(), mStereoMix.load(), mEqEnabled.load());
    return true;
}

void JamesDspEngine::process(const float* in, float* out, size_t frames, int channels) {
    /* RT-safe path: no locks, no allocation for the stereo case. */
    if (mJdsp && channels == 2 && frames > 0) {
        /* Engine auto-reallocates if frames exceeds blockSizeMax
         * (see pfloat32Multiplexed), keeping steady-state allocation-free. */
        mJdsp->processFloatMultiplexd(mJdsp, const_cast<float*>(in), out, frames);
        return;
    }
    if (out != in && frames > 0) {
        memcpy(out, in, frames * static_cast<size_t>(channels) * sizeof(float));
    }
}

void JamesDspEngine::reset() {
    std::lock_guard<std::mutex> lk(mEngineMutex);
    reinitLocked();
}

bool JamesDspEngine::reinitLocked() {
    if (!mJdsp || mSampleRate == 0) return false;
    JamesDSPFree(mJdsp);
    JamesDSPInit(mJdsp, static_cast<int>(mFrames), static_cast<float>(mSampleRate));
    applyParamsLocked();
    ALOGI("engine reset (sr=%d frames=%zu)", mSampleRate, mFrames);
    return true;
}

void JamesDspEngine::applyParamsLocked() {
    if (mBassEnabled.load(std::memory_order_relaxed)) {
        BassBoostSetParam(mJdsp, mBassGainDb.load(std::memory_order_relaxed));
        BassBoostEnable(mJdsp);
    }
    const int reverb = mReverbPreset.load(std::memory_order_relaxed);
    if (reverb >= 0) {
        Reverb_SetParam(mJdsp, reverb);
        ReverbEnable(mJdsp);
    }
    if (mStereoMix.load(std::memory_order_relaxed) > 0.0f) {
        StereoEnhancementSetParam(mJdsp, mStereoMix.load(std::memory_order_relaxed));
        StereoEnhancementEnable(mJdsp);
    }
    if (mEqEnabled.load(std::memory_order_relaxed)) {
        MultimodalEqualizerEnable(mJdsp, 1);
    }
    JamesDSPSetPostGain(mJdsp, mPostGainDb.load(std::memory_order_relaxed));
}

void JamesDspEngine::close() {
    std::lock_guard<std::mutex> lk(mEngineMutex);
    if (!mJdsp) return;
    JamesDSPFree(mJdsp);
    delete mJdsp;
    mJdsp = nullptr;
    globalUnref();
    ALOGI("closed");
}

bool JamesDspEngine::setVendorParam(int32_t id, const void* data, size_t bytes) {
    std::lock_guard<std::mutex> lk(mEngineMutex);
    switch (id) {
        case VendorParamId::kBassBoostEnable:
            if (bytes < sizeof(int32_t)) return false;
            mBassEnabled.store(*static_cast<const int32_t*>(data) != 0);
            if (mJdsp) {
                if (mBassEnabled.load()) {
                    BassBoostSetParam(mJdsp, mBassGainDb.load());
                    BassBoostEnable(mJdsp);
                } else {
                    BassBoostDisable(mJdsp);
                }
            }
            ALOGI("bass boost -> %s", mBassEnabled.load() ? "on" : "off");
            return true;
        case VendorParamId::kBassBoostGainDb: {
            if (bytes < sizeof(float)) return false;
            float db = *static_cast<const float*>(data);
            if (db < 0.0f) db = 0.0f;
            if (db > 15.0f) db = 15.0f;
            mBassGainDb.store(db);
            if (mJdsp && mBassEnabled.load()) BassBoostSetParam(mJdsp, mBassGainDb.load());
            ALOGI("bass boost gain -> %.1f dB", db);
            return true;
        }
        case VendorParamId::kReverbPreset:
            if (bytes < sizeof(int32_t)) return false;
            mReverbPreset.store(*static_cast<const int32_t*>(data));
            if (mJdsp) {
                ReverbDisable(mJdsp);
                if (mReverbPreset.load() >= 0) {
                    Reverb_SetParam(mJdsp, mReverbPreset.load());
                    ReverbEnable(mJdsp);
                }
            }
            ALOGI("reverb preset -> %d", mReverbPreset.load());
            return true;
        case VendorParamId::kStereoMix:
            if (bytes < sizeof(float)) return false;
            mStereoMix.store(*static_cast<const float*>(data));
            if (mJdsp) {
                StereoEnhancementDisable(mJdsp);
                if (mStereoMix.load() > 0.0f) {
                    StereoEnhancementSetParam(mJdsp, mStereoMix.load());
                    StereoEnhancementEnable(mJdsp);
                }
            }
            return true;
        case VendorParamId::kEqEnable:
            if (bytes < sizeof(int32_t)) return false;
            mEqEnabled.store(*static_cast<const int32_t*>(data) != 0);
            if (mJdsp) MultimodalEqualizerEnable(mJdsp, mEqEnabled.load() ? 1 : 0);
            return true;
        case VendorParamId::kPostGainDb: {
            if (bytes < sizeof(float)) return false;
            float db = *static_cast<const float*>(data);
            if (db < -15.0f) db = -15.0f;
            if (db > 15.0f) db = 15.0f;
            mPostGainDb.store(db);
            if (mJdsp) JamesDSPSetPostGain(mJdsp, mPostGainDb.load());
            ALOGI("post gain -> %.1f dB", db);
            return true;
        }
    }
    ALOGW("unknown vendor param id=%d", id);
    return false;
}

bool JamesDspEngine::getVendorParam(int32_t id, void* out, size_t bytes) const {
    std::lock_guard<std::mutex> lk(mEngineMutex);
    switch (id) {
        case VendorParamId::kBassBoostEnable:
            if (bytes < sizeof(int32_t)) return false;
            *static_cast<int32_t*>(out) = mBassEnabled.load() ? 1 : 0;
            return true;
        case VendorParamId::kBassBoostGainDb:
            if (bytes < sizeof(float)) return false;
            *static_cast<float*>(out) = mBassGainDb.load();
            return true;
        case VendorParamId::kReverbPreset:
            if (bytes < sizeof(int32_t)) return false;
            *static_cast<int32_t*>(out) = mReverbPreset.load();
            return true;
        case VendorParamId::kStereoMix:
            if (bytes < sizeof(float)) return false;
            *static_cast<float*>(out) = mStereoMix.load();
            return true;
        case VendorParamId::kEqEnable:
            if (bytes < sizeof(int32_t)) return false;
            *static_cast<int32_t*>(out) = mEqEnabled.load();
            return true;
        case VendorParamId::kPostGainDb:
            if (bytes < sizeof(float)) return false;
            *static_cast<float*>(out) = mPostGainDb.load();
            return true;
    }
    return false;
}

}  // namespace jamesdsp::registrar
