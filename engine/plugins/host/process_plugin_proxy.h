#pragma once

#include "plugin_host.h"
#include "plugin_host_client.h"

#include <atomic>
#include <cstdint>
#include <memory>

namespace auradsp {

class ProcessPluginProxy final : public IPluginInstance {
public:
    ProcessPluginProxy(std::shared_ptr<PluginHostClient> client, size_t slot,
                       double sampleRate, uint32_t maxBlockSize);
    ~ProcessPluginProxy() override;

    bool load(const std::string& path, const std::string& pluginId,
              const PluginMetadata* scanSeed = nullptr) override;
    void unload() override;
    bool activate(double sampleRate, uint32_t maxBlockSize) override;
    void deactivate() override;
    void process(float* const* inChannels, float* const* outChannels,
                 uint32_t numFrames) override;
    void processInterleaved(float* interleaved, uint32_t numFrames,
                            uint32_t channels, uint32_t mask) override;
    bool interleavedTransport() const override { return true; }
    void setChannelHint(int channels) override;
    bool isLoaded() const override;
    bool isBypassed() const override;
    bool hostTransportFailed() const override {
        return m_failed.load(std::memory_order_acquire);
    }
    void setBypass(bool bypass) override;
    uint32_t getLatency() const override;
    const PluginMetadata& getMetadata() const override;
    PluginBusInfo busInfo() const override { return m_busInfo; }

    bool showEditor(const std::string& title = "") override;
    void closeEditor() override;
    bool isEditorOpen() const override;

    bool savePreset(const std::string& filePath) override;
    bool loadPreset(const std::string& filePath) override;

    uint64_t inputOverflows() const;
    uint64_t outputOverflows() const;
    uint64_t chunksIn() const;
    uint64_t chunksOut() const;
    bool remoteFailed() const {
        return m_failed.load(std::memory_order_acquire) ||
               (m_client && !m_client->alive());
    }
    uint32_t transportLatency() const { return ipc::kTransportFrames; }

private:
    bool submitChunk();
    bool pumpOutput();
    void copyBypass(float* const* inChannels, float* const* outChannels,
                    uint32_t numFrames) const;

    std::shared_ptr<PluginHostClient> m_client;
    std::shared_ptr<SharedRegion> m_region;
    ipc::SlotAudioRing* m_ring = nullptr;
    size_t m_slot = 0;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlock = 1024;
    PluginMetadata m_metadata;
    PluginBusInfo m_busInfo;

    std::atomic<bool> m_loaded{false};
    std::atomic<bool> m_bypassed{false};
    std::atomic<bool> m_failed{false};
    std::atomic<bool> m_editorOpen{false};
    std::atomic<uint32_t> m_latency{0};

    float m_inInterleaved[ipc::kChannels * ipc::kTransportFrames] = {};
    uint32_t m_inFill = 0;
    uint64_t m_nextSeq = 0;

    float m_outInterleaved[ipc::kChannels * ipc::kTransportFrames] = {};
    uint32_t m_outFill = 0;
    uint32_t m_outPos = 0;
    uint32_t m_outChannels = 2;
    uint32_t m_outMask = 0xFF;
    uint32_t m_transportChannels = 2;
    uint32_t m_transportMask = 0xFF;

    uint32_t m_missStreak = 0;
};

} // namespace auradsp
