/*
 * Engine.h — DSP engine abstraction for the JamesDSP effect registrar.
 *
 * A concrete effect library (e.g. libjamesdsp) implements this interface;
 * the registrar core (AidlEffectBase) owns everything Android-specific:
 * state machine, FMQ data plane, worker thread, binder plumbing.
 *
 * Contract:
 *  - open() is called once per effect instance, on the binder thread,
 *    before any process() call. Return false to reject the config.
 *  - process() is called on the registrar worker thread, from IDLE/
 *    PROCESSING loop only when data is available; must be real-time safe
 *    (no allocations, no locks except engine-internal RT-safe ones).
 *  - close() is called once; after close() no process() calls occur.
 *  - reset() may be called in any state to clear internal DSP state.
 */
#pragma once

#include <cstddef>
#include <cstdint>

namespace jamesdsp::registrar {

/* Vendor parameter protocol — shared between the effect layer (which
 * translates standard AIDL effect parameters) and engine implementations.
 * Payload types are documented per id; callers pass exactly that layout. */
namespace VendorParamId {
constexpr int32_t kBassBoostEnable = 1;  /* int32: 0/1 */
constexpr int32_t kBassBoostGainDb = 2;  /* float: dB [0,15] */
constexpr int32_t kReverbPreset    = 3;  /* int32: -1 disabled, else sf_reverb_preset index */
constexpr int32_t kStereoMix       = 4;  /* float: 0..1 */
constexpr int32_t kEqEnable        = 5;  /* int32: 0/1 */
constexpr int32_t kPostGainDb      = 6;  /* float: dB [-15,15] engine output gain */
}  // namespace VendorParamId

class IAudioEngine {
public:
    virtual ~IAudioEngine() = default;

    /* Configure the engine. Returns false on unsupported config. */
    virtual bool open(int sampleRate, int channels, size_t framesPerBuffer) = 0;

    /* In-place-capable processing: 'out' may alias 'in'. */
    virtual void process(const float* in, float* out, size_t frames, int channels) = 0;

    /* Clear DSP state (coefficients history, buffers). Config kept. */
    virtual void reset() = 0;

    /* Release resources. */
    virtual void close() = 0;

    /* Engine name for logging. */
    virtual const char* name() const = 0;

    /* Optional vendor parameter plumbing (see VendorParamId). Binder-thread
     * only — engines must NOT be called from the process path. Default
     * implementation reports unsupported. */
    virtual bool setVendorParam(int32_t id, const void* data, size_t bytes) {
        (void)id; (void)data; (void)bytes;
        return false;
    }
    virtual bool getVendorParam(int32_t id, void* out, size_t bytes) const {
        (void)id; (void)out; (void)bytes;
        return false;
    }
};

}  // namespace jamesdsp::registrar
