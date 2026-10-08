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
 *   - Bass boost enabled at +6.0 dB on open(), so an on-device run
 *     produces an audible pass/fail signal without any parameter call.
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
    /* Vendor parameter ids for setVendorParam/getVendorParam. */
    enum class ParamId : int32_t {
        kBassBoostEnable = 1,   /* payload int32: 0/1 */
        kBassBoostGainDb = 2,   /* payload float: dB (max gain) */
        kReverbPreset    = 3,   /* payload int32: preset index (Reverb_SetParam) */
        kStereoMix       = 4,   /* payload float: 0..1 mix amount */
        kEqEnable        = 5,   /* payload int32: 0/1 (flat EQ until configured) */
    };

    JamesDspEngine() = default;
    ~JamesDspEngine() override;

    /* IAudioEngine */
    bool open(int sampleRate, int channels, size_t framesPerBuffer) override;
    void process(const float* in, float* out, size_t frames, int channels) override;
    void reset() override;
    void close() override;
    const char* name() const override { return "JamesDSP"; }

    /* Vendor parameter plumbing (called from effect subclass hook on
     * binder thread; internally takes engine mutex — NOT on process path). */
    bool setVendorParam(int32_t id, const void* data, size_t bytes);
    bool getVendorParam(int32_t id, void* out, size_t bytes) const;

private:
    bool reinitLocked();     /* caller holds mEngineMutex */
    void applyParamsLocked(); /* caller holds mEngineMutex */

    JamesDSPLib* mJdsp = nullptr;
    int mSampleRate = 0;
    int mChannels = 0;
    size_t mFrames = 0;

    /* Persisted vendor params (re-applied on reset/open). */
    std::atomic<bool> mBassEnabled{true};
    std::atomic<float> mBassGainDb{6.0f};
    std::atomic<int32_t> mReverbPreset{-1};   /* -1 = disabled */
    std::atomic<float> mStereoMix{0.0f};
    std::atomic<int32_t> mEqEnabled{0};

    /* Guards init/teardown/param application. Not taken by process(). */
    mutable std::mutex mEngineMutex;
};

}  // namespace jamesdsp::registrar
