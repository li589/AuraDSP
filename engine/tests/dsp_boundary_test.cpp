#include "engine_internal.h"
#include "dsp/dsp_mc_liveprog.h"
#include "legacy/jdsp/jdsp_header.h"

#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>

namespace {
int failures = 0;

void Check(bool condition, const char* message) {
    if (!condition) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

int RunLiveProgBoundary() {
    JamesDSPGlobalMemoryAllocation();
    McLiveProgHost* host = mc_liveprog_create(48000.0f, 2);
    Check(host != nullptr, "create MC liveprog host");
    if (host) {
        const char* code = "@init\nspl0=spl0;\n@sample\nspl0=spl0*2.0;\n";
        const int loaded = mc_liveprog_load(host, code);
        Check(loaded == 1, "compile MC liveprog fixture");
        if (loaded == 1) {
            mc_liveprog_set_enabled(host, 1);
            float zeroChannels = 0.25f;
            float negativeChannels = 0.25f;
            mc_liveprog_process(host, &zeroChannels, 1, 0);
            mc_liveprog_process(host, &negativeChannels, 1, -1);
            Check(zeroChannels == 0.25f, "zero channels must not execute or stride VM");
            Check(negativeChannels == 0.25f, "negative channels must not execute or stride VM");
        }
        mc_liveprog_destroy(host);
    }
    JamesDSPGlobalMemoryDeallocation();
    return failures;
}

int RunReverbBoundary() {
    auto handle = std::make_unique<auradsp_handle_s>();
    handle->sample_rate = 48000.0f;
    handle->p.reverb_preset.store(19, std::memory_order_relaxed);
    float reverbOutput = 0.25f;
    mc_reverb_process_mc(handle.get(), &reverbOutput, 1, 2);
    Check(reverbOutput == 0.25f, "invalid MC reverb preset must bypass safely");
    handle->p.reverb_preset.store(INT_MAX, std::memory_order_relaxed);
    mc_reverb_process_mc(handle.get(), &reverbOutput, 1, 2);
    Check(reverbOutput == 0.25f, "extreme MC reverb preset must bypass safely");
    return failures;
}

int RunMultimodalEqBoundary() {
    auto jdsp = std::make_unique<JamesDSPLib>();
    std::memset(jdsp.get(), 0, sizeof(JamesDSPLib));
    jdsp->fs = 48000.0;
    double freq[NUMPTS] = {};
    double gain[NUMPTS] = {};
    for (int i = 0; i < NUMPTS; ++i) {
        freq[i] = 20.0 * std::pow(1000.0, (double)i / (NUMPTS - 1));
        gain[i] = (i == 0) ? -100.0 : ((i == NUMPTS - 1) ? 100.0 : 0.0);
    }
    MultimodalEqualizerAxisInterpolation(jdsp.get(), 0, 1, freq, gain);
    Check(jdsp->mEQ.gain[1] == -64.0, "first multimodal EQ gain must clamp to -64 dB");
    Check(jdsp->mEQ.gain[NUMPTS] == 64.0, "last multimodal EQ gain must clamp to +64 dB");
    Check(jdsp->mEQ.gain[NUMPTS + 1] == 64.0, "Nyquist endpoint must inherit clamped gain");
    return failures;
}
}

int main(int argc, char** argv) {
    const char* mode = (argc > 1) ? argv[1] : "liveprog";
    if (std::strcmp(mode, "reverb") == 0) failures += RunReverbBoundary();
    else if (std::strcmp(mode, "multimodal_eq") == 0) failures += RunMultimodalEqBoundary();
    else failures += RunLiveProgBoundary();
    if (failures != 0) return 1;
    std::puts("dsp boundary safety: all checks passed");
    return 0;
}
