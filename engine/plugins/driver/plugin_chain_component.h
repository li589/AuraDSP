#pragma once

#include "plugin_host.h"
#include "delay_line.h"

#include <atomic>
#include <array>
#include <cstdint>
#include <memory>

namespace auradsp {

class PluginChainComponent {
public:
    PluginChainComponent();
    ~PluginChainComponent();

    PluginChainComponent(const PluginChainComponent&) = delete;
    PluginChainComponent& operator=(const PluginChainComponent&) = delete;

    bool prepare(double sampleRate, uint32_t maxBlockSize);
    void reset();

    void process(int stage, float* const* in, float* const* out,
                 uint32_t frames) noexcept;
    void processInterleaved(int stage, float* interleaved,
                            uint32_t frames) noexcept;
    void processInterleavedN(int stage, float* interleaved, uint32_t frames,
                             uint32_t channels) noexcept;
    void setChannelHint(int channels) noexcept;

    void setBypass(int slot, bool bypass) noexcept;
    bool bypass(int slot) const noexcept;
    uint32_t latency(int slot) const noexcept;
    uint32_t stageLatency(int stage) const noexcept;
    uint32_t totalLatency() const noexcept;
    bool hasActive(int slot) const noexcept;

    void setPdc(bool enable) noexcept { m_pdcEnabled.store(enable, std::memory_order_release); }
    bool pdc() const noexcept { return m_pdcEnabled.load(std::memory_order_acquire); }

    PluginHostManager& host() noexcept { return *m_host; }
    const PluginHostManager& host() const noexcept { return *m_host; }

private:
    bool stageHasActive(int stage) const noexcept;
    bool stageHasActiveOrPdc(int stage) const noexcept;

    std::unique_ptr<PluginHostManager> m_host;
    std::unique_ptr<float[]> m_chanInL;
    std::unique_ptr<float[]> m_chanInR;
    std::unique_ptr<float[]> m_chanOutL;
    std::unique_ptr<float[]> m_chanOutR;
    std::unique_ptr<float[]> m_workAL;
    std::unique_ptr<float[]> m_workAR;
    std::unique_ptr<float[]> m_workBL;
    std::unique_ptr<float[]> m_workBR;
    uint32_t m_maxBlock = 0;

    std::atomic<bool> m_pdcEnabled{false};
    std::array<DelayLine, PluginHostManager::kMaxPluginSlots> m_delayLines;
    std::array<MultiDelayLine, PluginHostManager::kMaxPluginSlots> m_multiDelayLines;
    std::array<uint32_t, PluginHostManager::kMaxPluginSlots> m_lastMasks{};
};

} // namespace auradsp
