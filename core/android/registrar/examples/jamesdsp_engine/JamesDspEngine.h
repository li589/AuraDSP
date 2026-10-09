/*
 * JamesDspEngine.h — libjamesdsp (vendor-src) wrapped as IAudioEngine.
 *
 * Wraps the JamesDSP C engine (JamesDSPLib) behind the registrar's
 * engine abstraction. Stereo interleaved float in/out maps 1:1 onto
 * the engine's processFloatMultiplexd entry point.
 *
 * Thread contract (from Engine.h): process() is RT-safe. libjamesdsp's
 * own processing is allocation-free in steady state (buffers sized at
 * open / JamesDSPReallocateBlock on block-size change); we hold no
 * additional locks on the process path.
 *
 * Engine defaults (validation build):
 *   - Bass boost enabled at +15.0 dB (API ceiling) on open(). +6 dB was
 *     inaudible on the phone speaker (physically rolls off below ~300 Hz);
 *     15 dB makes the processing chain unambiguously audible for A/B tests.
 *   - Reverb enabled with SF_REVERB_PRESET_LARGEHALL1 for the same reason.
 *   - All other effects disabled.
 * Tunables via setVendorParam() (see ParamId).
 */
#pragma once

#include <registrar/Engine.h>

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>

/* Pure-C engine (no __cplusplus guards upstream) — wrap for C++ TU. */
extern "C" {
#include "jdsp/jdsp_header.h"
}

namespace jamesdsp::registrar {

class JamesDspEngine final : public IAudioEngine {
public:
    /* Vendor param ids come from registrar/Engine.h VendorParamId:
     *   kBassBoostEnable(1) int32 0/1     kBassBoostGainDb(2) float dB[0,15]
     *   kReverbPreset(3)    int32 -1/idx  kStereoMix(4)       float 0..1
     *   kEqEnable(5)        int32 0/1     kPostGainDb(6)      float dB[-15,15] */

    JamesDspEngine() = default;
    ~JamesDspEngine() override;

    /* IAudioEngine */
    bool open(int sampleRate, int channels, size_t framesPerBuffer) override;
    void process(const float* in, float* out, size_t frames, int channels) override;
    void reset() override;
    void close() override;
    const char* name() const override { return "JamesDSP"; }

    /* Vendor parameter plumbing (see VendorParamId in Engine.h). */
    bool setVendorParam(int32_t id, const void* data, size_t bytes) override;
    bool getVendorParam(int32_t id, void* out, size_t bytes) const override;

private:
    bool reinitLocked();     /* caller holds mEngineMutex */
    void applyParamsLocked(); /* caller holds mEngineMutex */

    JamesDSPLib* mJdsp = nullptr;
    int mSampleRate = 0;
    int mChannels = 0;
    size_t mFrames = 0;

    /* Persisted vendor params (re-applied on reset/open). */
    std::atomic<bool> mBassEnabled{true};
    std::atomic<float> mBassGainDb{15.0f};    /* dB [0-15], API ceiling for A/B audibility */
    std::atomic<int32_t> mReverbPreset{5};    /* SF_REVERB_PRESET_LARGEHALL1 (audible test default) */
    std::atomic<float> mStereoMix{0.0f};
    std::atomic<int32_t> mEqEnabled{0};
    std::atomic<float> mPostGainDb{0.0f};     /* 0 dB = unity */

    /* Guards init/teardown/param application. Not taken by process(). */
    mutable std::mutex mEngineMutex;
};

}  // namespace jamesdsp::registrar
