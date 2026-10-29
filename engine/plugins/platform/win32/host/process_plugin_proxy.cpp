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
    /* E15（2026-10-23 v2）总延迟 = 插件自身延迟 + 传输延迟，其中**传输延迟
     * 恒为 1 个回调 = N×128 帧**（N = 每次回调的传输块数 = 目标流水深）。
     *
     * 实测标定（ConvologyXT，48k，真实实时节流）：
     *   回调块 128 → 传输 128（总 416）  256 → 256（544）
     *   512 → 512（800）                1024 → 1024（1312）
     * 上报与实测**误差全为 0**。
     *
     * 历史坑（两次假设都被推翻）：
     *   - F-7 按 R-1 的 544 实测定 +2 块 → post-F-6 下过报（pre-F-6 宿主
     *     Sleep(1) 轮询慢一块，那 544 是当时的时序产物）；
     *   - 只看 128 帧回调会误以为「恒定 1 块」，但消费是帧到即取、一次调用
     *     微秒级跑完——多块回调下宿主不可能在调用内产出，固定深度 1/2 都会
     *     导致延迟随块大小漂移（512 帧实测 768）或大半干声。
     * 故本值随块数在 processInterleaved 里重算；getLatencySlot 对进程外
     * 槽取实时值。语义分层：transportLatency() = N×128（实际传输延迟，
     * UI 显示口径），不再是固定 128。 */
    // E15 v2：插件自身延迟单独记账；传输项 = 目标深度 × 块长（随回调块大小
    // 自适应，见 processInterleaved 的块数变更分支）。
    m_pluginLatency.store(info.latency, std::memory_order_release);
    m_targetInFlight.store(1, std::memory_order_release);
    // 首块前的保守口径：假设 128 帧回调（N=1）。首块后按实际块数重算。
    m_latency.store(info.latency + ipc::kTransportFrames,
                    std::memory_order_release);

    m_inFill = 0;
    m_nextSeq = 0;
    m_outFill = 0;
    m_outPos = 0;
    m_missStreak.store(0, std::memory_order_relaxed);
    m_gotOutputThisBlock = false;
    m_blockHadPassthrough = false;
    m_nextSeqOut = 0;
    m_outSynced = false;
    m_seqGaps.store(0, std::memory_order_relaxed);
    // E15：深度记账随每次加载归零（新流水从 0 起，高水位与违例清零）。
    m_inFlight.store(0, std::memory_order_relaxed);
    m_maxInFlight.store(0, std::memory_order_relaxed);
    m_depthViolations.store(0, std::memory_order_relaxed);
    m_depthDrops.store(0, std::memory_order_relaxed);
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
    // E15：卸载后在途块已作废（宿主侧随之清空），深度归零防下一会话误判。
    m_inFlight.store(0, std::memory_order_relaxed);
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

/* E15（2026-10-23 v2）确定性流水深 = 每次回调的传输块数 N。
 * 见头文件 m_targetInFlight 注释：固定深度与「帧到即取」的消费模型不相容
 * （N 块回调只能拿到深度个湿声块），实测延迟随 N 线性漂移。深度=N 时延迟
 * 恒为 1 个回调，上报 = 插件延迟 + N×kTransportFrames 精确。
 * 旧实现完全无上限：宿主跟不上时队列涨到环容量 16 块，上报仍写 +1 块。 */

/* E15：取回一块输出 = 流水深度 -1（钳制不下溢——跨会话 residue 可能
 * 对不上旧提交）。 */
void ProcessPluginProxy::ConsumeDepthOne() {
    const uint32_t cur = m_inFlight.load(std::memory_order_relaxed);
    if (cur > 0) m_inFlight.fetch_sub(1, std::memory_order_relaxed);
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
    /* E15：深度 +1（提交成功才记账；环满丢块不计）。高水位只在音频线程
     * 写、status 从控制线程读，relaxed 足够——纯观测用途。 */
    {
        const uint32_t depth =
            m_inFlight.fetch_add(1, std::memory_order_relaxed) + 1;
        if (depth > m_maxInFlight.load(std::memory_order_relaxed)) {
            m_maxInFlight.store(depth, std::memory_order_relaxed);
        }
    }
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
            ConsumeDepthOne();
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
            ConsumeDepthOne();
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
        ConsumeDepthOne();
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
    /* E15 v2：目标深度 = 本次回调的传输块数（1..环容量）。块大小变更时
     * 同步重算上报 latency = 插件延迟 + N×块长（延迟恒为 1 个回调）。
     * 音频线程写、控制线程读 status/latency → release/acquire。 */
    {
        uint32_t chunks = (numFrames + ipc::kTransportFrames - 1) /
                          ipc::kTransportFrames;
        if (chunks == 0) chunks = 1;
        if (chunks > ipc::kRingBlocks) chunks = ipc::kRingBlocks;
        if (chunks != m_targetInFlight.load(std::memory_order_relaxed)) {
            m_targetInFlight.store(chunks, std::memory_order_release);
            m_latency.store(m_pluginLatency.load(std::memory_order_relaxed) +
                                chunks * ipc::kTransportFrames,
                            std::memory_order_release);
        }
    }
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
        } else {
            /* E14: 本帧无输出可用 → 原样直通（interleaved 保持输入值）。
             * 标记本块，块边界据此丢弃不提交（防双发）。 */
            m_blockHadPassthrough = true;
        }

        ++m_inFill;
        if (m_inFill == ipc::kTransportFrames) {
            m_inFill = 0;
            /* E14: 直通块丢弃不提交——直通内容已被上层听见，再提交会让宿主
             * 处理结果（回声）稍后再次进入输出流，同一段音频听到两遍（R-1
             * 轮「帧 0 与帧 544 双脉冲」同源）。破鸡生蛋：宿主必须有输入才
             * 产输出，丢弃后若不补位，宿主队列耗尽即永久空闲——后续块全部
             * 直通+丢弃，饿死螺旋（替换重载场景实测：processCalls 冻结 +
             * 64 块判死）。故只要宿主存活就提交一个静音 prime 块补位：其
             * 回声≈静音无听感，下一块起流水恢复；健康流水无直通 → 零
             * prime。宿主始终不应答时由 E12 missStreak（m_outSynced 建立
             * 后）与 remoteFailed(!alive) 判死兜底。
             * F-4/E12: 输入环满丢块仍是饥饿证据，计入 miss 窗口；prime 提交
             * 失败不计数（丢弃块的补位非流水数据）。 */
            /* E15：提交前守深度不变量（>1 结构上不可达——E14 保证带直通帧
             * 的块不提交，且下方硬上限只允许 0→1；此处仅作哨兵）。 */
            /* E15 硬上限：深度已满则本块不提交（直通）。宿主手上有活 →
             * 不会饿死，prime 也无需补位。
             * 注意：块大小切换（设备缓冲变化）会让目标深度变化，此时在途块
             * 可能暂时多于新目标——那是正常过渡（残留会被后续帧消费掉），
             * **不计入 depthViolations**。该计数器只表示「上限被绕过」，
             * 而提交路径上的 depthFull 判定使其结构上恒为 0。 */
            const uint32_t target =
                m_targetInFlight.load(std::memory_order_relaxed);
            const bool depthFull =
                m_inFlight.load(std::memory_order_relaxed) >= target;
            /* depthViolations 在此不再自增：上限由 depthFull 在提交路径强制，
             * 越界结构上不可能。字段保留是为 status 兼容与「恒 0」断言。 */
            if (!m_blockHadPassthrough) {
                if (depthFull) {
                    m_depthDrops.fetch_add(1, std::memory_order_relaxed);
                } else if (!submitChunk(channels, mask)) {
                    m_missStreak.fetch_add(1, std::memory_order_relaxed);
                }
            } else if (m_client && m_client->alive() && !depthFull) {
                for (uint32_t ch = 0; ch < ipc::kChannels; ++ch) {
                    std::memset(m_inPlanar + ch * ipc::kTransportFrames, 0,
                                ipc::kTransportFrames * sizeof(float));
                }
                submitChunk(channels, mask);
            }
            m_blockHadPassthrough = false;
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

uint32_t ProcessPluginProxy::depthTarget() const {
    return m_targetInFlight.load(std::memory_order_acquire);
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
        /* E15: 与 load() 同口径——插件延迟 + 1×传输块（见 load 处注释）。 */
        m_latency.store(latency + ipc::kTransportFrames,
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
