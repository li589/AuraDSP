/*
 * SpikeEqEngine.cpp — RBJ cookbook peaking EQ (f0=1kHz, Q=1.0, +12dB).
 */
#define LOG_TAG "JDSP_SpikeEQ"
#include "SpikeEqEngine.h"

#include <utils/Log.h>

#include <cmath>

namespace jamesdsp::examples {

using jamesdsp::registrar::IAudioEngine;

bool SpikeEqEngine::open(int sampleRate, int channels, size_t framesPerBuffer) {
    if (sampleRate <= 0 || channels <= 0 || channels > 8) return false;
    mSampleRate = sampleRate;
    mChannels = channels;
    designCoefficients();
    ALOGI("SpikeEQ engine open: sr=%d ch=%d frames=%zu", sampleRate, channels, framesPerBuffer);
    return true;
}

void SpikeEqEngine::designCoefficients() {
    const double f0 = 1000.0, Q = 1.0, gainDb = 12.0;
    const double A = std::pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * M_PI * f0 / static_cast<double>(mSampleRate);
    const double alpha = std::sin(w0) / (2.0 * Q);

    const double b0 = 1.0 + alpha * A, b1 = -2.0 * std::cos(w0), b2 = 1.0 - alpha * A;
    const double a0 = 1.0 + alpha / A, a1 = -2.0 * std::cos(w0), a2 = 1.0 - alpha / A;

    mB0 = b0 / a0; mB1 = b1 / a0; mB2 = b2 / a0;
    mA0 = 1.0;     mA1 = a1 / a0; mA2 = a2 / a0;
    reset();
    ALOGI("SpikeEQ biquad: fs=%d b=[%.6f %.6f %.6f] a=[1 %.6f %.6f]", mSampleRate, mB0, mB1, mB2,
          mA1, mA2);
}

void SpikeEqEngine::process(const float* in, float* out, size_t frames, int channels) {
    if (channels > 8) channels = 8;
    for (size_t i = 0; i < frames; i++) {
        for (int c = 0; c < channels; c++) {
            const float x = in[i * channels + c];
            const float y = static_cast<float>(mB0 * x + mB1 * mX1[c] + mB2 * mX2[c] -
                                               mA1 * mY1[c] - mA2 * mY2[c]);
            mX2[c] = mX1[c]; mX1[c] = x;
            mY2[c] = mY1[c]; mY1[c] = y;
            out[i * channels + c] = y;
        }
    }
}

void SpikeEqEngine::reset() {
    for (int c = 0; c < 8; c++) mX1[c] = mX2[c] = mY1[c] = mY2[c] = 0.0f;
}

void SpikeEqEngine::close() {
    ALOGI("SpikeEQ engine closed");
}

}  // namespace jamesdsp::examples
