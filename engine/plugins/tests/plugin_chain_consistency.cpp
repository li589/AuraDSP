#include "plugin_host.h"
#include "plugins/driver/plugin_chain_component.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr double kSampleRate = 48000.0;
constexpr uint32_t kBlock = 256;
constexpr uint32_t kBlocks = 8;

} // namespace

int main() {
    const char* path = "C:\\Program Files\\Common Files\\VST3\\ConvologyXT_64.vst3";
    int failures = 0;
    auto check = [&](bool ok, const char* what) {
        std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
        if (!ok) ++failures;
    };

    auradsp::PluginHostManager direct;
    auradsp::PluginChainComponent chained;

    check(chained.prepare(kSampleRate, kBlock), "chain prepare");

    const bool directLoaded =
        direct.loadPluginSlot(0, path, "", kSampleRate, kBlock);
    const bool chainLoaded =
        chained.host().loadPluginSlot(0, path, "", kSampleRate, kBlock);
    check(directLoaded && chainLoaded, "both load slot 0");
    if (!directLoaded || !chainLoaded) return 1;

    direct.setBypassSlot(0, false);
    chained.setBypass(0, false);

    check(direct.hasActivePluginSlot(0) && chained.hasActive(0), "slot active");
    check(direct.getLatencySlot(0) == chained.latency(0), "slot latency match");
    check(chained.totalLatency() == chained.latency(0), "total latency aggregation");

    const size_t total = static_cast<size_t>(kBlock) * kBlocks;
    std::vector<float> inL(total);
    std::vector<float> inR(total);
    std::vector<float> interleaved(total * 2);
    for (size_t i = 0; i < total; ++i) {
        const double t = static_cast<double>(i) / kSampleRate;
        const float l = static_cast<float>(0.25 * std::sin(2.0 * 3.14159265358979323846 * 997.0 * t));
        const float r = static_cast<float>(0.2 * std::sin(2.0 * 3.14159265358979323846 * 1499.0 * t + 0.3));
        inL[i] = l;
        inR[i] = r;
        interleaved[i * 2] = l;
        interleaved[i * 2 + 1] = r;
    }

    std::vector<float> directL(kBlock);
    std::vector<float> directR(kBlock);
    std::vector<float> block(kBlock * 2);
    std::vector<float> directInL(kBlock);
    std::vector<float> directInR(kBlock);

    float diffL = 0.0f;
    float diffR = 0.0f;
    float chainVsOriginal = 0.0f;
    for (int stage = 0; stage < 5; ++stage) {
        direct.setInsertStageSlot(0, stage);
        chained.host().setInsertStageSlot(0, stage);
        char msg[64];
        std::snprintf(msg, sizeof(msg), "stage %d latency aggregation", stage);
        check(chained.stageLatency(stage) == chained.latency(0), msg);

        float stageDiffL = 0.0f;
        float stageDiffR = 0.0f;
        for (uint32_t b = 0; b < kBlocks; ++b) {
            const size_t off = static_cast<size_t>(b) * kBlock;

            std::memcpy(directInL.data(), inL.data() + off, kBlock * sizeof(float));
            std::memcpy(directInR.data(), inR.data() + off, kBlock * sizeof(float));
            float* directIn[2] = {directInL.data(), directInR.data()};
            float* directOut[2] = {directL.data(), directR.data()};
            direct.processSlot(0, directIn, directOut, kBlock);

            std::memcpy(block.data(), interleaved.data() + off * 2,
                        kBlock * 2 * sizeof(float));
            chained.processInterleaved(stage, block.data(), kBlock);
            for (uint32_t i = 0; i < kBlock; ++i) {
                stageDiffL = std::max(stageDiffL,
                                      std::fabs(block[i * 2] - directL[i]));
                stageDiffR = std::max(stageDiffR,
                                      std::fabs(block[i * 2 + 1] - directR[i]));
                chainVsOriginal = std::max(
                    chainVsOriginal,
                    std::fabs(block[i * 2] - inL[off + i]));
                chainVsOriginal = std::max(
                    chainVsOriginal,
                    std::fabs(block[i * 2 + 1] - inR[off + i]));
            }
        }
        diffL = std::max(diffL, stageDiffL);
        diffR = std::max(diffR, stageDiffR);
    }

    check(diffL <= 1e-6f && diffR <= 1e-6f, "direct and chain outputs match in all stages");
    check(chainVsOriginal > 1e-6f, "chain actually processed audio");

    const bool directLoaded1 =
        direct.loadPluginSlot(1, path, "", kSampleRate, kBlock);
    const bool chainLoaded1 =
        chained.host().loadPluginSlot(1, path, "", kSampleRate, kBlock);
    check(directLoaded1 && chainLoaded1, "both load slot 1");
    if (!directLoaded1 || !chainLoaded1) return 1;

    direct.setInsertStageSlot(0, 2);
    direct.setInsertStageSlot(1, 2);
    chained.host().setInsertStageSlot(0, 2);
    chained.host().setInsertStageSlot(1, 2);
    direct.setBypassSlot(1, false);
    chained.setBypass(1, false);
    check(chained.stageLatency(2) == chained.latency(0) + chained.latency(1),
          "two-slot stage latency sum");

    std::vector<float> stageL(kBlock);
    std::vector<float> stageR(kBlock);
    float serialDiffL = 0.0f;
    float serialDiffR = 0.0f;
    for (uint32_t b = 0; b < kBlocks; ++b) {
        const size_t off = static_cast<size_t>(b) * kBlock;

        std::memcpy(directInL.data(), inL.data() + off, kBlock * sizeof(float));
        std::memcpy(directInR.data(), inR.data() + off, kBlock * sizeof(float));
        float* firstIn[2] = {directInL.data(), directInR.data()};
        float* firstOut[2] = {stageL.data(), stageR.data()};
        direct.processSlot(0, firstIn, firstOut, kBlock);
        float* secondOut[2] = {directL.data(), directR.data()};
        direct.processSlot(1, firstOut, secondOut, kBlock);

        std::memcpy(block.data(), interleaved.data() + off * 2,
                    kBlock * 2 * sizeof(float));
        chained.processInterleaved(2, block.data(), kBlock);
        for (uint32_t i = 0; i < kBlock; ++i) {
            serialDiffL = std::max(serialDiffL,
                                   std::fabs(block[i * 2] - directL[i]));
            serialDiffR = std::max(serialDiffR,
                                   std::fabs(block[i * 2 + 1] - directR[i]));
        }
    }
    check(serialDiffL <= 1e-6f && serialDiffR <= 1e-6f,
          "two slots in one stage match direct serial processing");

    direct.unloadPluginSlot(1);
    chained.host().unloadPluginSlot(1);

    direct.setInsertStageSlot(0, 4);
    chained.host().setInsertStageSlot(0, 4);
    std::memcpy(block.data(), interleaved.data(), kBlock * 2 * sizeof(float));
    chained.processInterleaved(0, block.data(), kBlock);
    bool inactiveExact = std::memcmp(block.data(), interleaved.data(),
                                     kBlock * 2 * sizeof(float)) == 0;
    check(inactiveExact, "inactive stage is bit-exact");

    direct.setBypassSlot(0, true);
    chained.setBypass(0, true);
    check(chained.stageLatency(4) == 0, "bypassed stage latency is zero");
    std::memcpy(block.data(), interleaved.data(), kBlock * 2 * sizeof(float));
    chained.processInterleaved(4, block.data(), kBlock);
    bool bypassExact = std::memcmp(block.data(), interleaved.data(),
                                   kBlock * 2 * sizeof(float)) == 0;
    check(bypassExact, "chain bypass is bit-exact");

    direct.setBypassSlot(0, false);
    chained.setBypass(0, false);
    direct.unloadPluginSlot(0);
    chained.reset();

    std::printf("max diff L=%.9g R=%.9g\n", diffL, diffR);
    std::printf("%s\n", failures == 0 ? "ALL TESTS PASSED" : "TESTS FAILED");
    return failures == 0 ? 0 : 1;
}
