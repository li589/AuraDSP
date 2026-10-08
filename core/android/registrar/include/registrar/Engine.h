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

namespace jamesdsp::registrar {

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
};

}  // namespace jamesdsp::registrar
