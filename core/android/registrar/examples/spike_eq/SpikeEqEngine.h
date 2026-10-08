/*
 * SpikeEqEngine.h — example IAudioEngine: peaking biquad EQ (1 kHz +12 dB).
 * Stand-in for the future libjamesdsp engine integration.
 */
#pragma once

#include <registrar/Engine.h>

namespace jamesdsp::examples {

class SpikeEqEngine : public jamesdsp::registrar::IAudioEngine {
public:
    bool open(int sampleRate, int channels, size_t framesPerBuffer) override;
    void process(const float* in, float* out, size_t frames, int channels) override;
    void reset() override;
    void close() override;
    const char* name() const override { return "SpikeEQ Core"; }

private:
    void designCoefficients();

    int mSampleRate = 48000;
    int mChannels = 2;
    double mB0 = 1.0, mB1 = 0.0, mB2 = 0.0, mA0 = 1.0, mA1 = 0.0, mA2 = 0.0;
    float mX1[8] = {}, mX2[8] = {}, mY1[8] = {}, mY2[8] = {};
};

}  // namespace jamesdsp::examples
