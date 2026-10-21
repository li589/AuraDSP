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
    /* F-6: 缓存宿主唤醒事件（借用句柄）。置于控制路径，音频线程后续
     * SetEvent 无需再加锁；load 成功前的失败路径不会走到这里。 */
    m_wakeEvent = m_client->wakeEvent();
    copyInfoToMetadata(info, m_metadata);
    m_busInfo = PluginBusInfo{};
    m_busInfo.inputBuses = static_cast<int>(info.inputBuses);
    m_busInfo.outputBuses = static_cast<int>(info.outputBuses);
    m_busInfo.auxInputBuses = static_cast<int>(info.auxInputBuses);
    m_busInfo.auxOutputBuses = static_cast<int>(info.auxOutputBuses);
    m_busInfo.mainInChannels = static_cast<int>(info.mainInChannels);
    m_busInfo.mainOutChannels = static_cast<int>(info.mainOutChannels);
    /* F-7: 总延迟 = 插件自身延迟 + 2 个传输块。一次 processInterleaved 调用
     * 的端到端流水深：调用方提交的块先在输入环排队（1 块），宿主处理后块进
     * 输出环，代理下一次 pump 才取得（再 1 块）。R-1 实测背书：Convology XT
     * 脉冲响应出现在第 544 样本 = 288（插件）+ 256（2×128 传输块）。
     * 语义分层：getLatency() = 端到端总量（本公式，Dart UI/测试消费）；
     * transportLatency() = 单块传输粒度 128（不变，UI 的分辨显示口径）。 */
    m_latency.store(info.latency + 2 * ipc::kTransportFrames,
                    std::memory_order_release);

    m_inFill = 0;
    m_nextSeq = 0;
    m_outFill = 0;
    m_outPos = 0;
    m_missStreak.store(0, std::memory_order_relaxed);
    m_gotOutputThisBlock = false;
    m_nextSeqOut = 0;
    m_outSynced = false;
    m_seqGaps.store(0, std::memory_order_relaxed);
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
    m_outSynced = false;
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
    if (!inChannels || !outChannels || numFrames == 0) return;
    /* F-5: bypass width follows the bus channel count (setChannelHint
     * semantics) — not the last call's plugChannels, which used to collapse
     * multichannel bypass to the plugin's channel count and silently drop
     * ch2+ (bypassing the stage-2 "beyond-plugin passthrough" fix). */
    const uint32_t channels = (std::max)(
        2u, (std::min)(m_transportChannels.load(std::memory_order_acquire),
                       ipc::kChannels));
    for (uint32_t ch = 0; ch < channels; ++ch) {
        if (inChannels[ch] && outChannels[ch] &&
            inChannels[ch] != outChannels[ch]) {
            std::memcpy(outChannels[ch], inChannels[ch],
                        static_cast<size_t>(numFrames) * sizeof(float));
        }
    }
}

bool ProcessPluginProxy::submitChunk(uint32_t channels, uint32_t mask) {
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
    block.reserved = ipc::packTransportFlags(channels, mask);
    for (uint32_t ch = 0; ch < ipc::kChannels; ++ch) {
        std::memcpy(block.samples[ch],
                    m_inPlanar + ch * ipc::kTransportFrames,
                    ipc::kTransportFrames * sizeof(float));
    }
    ring.inputWrite.store(w + 1, std::memory_order_release);
    ring.chunksIn.fetch_add(1, std::memory_order_relaxed);
    /* F-6: 唤醒宿主音频线程——每接受一个传输块一次。SetEvent 是纯内核
     * 调用（~1μs，无分配无锁，与 WASAPI 事件驱动同款实践），满足音频
     * 路径 RT-safe 契约；句柄为空（宿主未起/事件缺失）时静默跳过，
     * 宿主靠 2 ms 等待超时兜底。 */
    if (m_wakeEvent) SetEvent(m_wakeEvent);
    return true;
}

bool ProcessPluginProxy::pumpOutput(uint32_t channels, uint32_t mask) {
    if (!m_ring || m_outPos < m_outFill) return m_outPos < m_outFill;
    auto& ring = *m_ring;
    for (;;) {
        const uint32_t w = ring.outputWrite.load(std::memory_order_acquire);
        const uint32_t r = ring.outputRead.load(std::memory_order_relaxed);
        if (w == r) return false;

        const ipc::AudioBlock& block = ring.output[r % ipc::kRingBlocks];
        const uint32_t frames =
            (std::min)(block.frames, ipc::kTransportFrames);
        const uint32_t blockChannels = ipc::unpackTransportChannels(block.reserved);
        const uint32_t blockMask = ipc::unpackTransportMask(block.reserved);

        /* F-4: seq continuity. The host echoes the submitted seq on every
         * output block (auradsp_plugin_host_main.cpp L444), so a gap between
         * block.seq and the expected next seq means blocks were lost
         * upstream — either the host dropped them (output ring overflow =
         * proxy consumption starvation) or a parameter-transition drop
         * consumed them. Before this check, such losses were invisible:
         * pumpOutput simply moved to the next block and the audio stream
         * silently jumped forward by whole transport blocks. */
        const bool stale = m_outSynced && block.seq < m_nextSeqOut;
        if (stale) {
            /* Pre-resync residue (e.g. blocks still in flight across a
             * reload): discard silently, keep the expected cursor. */
            ring.outputRead.store(r + 1, std::memory_order_release);
            continue;
        }
        const bool mismatch = blockChannels != channels || blockMask != mask;
        if (mismatch) {
            /* Parameter-transition drop: a legitimate one-time cost of a
             * channel/mask change (in-flight blocks carry the old flags).
             * Counted in seqGaps for observability but NOT in missStreak —
             * a hint change must not fail an otherwise healthy session. */
            if (m_outSynced) {
                m_seqGaps.fetch_add(block.seq - m_nextSeqOut + 1,
                                    std::memory_order_relaxed);
                m_nextSeqOut = block.seq + 1;
            }
            ring.outputRead.store(r + 1, std::memory_order_release);
            continue;
        }

        if (!m_outSynced) {
            /* First block after load/reload: establish the baseline, never
             * a gap (the host may have restarted with its own counter). */
            m_outSynced = true;
            m_nextSeqOut = block.seq + 1;
        } else if (block.seq > m_nextSeqOut) {
            const uint64_t gap = block.seq - m_nextSeqOut;
            m_seqGaps.fetch_add(gap, std::memory_order_relaxed);
            m_missStreak.fetch_add(1, std::memory_order_relaxed);
            m_nextSeqOut = block.seq + 1;
        } else {
            m_nextSeqOut = block.seq + 1;
        }

        for (uint32_t ch = 0; ch < ipc::kChannels; ++ch) {
            std::memcpy(m_outPlanar + ch * ipc::kTransportFrames,
                        block.samples[ch], frames * sizeof(float));
        }
        m_outChannels = channels;
        m_outMask = mask;
        m_outFill = frames;
        m_outPos = 0;
        /* E12: 本块内取到了输出 = 宿主应答存活，块边界据此清零饥饿窗口。 */
        m_gotOutputThisBlock = true;
        ring.outputRead.store(r + 1, std::memory_order_release);
        return frames > 0;
    }
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

    /* F-5: bypass/beyond-plugin passthrough width follows the bus channel
     * count (setChannelHint semantics), not the per-call plugChannels. */
    const uint32_t channels = (std::max)(
        2u, (std::min)(m_transportChannels.load(std::memory_order_acquire),
                       ipc::kChannels));
    uint32_t plugChannels = (m_busInfo.mainInChannels > 0)
                                ? static_cast<uint32_t>(m_busInfo.mainInChannels)
                                : 2u;
    if (plugChannels > channels) plugChannels = channels;
    if (plugChannels > ipc::kChannels) plugChannels = ipc::kChannels;

    for (uint32_t ch = 0; ch < plugChannels; ++ch) {
        if (!inChannels[ch] || !outChannels[ch]) {
            copyBypass(inChannels, outChannels, numFrames);
            return;
        }
    }

    float block[ipc::kChannels * ipc::kTransportFrames];
    uint32_t offset = 0;
    while (offset < numFrames) {
        const uint32_t n = (std::min)(ipc::kTransportFrames, numFrames - offset);
        for (uint32_t i = 0; i < n; ++i) {
            for (uint32_t ch = 0; ch < plugChannels; ++ch) {
                block[i * plugChannels + ch] = inChannels[ch][offset + i];
            }
        }
        processInterleaved(block, n, plugChannels, (1u << plugChannels) - 1u);
        for (uint32_t i = 0; i < n; ++i) {
            for (uint32_t ch = 0; ch < plugChannels; ++ch) {
                outChannels[ch][offset + i] = block[i * plugChannels + ch];
            }
        }
        offset += n;
    }

    for (uint32_t ch = plugChannels; ch < channels; ++ch) {
        if (inChannels[ch] && outChannels[ch] &&
            inChannels[ch] != outChannels[ch]) {
            std::memcpy(outChannels[ch], inChannels[ch],
                        static_cast<size_t>(numFrames) * sizeof(float));
        }
    }
}

void ProcessPluginProxy::processInterleaved(float* interleaved, uint32_t numFrames,
                                             uint32_t channels, uint32_t mask) {
    if (!interleaved || numFrames == 0 || channels == 0) return;
    if (channels > ipc::kChannels) channels = ipc::kChannels;
    mask &= (1u << channels) - 1u;
    if (!m_loaded.load(std::memory_order_acquire) ||
        m_failed.load(std::memory_order_acquire) ||
        m_bypassed.load(std::memory_order_acquire) || !m_ring) {
        return;
    }

    /* F-5: channels/mask are per-call block parameters — they are passed
     * down to submitChunk/pumpOutput instead of overwriting the
     * session-level bus hint (m_transportChannels, setChannelHint-owned).
     * The old member write was both a semantic corruption (bus hint became
     * "whatever the last call used") and a data race (audio thread vs
     * control thread on a plain member). */
    for (uint32_t i = 0; i < numFrames; ++i) {
        float inFrame[ipc::kChannels] = {};
        for (uint32_t ch = 0; ch < channels; ++ch) {
            inFrame[ch] = interleaved[i * channels + ch];
            m_inPlanar[ch * ipc::kTransportFrames + m_inFill] = inFrame[ch];
        }

        if (m_outPos >= m_outFill) pumpOutput(channels, mask);
        if (m_outPos < m_outFill) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                if ((m_outMask & (1u << ch)) && ch < m_outChannels) {
                    interleaved[i * channels + ch] =
                        m_outPlanar[ch * ipc::kTransportFrames + m_outPos];
                } else {
                    interleaved[i * channels + ch] = inFrame[ch];
                }
            }
            ++m_outPos;
        }

        ++m_inFill;
        if (m_inFill == ipc::kTransportFrames) {
            /* F-4: a dropped input block (ring full) used to be silent —
             * the 128 frames never reached the host and no counter moved.
             * It is starvation evidence, so it now feeds the same miss
             * window as a missing output block. */
            const bool submitted = submitChunk(channels, mask);
            m_inFill = 0;
            /* E12: 块尾 prefetch 保留（帧首取块失败时，迟到的输出块可在此
             * 入缓冲供下一块消费），但**不再**把 prefetch 失败当饥饿——那
             * 是健康流水下的常态：本块刚提交，宿主不可能微秒级返回。饥饿
             * 的正确口径 = 流水建立（m_outSynced）后整块零输出；首块输出
             * 尚未到达（宿主启动中）不计入，防慢启动误判。 */
            if (m_outPos >= m_outFill) pumpOutput(channels, mask);
            const bool gotOutput = m_gotOutputThisBlock;
            m_gotOutputThisBlock = false;
            if (gotOutput) {
                m_missStreak.store(0, std::memory_order_relaxed);
            } else if (m_outSynced) {
                m_missStreak.fetch_add(1, std::memory_order_relaxed);
            }
            if (!submitted) {
                m_missStreak.fetch_add(1, std::memory_order_relaxed);
            }
            if (m_missStreak.load(std::memory_order_relaxed) >= kMissingLimit) {
                m_failed.store(true, std::memory_order_release);
                m_bypassed.store(true, std::memory_order_release);
            }
        }
    }
}

void ProcessPluginProxy::setChannelHint(int channels) {
    if (channels < 1) channels = 1;
    if (channels > static_cast<int>(ipc::kChannels)) channels = ipc::kChannels;
    /* F-5: this is the ONLY writer of m_transportChannels — the bus channel
     * count. The audio thread reads it for bypass width; the store is
     * release so a reader that observes the new value also observes every
     * prior store on this thread. */
    m_transportChannels.store(static_cast<uint32_t>(channels),
                              std::memory_order_release);
    if (m_client && m_loaded.load(std::memory_order_acquire)) {
        m_client->setChannelHint(static_cast<uint32_t>(channels));
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
        /* F-7: 与 load() 同口径——插件延迟 + 2×传输块（见 load 处注释）。 */
        m_latency.store(latency + 2 * ipc::kTransportFrames,
                        std::memory_order_release);
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

uint64_t ProcessPluginProxy::seqGaps() const {
    return m_seqGaps.load(std::memory_order_relaxed);
}

} // namespace auradsp
