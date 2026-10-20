#pragma once

#include "plugin_host.h"

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

    void setBypass(int slot, bool bypass) noexcept;
    bool bypass(int slot) const noexcept;
    uint32_t latency(int slot) const noexcept;
    uint32_t stageLatency(int stage) const noexcept;
    uint32_t totalLatency() const noexcept;
    bool hasActive(int slot) const noexcept;

    PluginHostManager& host() noexcept { return *m_host; }
    const PluginHostManager& host() const noexcept { return *m_host; }

private:
    bool stageHasActive(int stage) const noexcept;

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
};

} // namespace auradsp
