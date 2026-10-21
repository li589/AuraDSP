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
    // F-4: output blocks lost upstream (host output-ring overflow, or
    // parameter-transition drops) counted via seq continuity checks.
    uint64_t seqGaps() const;
    bool remoteFailed() const {
        return m_failed.load(std::memory_order_acquire) ||
               (m_client && !m_client->alive());
    }
    uint32_t transportLatency() const { return ipc::kTransportFrames; }

private:
    // F-4/F-5: channels/mask are per-call (block-level) parameters — they no
    // longer live in members. The session-level bus channel count stays in
    // m_transportChannels, owned exclusively by setChannelHint.
    bool submitChunk(uint32_t channels, uint32_t mask);
    bool pumpOutput(uint32_t channels, uint32_t mask);
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

    // Proxy-side scratch buffers stay PLANAR (same layout as ipc::AudioBlock):
    // sample index for channel ch at frame i is ch * kTransportFrames + i.
    // Interleaving only happens at the public processInterleaved() boundary.
    float m_inPlanar[ipc::kChannels * ipc::kTransportFrames] = {};
    uint32_t m_inFill = 0;
    uint64_t m_nextSeq = 0;

    float m_outPlanar[ipc::kChannels * ipc::kTransportFrames] = {};
    uint32_t m_outFill = 0;
    uint32_t m_outPos = 0;
    uint32_t m_outChannels = 2;
    uint32_t m_outMask = 0xFF;

    /* F-5: bus channel count — written only by setChannelHint (control
     * thread), read by the audio thread (bypass width in copyBypass /
     * process()). Atomic because the two are different threads; the old
     * plain member was a data race between them. */
    std::atomic<uint32_t> m_transportChannels{2};

    // F-4: output-side seq continuity tracking (audio thread writes; status
    // reads from the control thread — both atomic).
    uint64_t m_nextSeqOut = 0;
    bool m_outSynced = false;
    std::atomic<uint64_t> m_seqGaps{0};
    std::atomic<uint32_t> m_missStreak{0};
};

} // namespace auradsp
