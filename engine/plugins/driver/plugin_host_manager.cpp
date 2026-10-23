#include "plugin_host.h"
#include "debug_log.h"  // B-1 统一调试日志宏

#include "inflight_guard.h"
#include "plugin_format_driver.h"

#ifndef AURADSP_HOST_INPROC
#include "process_plugin_proxy.h"
#endif

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>
#include <string>

namespace auradsp {

/* F-8a：遥测测量抽取周期（音频块）。8 块 @ 48kHz/256 帧 ≈ 43ms → ~23Hz
 * 刷新，仍高于 UI 轮询与肉眼 meter 需求；块率更高时（低延迟小块）刷新
 * 同步加快，块率更低时（大块/高采样率）最坏 ~43ms 陈旧，meter 不可感知。
 * 仅门控 RMS/diff 测量，插件 process 音频路径不受任何影响。 */
constexpr uint32_t kTelemetryDecimation = 8;

static inline uint32_t packFloat(float v) {
    uint32_t u = 0;
    std::memcpy(&u, &v, sizeof(u));
    return u;
}

static inline float unpackFloat(uint32_t u) {
    float v = 0.0f;
    std::memcpy(&v, &u, sizeof(v));
    return v;
}
/* SEH 崩溃隔离。
 * MSVC 限制：__try 不能出现在需要 C++ 对象展开（ unwind）的函数中（C2712），
 * 而 processSlot 内有 InFlightGuard 析构，故把 SEH 段隔离到这个无对象函数。
 * 返回 0 = 正常，1 = 捕获到插件异常（调用方据此自动旁路该槽）。 */
int processSlotGuarded(PluginHostManager::PluginSlot& s,
                              float* const* inChannels, float* const* outChannels,
                              uint32_t numFrames) {
#if defined(_MSC_VER)
    __try {
        if (s.instance) s.instance->process(inChannels, outChannels, numFrames);
        return 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return 1;
    }
#else
    try {
        if (s.instance) s.instance->process(inChannels, outChannels, numFrames);
        return 0;
    } catch (...) {
        return 1;
    }
#endif
}

void quarantineAbandonedInstance(std::unique_ptr<IPluginInstance> inst) {
    static auto* s_leak = new std::vector<std::unique_ptr<IPluginInstance>>();
    static std::mutex s_leakMutex;
    std::lock_guard<std::mutex> lock(s_leakMutex);
    s_leak->push_back(std::move(inst));
}

void PluginHostManager::unloadPluginSlotLocked(size_t slot) {
    if (slot >= kMaxPluginSlots) return;
    PluginSlot& s = m_slots[slot];
    s.hasActive.store(false, std::memory_order_release);
    s.destroyPending.store(true, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_acquire);

    uint32_t spins = 0;
    while (s.inFlight.load(std::memory_order_relaxed) != 0 && spins < kQuiesceSpinLimit) {
        s.inFlight.wait(0, std::memory_order_relaxed);
        ++spins;
    }
    s.destroyPending.store(false, std::memory_order_relaxed);
    // 强制排空安全兜底：即便音频流非活动导致计数悬垂，也绝不能锁死用户卸载
    s.inFlight.store(0, std::memory_order_relaxed);

        s.latency.store(0, std::memory_order_relaxed);
        s.mainInChannels.store(2, std::memory_order_relaxed);
        s.mainOutChannels.store(2, std::memory_order_relaxed);
        s.processCalls.store(0, std::memory_order_relaxed);
        s.inRmsBits.store(0, std::memory_order_relaxed);
        s.outRmsBits.store(0, std::memory_order_relaxed);
        s.maxDiffBits.store(0, std::memory_order_relaxed);
        s.lastFrames.store(0, std::memory_order_relaxed);
        resetTelemetryGateSlot(slot);
        if (s.instance) {
            AURADSP_DBG_S("[DBG Slot] unloadLocked[" << slot << "] quiesced (spins=" << spins << "), calling closeEditor");
            s.instance->closeEditor();
            AURADSP_DBG_S("[DBG Slot] unloadLocked[" << slot << "] deactivate");
            s.instance->deactivate();
            AURADSP_DBG_S("[DBG Slot] unloadLocked[" << slot << "] unload");
            s.instance->unload();
            if (s.instance->abandoned()) {
                // 隔离（放弃释放）：内部线程挂死且仍引用实例，析构 =
                // use-after-free。整体移入隔离区（可控泄漏换不可控崩溃）。
                quarantineAbandonedInstance(std::move(s.instance));
                AURADSP_WARN_S("[DBG Slot] unloadLocked[" << slot << "] quarantined (abandoned)");
            } else {
                AURADSP_DBG_S("[DBG Slot] unloadLocked[" << slot << "] reset (dtor)");
                s.instance.reset();
            }
            AURADSP_DBG_S("[DBG Slot] unloadLocked[" << slot << "] complete");
        } else {
            AURADSP_DBG_S("[DBG Slot] unloadLocked[" << slot << "] no instance");
        }
    }

void PluginHostManager::unloadPluginSlot(size_t slot) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    unloadPluginSlotLocked(slot);
}

bool PluginHostManager::loadPluginSlot(size_t slot, const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize) {
    if (slot >= kMaxPluginSlots) return false;

#ifndef AURADSP_HOST_INPROC
    if (m_remoteMode && m_remoteClient) {
        std::unique_ptr<IPluginInstance> oldInstance;
        {
            std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
            m_sampleRate = sampleRate;
            m_maxBlockSize = maxBlockSize;
            oldInstance = detachInstanceLocked(slot);
        }
        if (oldInstance) destroyInstance(std::move(oldInstance));

        ensureChannelScratch(maxBlockSize);
        m_remoteClient->setChannelHint(
            static_cast<uint32_t>(m_channelHint.load(std::memory_order_relaxed)));
        auto instance = std::make_unique<ProcessPluginProxy>(
            m_remoteClient, slot, sampleRate, maxBlockSize);
        if (!instance->load(path, pluginId)) return false;

        /* R-1：宿主进程懒启动于本分支的首个请求（setChannelHint/load），
         * 而 create 期 updateFormat 的转发被 alive() 守卫跳过、此后不再补发，
         * 宿主侧格式与通道 scratch 可能从未初始化（processSlotInterleaved
         * 静默直通）。Op::Load 消息虽已携带格式，此处再补发一次 updateFormat
         * 作为兜底：保证宿主侧格式/scratch 与引擎当前格式一致，且覆盖
         * create 之后、load 之前发生过格式变更的场景。 */
        m_remoteClient->updateFormat(sampleRate, maxBlockSize);

        {
            std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
            commitInstanceLocked(slot, std::move(instance));
        }
        return true;
    }
#endif

    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    try {
        unloadPluginSlotLocked(slot);

        m_sampleRate = sampleRate;
        m_maxBlockSize = maxBlockSize;
        ensureChannelScratch(maxBlockSize);

        auto* driver = PluginDriverRegistry::instance().findForPath(path);
        if (!driver) return false;
        if (driver->resolveBinary(path).empty()) return false;

        auto instance = driver->createInstance();
        if (!instance) return false;

        // 扫描期命中项作为种子传入：加载路以扫描值为基准，descriptor 只补空不覆盖，
        // 于是「扫描值 == 加载值」对扫描期已有的字段恒成立（B1 的结构性保证）。
        // 无种子（例如从会话恢复直接加载、或该路径从未扫描）时退化为纯描述符路径，
        // 而两条路共用同一填充函数，优先级一致，结论仍相同。
        const PluginMetadata* seed = nullptr;
        for (const auto& p : m_scannedPlugins) {
            if (p.path != path) continue;
            if (!pluginId.empty() && !p.id.empty() && p.id != pluginId) continue;
            seed = &p;
            break;
        }

        bool lRet = instance->load(path, pluginId, seed);
        AURADSP_DBG_S("[DBG PluginHost] instance->load returned: " << lRet);
        if (!lRet) {
            if (instance->abandoned()) {
                // load 阶段线程挂死 → 隔离区（同 unloadPluginSlotLocked）。
                quarantineAbandonedInstance(std::move(instance));
                AURADSP_WARN("[DBG PluginHost] instance quarantined (abandoned during load)");
            }
            return false;
        }

        instance->setChannelHint(m_channelHint.load());
        bool aRet = instance->activate(sampleRate, maxBlockSize);
        AURADSP_DBG_S("[DBG PluginHost] instance->activate returned: " << aRet);
        if (!aRet) {
            instance->unload();
            if (instance->abandoned()) {
                quarantineAbandonedInstance(std::move(instance));
                AURADSP_WARN("[DBG PluginHost] instance quarantined (abandoned during activate-unload)");
            }
            return false;
        }

        commitInstanceLocked(slot, std::move(instance));
        return true;
    } catch (const std::exception& e) {
        unloadPluginSlotLocked(slot);
        return false;
    } catch (...) {
        unloadPluginSlotLocked(slot);
        return false;
    }
}

void PluginHostManager::setBypassSlot(size_t slot, bool bypass) {
    if (slot >= kMaxPluginSlots) return;
    m_slots[slot].bypassed.store(bypass, std::memory_order_release);
    // F-8a：旁通切换后首个音频块刷新遥测（解除旁通时不读到切换前的陈旧值）
    resetTelemetryGateSlot(slot);
    if (m_slots[slot].instance) {
        m_slots[slot].instance->setBypass(bypass);
    }
}

bool PluginHostManager::isBypassedSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return true;
    if (m_slots[slot].bypassed.load(std::memory_order_acquire)) return true;
    return m_slots[slot].instance && m_slots[slot].instance->hostTransportFailed();
}

uint32_t PluginHostManager::getLatencySlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return 0;
    return m_slots[slot].latency.load(std::memory_order_relaxed);
}

bool PluginHostManager::hasActivePluginSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return false;
    return m_slots[slot].hasActive.load(std::memory_order_acquire);
}

std::string PluginHostManager::getStatusJsonSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return "{}";
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    std::ostringstream ss;
    ss << "{"
       << "\"slot\":" << slot << ","
       << "\"hasActive\":" << (m_slots[slot].hasActive.load() ? "true" : "false") << ","
       << "\"bypassed\":" << (isBypassedSlot(slot) ? "true" : "false") << ","
       << "\"latency\":" << m_slots[slot].latency.load() << ","
       << "\"insertStage\":" << m_slots[slot].insertStage.load() << ","
       << "\"channels\":" << m_slots[slot].channelMask.load() << ","
       << "\"processCalls\":" << m_slots[slot].processCalls.load(std::memory_order_relaxed) << ","
       << "\"inRms\":" << unpackFloat(m_slots[slot].inRmsBits.load(std::memory_order_relaxed)) << ","
       << "\"outRms\":" << unpackFloat(m_slots[slot].outRmsBits.load(std::memory_order_relaxed)) << ","
       << "\"maxDiff\":" << unpackFloat(m_slots[slot].maxDiffBits.load(std::memory_order_relaxed)) << ","
       << "\"lastFrames\":" << m_slots[slot].lastFrames.load(std::memory_order_relaxed) << ","
       << "\"isEditorOpen\":" << ((m_slots[slot].instance && m_slots[slot].instance->isEditorOpen()) ? "true" : "false") << ",";
    const PluginBusInfo bus = m_slots[slot].instance ? m_slots[slot].instance->busInfo()
                                                      : PluginBusInfo{};
    ss << "\"busInfo\":{"
       << "\"inputs\":" << bus.inputBuses << ","
       << "\"outputs\":" << bus.outputBuses << ","
       << "\"auxInputs\":" << bus.auxInputBuses << ","
       << "\"auxOutputs\":" << bus.auxOutputBuses << ","
       << "\"mainInChannels\":" << bus.mainInChannels << ","
       << "\"mainOutChannels\":" << bus.mainOutChannels
       << "},";
#ifndef AURADSP_HOST_INPROC
    if (m_remoteMode) {
        bool remoteFailed = false;
        uint32_t transportLatency = 0;
        uint64_t inputOverflows = 0;
        uint64_t outputOverflows = 0;
        uint64_t seqGaps = 0;
        uint32_t inFlight = 0;
        uint32_t maxInFlight = 0;
        uint32_t depthViolations = 0;
        uint32_t depthDrops = 0;
        if (auto* proxy = dynamic_cast<ProcessPluginProxy*>(m_slots[slot].instance.get())) {
            remoteFailed = proxy->remoteFailed();
            transportLatency = proxy->transportLatency();
            inputOverflows = proxy->inputOverflows();
            outputOverflows = proxy->outputOverflows();
            seqGaps = proxy->seqGaps();
            // E15：流水深不变量观测（inFlight 恒 0/1；maxInFlight 应恒 1；
            // depthViolations 恒 0——非 0 即 latency 上报失真）。
            inFlight = proxy->inFlight();
            maxInFlight = proxy->maxInFlight();
            depthViolations = proxy->depthViolations();
            depthDrops = proxy->depthDrops();
        }
        ss << "\"remoteMode\":true,"
           << "\"remoteFailed\":" << (remoteFailed ? "true" : "false") << ","
           << "\"transportLatency\":" << transportLatency << ","
           << "\"inputOverflows\":" << inputOverflows << ","
           << "\"outputOverflows\":" << outputOverflows << ","
           << "\"seqGaps\":" << seqGaps << ","
           << "\"inFlight\":" << inFlight << ","
           << "\"maxInFlight\":" << maxInFlight << ","
           << "\"depthViolations\":" << depthViolations << ","
           << "\"depthDrops\":" << depthDrops << ",";
    }
#endif
    if (m_slots[slot].instance) {
        const auto& meta = m_slots[slot].instance->getMetadata();
        ss << "\"plugin\":" << meta.toJson();
    } else {
        ss << "\"plugin\":null";
    }
    ss << "}";
    return ss.str();
}

bool PluginHostManager::savePresetSlot(size_t slot, const std::string& filePath) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance && m_slots[slot].hasActive.load()) {
        return m_slots[slot].instance->savePreset(filePath);
    }
    return false;
}

bool PluginHostManager::loadPresetSlot(size_t slot, const std::string& filePath) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].instance && m_slots[slot].hasActive.load()) {
        return m_slots[slot].instance->loadPreset(filePath);
    }
    return false;
}

void PluginHostManager::setInsertStageSlot(size_t slot, int stage) {
    if (slot >= kMaxPluginSlots) return;
    if (stage < 0) stage = 0;
    if (stage > 4) stage = 4;
    m_slots[slot].insertStage.store(stage, std::memory_order_release);
    // F-8a：阶段迁移后首个音频块刷新遥测（新阶段的测量不滞后到下一抽取点）
    resetTelemetryGateSlot(slot);
}

int PluginHostManager::getInsertStageSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return 3;
    return m_slots[slot].insertStage.load(std::memory_order_acquire);
}

void PluginHostManager::setChannelMaskSlot(size_t slot, uint32_t mask) {
    if (slot >= kMaxPluginSlots) return;
    m_slots[slot].channelMask.store(mask & 0xFFu, std::memory_order_release);
}

uint32_t PluginHostManager::getChannelMaskSlot(size_t slot) const {
    if (slot >= kMaxPluginSlots) return 0;
    return m_slots[slot].channelMask.load(std::memory_order_acquire);
}

void PluginHostManager::getMainChannelsSlot(size_t slot, int* inChannels,
                                            int* outChannels) const {
    if (inChannels) *inChannels = 2;
    if (outChannels) *outChannels = 2;
    if (slot >= kMaxPluginSlots) return;
    if (inChannels) *inChannels = m_slots[slot].mainInChannels.load(std::memory_order_relaxed);
    if (outChannels) *outChannels = m_slots[slot].mainOutChannels.load(std::memory_order_relaxed);
}

void PluginHostManager::setChannelHint(int channels) {
    if (channels < 1) channels = 1;
    if (channels > 8) channels = 8;
    const int previous = m_channelHint.exchange(channels, std::memory_order_acq_rel);
    if (previous == channels) return;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
#ifndef AURADSP_HOST_INPROC
    if (m_remoteMode && m_remoteClient) {
        m_remoteClient->setChannelHint(static_cast<uint32_t>(channels));
        return;
    }
#endif
    for (size_t s = 0; s < kMaxPluginSlots; ++s) {
        if (!m_slots[s].instance || !m_slots[s].hasActive.load()) continue;
        m_slots[s].instance->setChannelHint(channels);
        m_slots[s].instance->activate(m_sampleRate, m_maxBlockSize);
        m_slots[s].latency.store(m_slots[s].instance->getLatency(),
                                 std::memory_order_relaxed);
        const PluginBusInfo bus = m_slots[s].instance->busInfo();
        m_slots[s].mainInChannels.store(bus.mainInChannels > 0 ? bus.mainInChannels : 2,
                                        std::memory_order_relaxed);
        m_slots[s].mainOutChannels.store(
            bus.mainOutChannels > 0 ? bus.mainOutChannels
                                    : (bus.mainInChannels > 0 ? bus.mainInChannels : 2),
            std::memory_order_relaxed);
    }
}

int PluginHostManager::getChannelHint() const {
    return m_channelHint.load(std::memory_order_acquire);
}

void PluginHostManager::processSlot(size_t slot, float* const* inChannels, float* const* outChannels, uint32_t numFrames) {
    if (slot >= kMaxPluginSlots) return;
    PluginSlot& s = m_slots[slot];
    /* 先计入 RT 临界区，再读 hasActive。控制线程的卸载顺序是
     * 「hasActive=false → 等 inFlight==0 → 销毁」，两者构成无竞态握手：
     * 若本线程的 fetch_add 晚于控制线程的检查，本线程随后读到的
     * hasActive 必为 false（acq_rel 与 release store 建立了 happens-before），
     * 于是不会触碰已释放的实例。 */
    s.inFlight.fetch_add(1, std::memory_order_acq_rel);
    InFlightGuard guard(s.inFlight, s.destroyPending);

    if (!s.hasActive.load(std::memory_order_acquire) || s.bypassed.load(std::memory_order_acquire)) {
        if (inChannels != outChannels && inChannels && outChannels) {
            for (int ch = 0; ch < 2; ++ch) {
                if (inChannels[ch] && outChannels[ch]) {
                    std::memcpy(outChannels[ch], inChannels[ch], numFrames * sizeof(float));
                }
            }
        }
        return;
    }

    /* SEH/异常段已隔离到 processSlotGuarded（MSVC C2712：无析构函数才能用 __try） */
    s.processCalls.fetch_add(1, std::memory_order_relaxed);
    if (processSlotGuarded(s, inChannels, outChannels, numFrames) != 0) {
        s.bypassed.store(true, std::memory_order_release);
    }
}

void PluginHostManager::processSlotInterleaved(size_t slot, float* interleaved,
                                                uint32_t numFrames, uint32_t channels,
                                                uint32_t mask) {
    if (slot >= kMaxPluginSlots || !interleaved || numFrames == 0 || channels == 0) return;
    if (channels > 8) channels = 8;
    mask &= (1u << channels) - 1u;
    if (mask == 0) return;
    if (numFrames > m_channelScratchBlock || !m_channelIn[0] ||
        !m_channelOut[0] || !m_channelZero) {
        return;
    }

    PluginSlot& s = m_slots[slot];
    if (!s.hasActive.load(std::memory_order_acquire) ||
        s.bypassed.load(std::memory_order_acquire)) {
        return;
    }

    /* F-8a：遥测测量按块抽取。音频路径（解交织/插件 process/分组 scatter）
     * 完全不受影响；未命中抽取点时跳过 RMS/diff 累加，sampleCount 保持 0，
     * 末尾既有 `if (sampleCount > 0)` 守卫自然不会触发 recordTelemetry。 */
    const bool sampleTelemetry = claimTelemetrySample(slot);

    for (uint32_t i = 0; i < numFrames; ++i) {
        for (uint32_t ch = 0; ch < channels; ++ch) {
            m_channelIn[ch][i] = interleaved[i * channels + ch];
        }
    }

    double inSum = 0.0;
    double outSum = 0.0;
    float maxDiff = 0.0f;
    uint32_t sampleCount = 0;

    auto accumulate = [&](const float* in, const float* out) {
        if (!sampleTelemetry) return;
        for (uint32_t i = 0; i < numFrames; ++i) {
            const float a = in[i];
            const float b = out[i];
            inSum += static_cast<double>(a) * a;
            outSum += static_cast<double>(b) * b;
            const float diff = std::fabs(b - a);
            if (diff > maxDiff) maxDiff = diff;
        }
        sampleCount += numFrames;
    };

    if (s.instance && s.instance->interleavedTransport()) {
        s.inFlight.fetch_add(1, std::memory_order_acq_rel);
        InFlightGuard guard(s.inFlight, s.destroyPending);
        /* E13: 交错传输路径（remote 代理分支）此前从不递增 processCalls——
         * 该计数只存在于平面 processSlot，进程内链组件经 else 分支的交错→
         * 平面转换间接计数，remote 路径则全程为 0（遥测盲区，R-1 遗留①）。
         * 仅在此分支递增：else 分支由其内部 processSlot 计数，避免双计。 */
        s.processCalls.fetch_add(1, std::memory_order_relaxed);
        if (s.hasActive.load(std::memory_order_acquire) &&
            !s.bypassed.load(std::memory_order_acquire)) {
            s.instance->processInterleaved(interleaved, numFrames, channels, mask);
        }
        if (sampleTelemetry) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                if (!(mask & (1u << ch))) continue;
                for (uint32_t i = 0; i < numFrames; ++i) {
                    const float a = m_channelIn[ch][i];
                    const float b = interleaved[i * channels + ch];
                    inSum += static_cast<double>(a) * a;
                    outSum += static_cast<double>(b) * b;
                    const float diff = std::fabs(b - a);
                    if (diff > maxDiff) maxDiff = diff;
                }
                sampleCount += numFrames;
            }
        }
    } else {
        int inChannels = 2;
        int outChannels = 2;
        getMainChannelsSlot(slot, &inChannels, &outChannels);
        if (inChannels <= 0) inChannels = 2;
        if (outChannels <= 0) outChannels = inChannels;
        if (inChannels > 8) inChannels = 8;
        if (outChannels > 8) outChannels = 8;

        auto fillOutput = [&](int count, const float* first) {
            for (int ch = 0; ch < count; ++ch) {
                if (ch < 2 && first && ch == 0) {
                    std::memcpy(m_channelOut[ch].get(), first,
                                static_cast<size_t>(numFrames) * sizeof(float));
                } else if (first) {
                    std::memcpy(m_channelOut[ch].get(), first,
                                static_cast<size_t>(numFrames) * sizeof(float));
                } else {
                    std::memset(m_channelOut[ch].get(), 0,
                                static_cast<size_t>(numFrames) * sizeof(float));
                }
            }
        };

        if (inChannels == 1) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                if (!(mask & (1u << ch))) continue;
                fillOutput(outChannels, m_channelIn[ch].get());
                float* inPtrs[1] = {m_channelIn[ch].get()};
                float* outPtrs[8] = {};
                for (int oc = 0; oc < outChannels; ++oc) outPtrs[oc] = m_channelOut[oc].get();
                processSlot(slot, inPtrs, outPtrs, numFrames);
                for (uint32_t i = 0; i < numFrames; ++i) {
                    interleaved[i * channels + ch] = m_channelOut[0][i];
                }
                accumulate(m_channelIn[ch].get(), m_channelOut[0].get());
            }
        } else if (inChannels == 2) {
            for (uint32_t base = 0; base + 1 < channels; base += 2) {
                const uint32_t group = mask & (3u << base);
                if (group == 0) continue;
                const uint32_t srcL = (group & 1u) ? base : base + 1;
                const uint32_t srcR = (group & 2u) ? base + 1 : srcL;
                std::memcpy(m_channelOut[0].get(), m_channelIn[srcL].get(),
                            static_cast<size_t>(numFrames) * sizeof(float));
                std::memcpy(m_channelOut[1].get(), m_channelIn[srcR].get(),
                            static_cast<size_t>(numFrames) * sizeof(float));
                for (int oc = 2; oc < outChannels; ++oc) {
                    std::memcpy(m_channelOut[oc].get(), m_channelIn[srcL].get(),
                                static_cast<size_t>(numFrames) * sizeof(float));
                }
                float* inPtrs[2] = {m_channelIn[srcL].get(), m_channelIn[srcR].get()};
                float* outPtrs[8] = {};
                for (int oc = 0; oc < outChannels; ++oc) outPtrs[oc] = m_channelOut[oc].get();
                processSlot(slot, inPtrs, outPtrs, numFrames);
                for (uint32_t i = 0; i < numFrames; ++i) {
                    if (group & 1u) interleaved[i * channels + base] = m_channelOut[0][i];
                    if (group & 2u) interleaved[i * channels + base + 1] = m_channelOut[1][i];
                }
                accumulate(m_channelIn[srcL].get(), m_channelOut[0].get());
                accumulate(m_channelIn[srcR].get(), m_channelOut[1].get());
            }
        } else {
            int selected[8] = {};
            int selectedCount = 0;
            for (uint32_t ch = 0; ch < channels && selectedCount < 8; ++ch) {
                if (mask & (1u << ch)) selected[selectedCount++] = static_cast<int>(ch);
            }
            for (int start = 0; start < selectedCount; start += inChannels) {
                const int groupCount =
                    (std::min)(inChannels, selectedCount - start);
                float* inPtrs[8] = {};
                float* outPtrs[8] = {};
                for (int j = 0; j < inChannels; ++j) {
                    inPtrs[j] = (j < groupCount)
                                    ? m_channelIn[selected[start + j]].get()
                                    : m_channelZero.get();
                }
                for (int j = 0; j < outChannels; ++j) {
                    outPtrs[j] = m_channelOut[j].get();
                    if (j < groupCount) {
                        std::memcpy(m_channelOut[j].get(), inPtrs[j],
                                    static_cast<size_t>(numFrames) * sizeof(float));
                    } else {
                        std::memset(m_channelOut[j].get(), 0,
                                    static_cast<size_t>(numFrames) * sizeof(float));
                    }
                }
                processSlot(slot, inPtrs, outPtrs, numFrames);
                for (int j = 0; j < groupCount; ++j) {
                    const int oc = (std::min)(j, outChannels - 1);
                    for (uint32_t i = 0; i < numFrames; ++i) {
                        interleaved[i * channels + selected[start + j]] =
                            m_channelOut[oc][i];
                    }
                    accumulate(inPtrs[j], m_channelOut[oc].get());
                }
            }
        }
    }

    if (sampleCount > 0) {
        const double denom = static_cast<double>(sampleCount);
        recordTelemetry(slot,
                        static_cast<float>(std::sqrt(inSum / denom)),
                        static_cast<float>(std::sqrt(outSum / denom)),
                        maxDiff,
                        numFrames);
    }
}

void PluginHostManager::recordTelemetry(size_t slot, float inRms, float outRms,
                                        float maxDiff, uint32_t frames) {
    if (slot >= kMaxPluginSlots) return;
    PluginSlot& s = m_slots[slot];
    s.inRmsBits.store(packFloat(inRms), std::memory_order_relaxed);
    s.outRmsBits.store(packFloat(outRms), std::memory_order_relaxed);
    s.maxDiffBits.store(packFloat(maxDiff), std::memory_order_relaxed);
    s.lastFrames.store(frames, std::memory_order_relaxed);
}

bool PluginHostManager::claimTelemetrySample(size_t slot) noexcept {
    if (slot >= kMaxPluginSlots) return false;
    PluginSlot& s = m_slots[slot];
    const uint32_t cur = s.telemetryCountdown.load(std::memory_order_relaxed);
    if (cur == 0) {
        s.telemetryCountdown.store(kTelemetryDecimation - 1, std::memory_order_relaxed);
        return true;
    }
    s.telemetryCountdown.store(cur - 1, std::memory_order_relaxed);
    return false;
}

void PluginHostManager::resetTelemetryGateSlot(size_t slot) noexcept {
    if (slot >= kMaxPluginSlots) return;
    m_slots[slot].telemetryCountdown.store(0, std::memory_order_relaxed);
}

// Legacy single-slot forward (slot 0).
// Only loadPlugin survives: it is the one still referenced by
// engine/plugins/tests/plugin_host_direct.cpp. The other six (unloadPlugin, setBypass,
// isBypassed, getLatency, hasActivePlugin, getStatusJson, process) had no
// callers anywhere in the repo -- the C ABI's own single-slot compatibility
// symbols forward straight to the *Slot functions and never used them.
bool PluginHostManager::loadPlugin(const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize) {
    return loadPluginSlot(0, path, pluginId, sampleRate, maxBlockSize);
}

bool PluginHostManager::ensureChannelScratch(uint32_t maxBlockSize) {
    if (maxBlockSize == 0) return false;
    if (m_channelScratchBlock >= maxBlockSize &&
        m_channelIn[0] && m_channelOut[0] && m_channelZero) {
        return true;
    }
    for (size_t ch = 0; ch < m_channelIn.size(); ++ch) {
        m_channelIn[ch].reset(new (std::nothrow) float[maxBlockSize]());
        m_channelOut[ch].reset(new (std::nothrow) float[maxBlockSize]());
        if (!m_channelIn[ch] || !m_channelOut[ch]) return false;
    }
    m_channelZero.reset(new (std::nothrow) float[maxBlockSize]());
    if (!m_channelZero) return false;
    m_channelScratchBlock = maxBlockSize;
    return true;
}

void PluginHostManager::updateFormat(double sampleRate, uint32_t maxBlockSize) {
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    m_sampleRate = sampleRate;
    m_maxBlockSize = maxBlockSize;
    ensureChannelScratch(maxBlockSize);
#ifndef AURADSP_HOST_INPROC
    if (m_remoteMode && m_remoteClient) {
        if (m_remoteClient->alive()) {
            m_remoteClient->updateFormat(sampleRate, maxBlockSize);
            m_remoteClient->setChannelHint(static_cast<uint32_t>(m_channelHint.load()));
            for (size_t s = 0; s < kMaxPluginSlots; ++s) {
                if (m_slots[s].instance && m_slots[s].hasActive.load()) {
                    m_slots[s].latency.store(m_slots[s].instance->getLatency(),
                                             std::memory_order_relaxed);
                }
            }
        }
        return;
    }
#endif
    for (size_t s = 0; s < kMaxPluginSlots; ++s) {
        if (m_slots[s].instance && m_slots[s].hasActive.load()) {
            m_slots[s].instance->setChannelHint(m_channelHint.load());
            m_slots[s].instance->activate(sampleRate, maxBlockSize);
            m_slots[s].latency.store(m_slots[s].instance->getLatency(), std::memory_order_relaxed);
            const PluginBusInfo bus = m_slots[s].instance->busInfo();
            m_slots[s].mainInChannels.store(bus.mainInChannels > 0 ? bus.mainInChannels : 2,
                                            std::memory_order_relaxed);
            m_slots[s].mainOutChannels.store(
                bus.mainOutChannels > 0 ? bus.mainOutChannels
                                        : (bus.mainInChannels > 0 ? bus.mainInChannels : 2),
                std::memory_order_relaxed);
        }
    }
}

//------------------------------------------------------------------------------

// C3 两段式拆分：prepare（重活，锁外） / commit（微秒级，锁内）

std::unique_ptr<IPluginInstance> PluginHostManager::prepareInstance(size_t slot, const std::string& path, const std::string& pluginId) {
#ifndef AURADSP_HOST_INPROC
    if (m_remoteMode && m_remoteClient) {
        if (slot >= kMaxPluginSlots) return nullptr;
        std::unique_ptr<IPluginInstance> oldInstance;
        {
            std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
            oldInstance = detachInstanceLocked(slot);
        }
        if (oldInstance) destroyInstance(std::move(oldInstance));

        auto instance = std::make_unique<ProcessPluginProxy>(
            m_remoteClient, slot, m_sampleRate, m_maxBlockSize);
        if (!instance->load(path, pluginId)) return nullptr;
        return instance;
    }
#else
    (void)slot;
#endif

    auto* driver = PluginDriverRegistry::instance().findForPath(path);
    if (!driver) return nullptr;
    if (driver->resolveBinary(path).empty()) return nullptr;

    auto instance = driver->createInstance();
    if (!instance) return nullptr;

    // 查找扫描期种子（匹配 path + pluginId）——值拷贝到局部变量，避免持有裸指针跨越锁外耗时 I/O 导致 UAF
    PluginMetadata seedCopy;
    bool hasSeed = false;
    {
        std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
        for (const auto& p : m_scannedPlugins) {
            if (p.path != path) continue;
            if (!pluginId.empty() && !p.id.empty() && p.id != pluginId) continue;
            seedCopy = p;
            hasSeed = true;
            break;
        }
    }

    bool lRet = instance->load(path, pluginId, hasSeed ? &seedCopy : nullptr);
    if (!lRet) {
        if (instance->abandoned()) {
            quarantineAbandonedInstance(std::move(instance));
        }
        return nullptr;
    }

    bool aRet = instance->activate(m_sampleRate, m_maxBlockSize);
    if (!aRet) {
        instance->unload();
        if (instance->abandoned()) {
            quarantineAbandonedInstance(std::move(instance));
        }
        return nullptr;
    }

    return instance;
}

void PluginHostManager::commitInstanceLocked(size_t slot, std::unique_ptr<IPluginInstance> instance) {
    // 注意：调用方已持有 m_hostMutex
    if (slot >= kMaxPluginSlots || !instance) return;
    PluginSlot& s = m_slots[slot];
    // 挂入新实例（若槽上有未事先摘除的旧实例，做防御性替换）
    auto old = std::move(s.instance);
    s.instance = std::move(instance);
    s.latency.store(s.instance->getLatency(), std::memory_order_relaxed);
    const PluginBusInfo bus = s.instance->busInfo();
    s.mainInChannels.store(bus.mainInChannels > 0 ? bus.mainInChannels : 2,
                           std::memory_order_relaxed);
    s.mainOutChannels.store(bus.mainOutChannels > 0 ? bus.mainOutChannels
                                                    : (bus.mainInChannels > 0 ? bus.mainInChannels : 2),
                            std::memory_order_relaxed);
    s.hasActive.store(true, std::memory_order_release);
    s.bypassed.store(false, std::memory_order_release);
    s.processCalls.store(0, std::memory_order_relaxed);
    s.inRmsBits.store(0, std::memory_order_relaxed);
    s.outRmsBits.store(0, std::memory_order_relaxed);
    s.maxDiffBits.store(0, std::memory_order_relaxed);
    s.lastFrames.store(0, std::memory_order_relaxed);
    resetTelemetryGateSlot(slot);

    if (old) {
        // 正常流程由 runControlTask 预先调用 detachInstanceLocked 摘除并在锁外销毁；
        // 若直接调用本函数导致有残留旧实例，放入隔离区防止锁内耗时阻塞与 RT 冲突
        quarantineAbandonedInstance(std::move(old));
    }
}

//------------------------------------------------------------------------------

// C3 两段式拆分：detach（摘出+等RT退出，锁内） / destroy（重活，锁外）

std::unique_ptr<IPluginInstance> PluginHostManager::detachInstanceLocked(size_t slot) {
    // 注意：调用方已持有 m_hostMutex
    if (slot >= kMaxPluginSlots) return nullptr;
    PluginSlot& s = m_slots[slot];
    s.hasActive.store(false, std::memory_order_release);
    s.destroyPending.store(true, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_acquire);

    uint32_t spins = 0;
    while (s.inFlight.load(std::memory_order_relaxed) != 0 && spins < kQuiesceSpinLimit) {
        s.inFlight.wait(0, std::memory_order_relaxed);
        ++spins;
    }
    s.destroyPending.store(false, std::memory_order_relaxed);
    s.inFlight.store(0, std::memory_order_relaxed);
    s.latency.store(0, std::memory_order_relaxed);

    auto instance = std::move(s.instance);
    return instance;  // 调用方在锁外销毁
}

void PluginHostManager::destroyInstance(std::unique_ptr<IPluginInstance> instance) {
    if (!instance) return;
    instance->closeEditor();
    instance->deactivate();
    instance->unload();
    if (instance->abandoned()) {
        quarantineAbandonedInstance(std::move(instance));
    }
    // 否则 unique_ptr 析构
}

//------------------------------------------------------------------------------

// C3 控制线程：异步执行 load/unload 任务

bool PluginHostManager::submitTaskLocked(ControlTask task) {
    // 注意：调用方已持有 m_hostMutex
    // 设置任务状态为进行中
    m_slots[task.slot].taskState.store(1, std::memory_order_release);
    // 入队
    {
        std::lock_guard<std::mutex> ql(m_controlMutex);
        m_controlQueue.push_back(std::move(task));
    }
    m_controlCv.notify_one();
    return true;
}

void PluginHostManager::ensureControlThreadLocked() {
    if (m_controlRunning.load(std::memory_order_relaxed)) return;
    m_controlRunning.store(true, std::memory_order_release);
    m_controlThread = std::thread([this]() { controlLoop(); });
}

void PluginHostManager::controlLoop() {
    while (true) {
        ControlTask task;
        {
            std::unique_lock<std::mutex> lk(m_controlMutex);
            m_controlCv.wait(lk, [this]() { return !m_controlQueue.empty() || !m_controlRunning.load(); });
            if (!m_controlRunning.load() && m_controlQueue.empty()) break;
            task = std::move(m_controlQueue.front());
            m_controlQueue.pop_front();
        }
        runControlTask(task);
    }
}

void PluginHostManager::runControlTask(const ControlTask& t) {
    if (t.slot >= kMaxPluginSlots) return;

    try {
        if (t.isLoad) {
#ifndef AURADSP_HOST_INPROC
            if (m_remoteMode) {
                std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
                m_sampleRate = t.sampleRate;
                m_maxBlockSize = t.maxBlockSize;
            }
#endif
            // prepare 在锁外执行（重活）
            auto instance = prepareInstance(t.slot, t.path, t.pluginId);
            std::unique_ptr<IPluginInstance> oldInstance;
            // commit 在锁内执行（微秒级）
            {
                std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
                m_sampleRate = t.sampleRate;
                m_maxBlockSize = t.maxBlockSize;
                if (instance) {
                    // 若槽上已有旧实例，先安全摘出（静默等待 RT 线程退出临界区）
                    oldInstance = detachInstanceLocked(t.slot);
                    commitInstanceLocked(t.slot, std::move(instance));
                    m_slots[t.slot].taskState.store(2, std::memory_order_release); // 成功
                } else {
                    m_slots[t.slot].taskState.store(3, std::memory_order_release); // 失败
                }
            }
            if (oldInstance) {
                destroyInstance(std::move(oldInstance)); // 旧实例在锁外销毁
            }
        } else {
            // unload：detach 在锁内（短），destroy 在锁外（重活）
            std::unique_ptr<IPluginInstance> instance;
            {
                std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
                instance = detachInstanceLocked(t.slot);
                m_slots[t.slot].taskState.store(2, std::memory_order_release); // 卸载总是"成功"
            }
            destroyInstance(std::move(instance)); // 锁外销毁
        }
    } catch (...) {
        // 防止异常抛出导致控制线程 std::terminate 终止并永久死锁
        m_slots[t.slot].taskState.store(3, std::memory_order_release);
    }
}

//------------------------------------------------------------------------------

// C3 公开 API

bool PluginHostManager::submitSlotLoadAsync(size_t slot, const std::string& path, const std::string& pluginId,
                                             double sampleRate, uint32_t maxBlockSize) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    // 如果该槽已有进行中的任务，拒绝（调用方应先轮询确认空闲）
    if (m_slots[slot].taskState.load(std::memory_order_acquire) == 1) return false;
    ensureControlThreadLocked();
    ControlTask task;
    task.slot = slot;
    task.isLoad = true;
    task.path = path;
    task.pluginId = pluginId;
    task.sampleRate = sampleRate;
    task.maxBlockSize = maxBlockSize;
    return submitTaskLocked(std::move(task));
}

bool PluginHostManager::submitSlotUnloadAsync(size_t slot) {
    if (slot >= kMaxPluginSlots) return false;
    std::lock_guard<std::recursive_mutex> lock(m_hostMutex);
    if (m_slots[slot].taskState.load(std::memory_order_acquire) == 1) return false;
    ensureControlThreadLocked();
    ControlTask task;
    task.slot = slot;
    task.isLoad = false;
    return submitTaskLocked(std::move(task));
}

int PluginHostManager::slotTaskState(size_t slot) const {
    if (slot >= kMaxPluginSlots) return 0;
    return m_slots[slot].taskState.load(std::memory_order_acquire);
}

bool PluginHostManager::slotTaskPending(size_t slot) const {
    if (slot >= kMaxPluginSlots) return false;
    return m_slots[slot].taskState.load(std::memory_order_acquire) == 1;
}
} // namespace auradsp
