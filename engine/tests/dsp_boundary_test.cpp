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

            const char* envCode =
                "@init\nspl0=spl0;\n@sample\n"
                "spl0=slider1; spl1=srate/48000;\n";
            const int envLoaded = mc_liveprog_load(host, envCode);
            Check(envLoaded == 1, "compile MC liveprog environment fixture");
            if (envLoaded == 1) {
                mc_liveprog_set_slider(host, 1, 0.75f);
                mc_liveprog_set_sample_rate(host, 44100.0f);
                mc_liveprog_set_channels(host, 2);
                float envBuffer[2] = {};
                mc_liveprog_process(host, envBuffer, 1, 2);
                Check(envBuffer[0] == 0.75f, "RT must consume shadow slider value");
                Check(std::fabs(envBuffer[1] - 44100.0f / 48000.0f) < 1e-6f,
                      "RT must consume shadow sample-rate value");
            }

            McLiveProgHost* initHost = mc_liveprog_create(48000.0f, 2);
            Check(initHost != nullptr, "create second MC liveprog host for @init slider test");
            if (initHost) {
                const char* initSliderCode =
                    "@init\nslider12 = 10.0;\n@slider\ns = 1.0 / slider12;\n@sample\nspl0 = s;\n";
                Check(mc_liveprog_load(initHost, initSliderCode) == 1,
                      "compile @init slider default fixture");
                mc_liveprog_set_enabled(initHost, 1);
                float initBuf[2] = {1.0f, 1.0f};
                for (int b = 0; b < 3; ++b) {
                    mc_liveprog_process(initHost, initBuf, 1, 2);
                    Check(std::fabs(initBuf[0] - 0.1f) < 1e-6f,
                          "RT must preserve @init slider defaults when untouched by host");
                }
                mc_liveprog_set_slider(initHost, 12, 4.0f);
                mc_liveprog_process(initHost, initBuf, 1, 2);
                Check(std::fabs(initBuf[0] - 0.25f) < 1e-6f,
                      "explicit host slider update must override @init default");
                mc_liveprog_destroy(initHost);
            }
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
