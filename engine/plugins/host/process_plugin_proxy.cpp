#include "process_plugin_proxy.h"

#include <algorithm>
#include <cstring>

namespace auradsp {
namespace {
constexpr uint32_t kMissingLimit = 64;  // 64 * 128 frames ≈ 170 ms @ 48 kHz

void copyInfoToMetadata(const ipc::RemotePluginInfo& info, PluginMetadata& meta) {
    meta.path = info.path;
    meta.id = info.id;
    meta.name = info.name;
    meta.bundleName = info.bundleName;
    meta.vendor = info.vendor;
    meta.version = info.version;
    meta.category = info.category;
    meta.description = info.description;
    meta.errorMessage = info.errorMessage;
    meta.format = static_cast<PluginFormat>(info.format);
    meta.is64Bit = info.is64Bit != 0;
    meta.isCompatible = info.isCompatible != 0;
    meta.latency = info.latency;
}
} // namespace

ProcessPluginProxy::ProcessPluginProxy(std::shared_ptr<PluginHostClient> client,
                                       size_t slot, double sampleRate,
                                       uint32_t maxBlockSize)
    : m_client(std::move(client)),
      m_slot(slot),
      m_sampleRate(sampleRate),
      m_maxBlock(maxBlockSize) {}

ProcessPluginProxy::~ProcessPluginProxy() = default;

bool ProcessPluginProxy::load(const std::string& path, const std::string& pluginId,
                              const PluginMetadata* scanSeed) {
    (void)scanSeed;
    if (!m_client) return false;

    ipc::RemotePluginInfo info = {};
    std::string error;
    if (!m_client->load(static_cast<uint32_t>(m_slot), path, pluginId,
                        m_sampleRate, m_maxBlock, info, error)) {
        m_failed.store(true, std::memory_order_release);
        return false;
    }

    m_region = m_client->region();
    if (!m_region || m_slot >= ipc::kMaxSlots) {
        m_failed.store(true, std::memory_order_release);
        return false;
    }
    m_ring = &m_region->header()->slots[m_slot];
    m_ring->editorOpen.store(0, std::memory_order_release);
    copyInfoToMetadata(info, m_metadata);
    m_latency.store(info.latency + ipc::kTransportFrames, std::memory_order_release);

    m_inFill = 0;
    m_nextSeq = 0;
    m_outFill = 0;
    m_outPos = 0;
    m_missStreak = 0;
    m_failed.store(false, std::memory_order_release);
    m_bypassed.store(false, std::memory_order_release);
    m_loaded.store(true, std::memory_order_release);
    return true;
}

void ProcessPluginProxy::unload() {
    if (m_loaded.exchange(false, std::memory_order_acq_rel) && m_client) {
        m_client->closeEditor(static_cast<uint32_t>(m_slot));
        m_client->unload(static_cast<uint32_t>(m_slot));
    }
    m_editorOpen.store(false, std::memory_order_release);
    if (m_ring) m_ring->editorOpen.store(0, std::memory_order_release);
    m_bypassed.store(false, std::memory_order_release);
    m_inFill = 0;
    m_outFill = 0;
    m_outPos = 0;
}

bool ProcessPluginProxy::activate(double sampleRate, uint32_t maxBlockSize) {
    if (!m_loaded.load(std::memory_order_acquire)) return false;
    m_sampleRate = sampleRate;
    m_maxBlock = maxBlockSize;
    if (!m_client || !m_client->updateFormat(sampleRate, maxBlockSize)) {
        m_failed.store(true, std::memory_order_release);
        return false;
    }
    return true;
}

void ProcessPluginProxy::deactivate() {
}

void ProcessPluginProxy::copyBypass(float* const* inChannels, float* const* outChannels,
                                    uint32_t numFrames) const {
    if (!inChannels || !outChannels) return;
    for (uint32_t ch = 0; ch < ipc::kChannels; ++ch) {
        if (inChannels[ch] && outChannels[ch] &&
            inChannels[ch] != outChannels[ch]) {
            std::memcpy(outChannels[ch], inChannels[ch],
                        static_cast<size_t>(numFrames) * sizeof(float));
        }
    }
}

bool ProcessPluginProxy::submitChunk() {
    if (!m_ring) return false;
    auto& ring = *m_ring;
    const uint32_t w = ring.inputWrite.load(std::memory_order_relaxed);
    const uint32_t r = ring.inputRead.load(std::memory_order_acquire);
    if (w - r >= ipc::kRingBlocks) {
        ring.inputOverflows.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    ipc::AudioBlock& block = ring.input[w % ipc::kRingBlocks];
    block.seq = m_nextSeq++;
    block.frames = ipc::kTransportFrames;
    block.reserved = 0;
    std::memcpy(block.samples[0], m_inL, sizeof(m_inL));
    std::memcpy(block.samples[1], m_inR, sizeof(m_inR));
    ring.inputWrite.store(w + 1, std::memory_order_release);
    ring.chunksIn.fetch_add(1, std::memory_order_relaxed);
    return true;
}

bool ProcessPluginProxy::pumpOutput() {
    if (!m_ring || m_outPos < m_outFill) return m_outPos < m_outFill;
    auto& ring = *m_ring;
    const uint32_t w = ring.outputWrite.load(std::memory_order_acquire);
    const uint32_t r = ring.outputRead.load(std::memory_order_relaxed);
    if (w == r) return false;

    const ipc::AudioBlock& block = ring.output[r % ipc::kRingBlocks];
    const uint32_t frames = std::min<uint32_t>(block.frames, ipc::kTransportFrames);
    std::memcpy(m_outL, block.samples[0], static_cast<size_t>(frames) * sizeof(float));
    std::memcpy(m_outR, block.samples[1], static_cast<size_t>(frames) * sizeof(float));
    m_outFill = frames;
    m_outPos = 0;
    ring.outputRead.store(r + 1, std::memory_order_release);
    return frames > 0;
}

void ProcessPluginProxy::process(float* const* inChannels, float* const* outChannels,
                                 uint32_t numFrames) {
    if (!inChannels || !outChannels || numFrames == 0) return;
    if (!m_loaded.load(std::memory_order_acquire) ||
        m_failed.load(std::memory_order_acquire) ||
        m_bypassed.load(std::memory_order_acquire) || !m_ring) {
        copyBypass(inChannels, outChannels, numFrames);
        return;
    }

    float* inL = inChannels[0];
    float* inR = inChannels[1];
    float* outL = outChannels[0];
    float* outR = outChannels[1];
    if (!inL || !inR || !outL || !outR) return;

    for (uint32_t i = 0; i < numFrames; ++i) {
        if (m_outPos >= m_outFill) {
            pumpOutput();
        }
        if (m_outPos < m_outFill) {
            outL[i] = m_outL[m_outPos];
            outR[i] = m_outR[m_outPos];
            ++m_outPos;
        } else {
            outL[i] = inL[i];
            outR[i] = inR[i];
        }

        m_inL[m_inFill] = inL[i];
        m_inR[m_inFill] = inR[i];
        ++m_inFill;
        if (m_inFill == ipc::kTransportFrames) {
            submitChunk();
            m_inFill = 0;
            if (m_outPos >= m_outFill && !pumpOutput()) {
                if (++m_missStreak >= kMissingLimit) {
                    m_failed.store(true, std::memory_order_release);
                    m_bypassed.store(true, std::memory_order_release);
                }
            } else {
                m_missStreak = 0;
            }
        }
    }
}

bool ProcessPluginProxy::isLoaded() const {
    return m_loaded.load(std::memory_order_acquire);
}

bool ProcessPluginProxy::isBypassed() const {
    return m_bypassed.load(std::memory_order_acquire) ||
           m_failed.load(std::memory_order_acquire);
}

void ProcessPluginProxy::setBypass(bool bypass) {
    m_bypassed.store(bypass, std::memory_order_release);
    if (m_client && m_loaded.load(std::memory_order_acquire)) {
        m_client->setBypass(static_cast<uint32_t>(m_slot), bypass);
    }
}

uint32_t ProcessPluginProxy::getLatency() const {
    return m_latency.load(std::memory_order_acquire);
}

const PluginMetadata& ProcessPluginProxy::getMetadata() const {
    return m_metadata;
}

bool ProcessPluginProxy::showEditor(const std::string& title) {
    if (!m_client) return false;
    const bool ok = m_client->showEditor(static_cast<uint32_t>(m_slot), title);
    m_editorOpen.store(ok, std::memory_order_release);
    if (m_ring && ok) m_ring->editorOpen.store(1, std::memory_order_release);
    return ok;
}

void ProcessPluginProxy::closeEditor() {
    if (m_client) m_client->closeEditor(static_cast<uint32_t>(m_slot));
    m_editorOpen.store(false, std::memory_order_release);
    if (m_ring) m_ring->editorOpen.store(0, std::memory_order_release);
}

bool ProcessPluginProxy::isEditorOpen() const {
    if (m_failed.load(std::memory_order_acquire)) return false;
    if (m_ring) {
        return m_ring->editorOpen.load(std::memory_order_acquire) != 0;
    }
    return m_editorOpen.load(std::memory_order_acquire);
}

bool ProcessPluginProxy::savePreset(const std::string& filePath) {
    if (!m_client) return false;
    return m_client->savePreset(static_cast<uint32_t>(m_slot), filePath);
}

bool ProcessPluginProxy::loadPreset(const std::string& filePath) {
    if (!m_client) return false;
    const bool ok = m_client->loadPreset(static_cast<uint32_t>(m_slot), filePath);
    if (ok) {
        const uint32_t latency = m_client->getLatency(static_cast<uint32_t>(m_slot));
        m_latency.store(latency + ipc::kTransportFrames, std::memory_order_release);
    }
    return ok;
}

uint64_t ProcessPluginProxy::inputOverflows() const {
    return m_ring ? m_ring->inputOverflows.load(std::memory_order_relaxed) : 0;
}

uint64_t ProcessPluginProxy::outputOverflows() const {
    return m_ring ? m_ring->outputOverflows.load(std::memory_order_relaxed) : 0;
}

uint64_t ProcessPluginProxy::chunksIn() const {
    return m_ring ? m_ring->chunksIn.load(std::memory_order_relaxed) : 0;
}

uint64_t ProcessPluginProxy::chunksOut() const {
    return m_ring ? m_ring->chunksOut.load(std::memory_order_relaxed) : 0;
}

} // namespace auradsp
