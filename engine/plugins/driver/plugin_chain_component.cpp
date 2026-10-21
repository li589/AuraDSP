#include "plugins/driver/plugin_chain_component.h"

#include <new>

namespace auradsp {

PluginChainComponent::PluginChainComponent() = default;
PluginChainComponent::~PluginChainComponent() = default;

bool PluginChainComponent::prepare(double sampleRate, uint32_t maxBlockSize) {
    if (maxBlockSize == 0) return false;

    if (!m_host) {
        m_host.reset(new (std::nothrow) PluginHostManager());
        if (!m_host) return false;
    }
    m_host->updateFormat(sampleRate, maxBlockSize);

    /* E16：平面专用工作缓冲（m_chanIn/m_chanOut/m_work 系列共 8 块）随平面
     * process() 一并删除——交错路径全部原地工作，无额外缓冲需求。 */
    if (m_maxBlock == maxBlockSize) return true;
    m_maxBlock = maxBlockSize;

    for (size_t s = 0; s < m_delayLines.size(); ++s) {
        m_delayLines[s].prepare(DelayLine::kMaxDelay);
        m_multiDelayLines[s].prepare(MultiDelayLine::kMaxDelay);
    }
    return true;
}

void PluginChainComponent::reset() {
    if (!m_host) return;
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        m_host->unloadPluginSlot(slot);
        m_delayLines[slot].reset();
        m_multiDelayLines[slot].reset();
        m_lastMasks[slot] = 0;
    }
}

/* E16：平面 4 参 process() 已删除（Phase 3 重构前遗留死路径，全库无生产
 * 调用方；其立体声硬边界是 F-8b 记录的误路由隐患）。链路统一入口为
 * processInterleavedN()，见头文件注释。 */

void PluginChainComponent::processInterleaved(int stage, float* interleaved,
                                               uint32_t frames) noexcept {
    processInterleavedN(stage, interleaved, frames, 2);
}

void PluginChainComponent::processInterleavedN(int stage, float* interleaved,
                                                uint32_t frames,
                                                uint32_t channels) noexcept {
    if (!m_host || !interleaved || frames == 0 || frames > m_maxBlock ||
        channels == 0) {
        return;
    }
    if (channels > 8) channels = 8;
    if (!stageHasActiveOrPdc(stage)) return;

    const bool pdc = m_pdcEnabled.load(std::memory_order_acquire);
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (!m_host->hasActivePluginSlot(slot) ||
            m_host->getInsertStageSlot(slot) != stage) {
            continue;
        }
        uint32_t mask = m_host->getChannelMaskSlot(slot) & ((1u << channels) - 1u);
        if (mask == 0) continue;
        if (mask != m_lastMasks[slot]) {
            m_multiDelayLines[slot].reset();
            m_lastMasks[slot] = mask;
        }

        const bool bypassed = m_host->isBypassedSlot(slot);
        if (pdc) {
            m_multiDelayLines[slot].setDelay(m_host->getLatencySlot(slot));
            if (bypassed) {
                m_multiDelayLines[slot].process(interleaved, frames, channels, mask);
            } else {
                m_multiDelayLines[slot].pushOnly(interleaved, frames, channels, mask);
            }
        }
        if (bypassed) continue;

        m_host->processSlotInterleaved(slot, interleaved, frames, channels, mask);
    }
}

void PluginChainComponent::setChannelHint(int channels) noexcept {
    if (!m_host) return;
    m_host->setChannelHint(channels);
}

void PluginChainComponent::setBypass(int slot, bool bypassValue) noexcept {
    if (!m_host || slot < 0 ||
        slot >= static_cast<int>(PluginHostManager::kMaxPluginSlots)) {
        return;
    }
    m_host->setBypassSlot(static_cast<size_t>(slot), bypassValue);
}

bool PluginChainComponent::bypass(int slot) const noexcept {
    if (!m_host || slot < 0 ||
        slot >= static_cast<int>(PluginHostManager::kMaxPluginSlots)) {
        return true;
    }
    return m_host->isBypassedSlot(static_cast<size_t>(slot));
}

uint32_t PluginChainComponent::latency(int slot) const noexcept {
    if (!m_host || slot < 0 ||
        slot >= static_cast<int>(PluginHostManager::kMaxPluginSlots)) {
        return 0;
    }
    return m_host->getLatencySlot(static_cast<size_t>(slot));
}

uint32_t PluginChainComponent::stageLatency(int stage) const noexcept {
    if (!m_host) return 0;
    const bool pdc = m_pdcEnabled.load(std::memory_order_acquire);
    uint32_t total = 0;
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (m_host->hasActivePluginSlot(slot) &&
            m_host->getChannelMaskSlot(slot) != 0 &&
            m_host->getInsertStageSlot(slot) == stage &&
            (pdc || !m_host->isBypassedSlot(slot))) {
            total += m_host->getLatencySlot(slot);
        }
    }
    return total;
}

uint32_t PluginChainComponent::totalLatency() const noexcept {
    if (!m_host) return 0;
    const bool pdc = m_pdcEnabled.load(std::memory_order_acquire);
    uint32_t total = 0;
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (m_host->hasActivePluginSlot(slot) &&
            m_host->getChannelMaskSlot(slot) != 0 &&
            (pdc || !m_host->isBypassedSlot(slot))) {
            total += m_host->getLatencySlot(slot);
        }
    }
    return total;
}

bool PluginChainComponent::hasActive(int slot) const noexcept {
    if (!m_host || slot < 0 ||
        slot >= static_cast<int>(PluginHostManager::kMaxPluginSlots)) {
        return false;
    }
    return m_host->hasActivePluginSlot(static_cast<size_t>(slot));
}

bool PluginChainComponent::stageHasActive(int stage) const noexcept {
    if (!m_host) return false;
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (m_host->hasActivePluginSlot(slot) &&
            m_host->getChannelMaskSlot(slot) != 0 &&
            !m_host->isBypassedSlot(slot) &&
            m_host->getInsertStageSlot(slot) == stage) {
            return true;
        }
    }
    return false;
}

bool PluginChainComponent::stageHasActiveOrPdc(int stage) const noexcept {
    if (!m_host) return false;
    const bool pdc = m_pdcEnabled.load(std::memory_order_acquire);
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (m_host->hasActivePluginSlot(slot) &&
            m_host->getInsertStageSlot(slot) == stage &&
            (pdc || !m_host->isBypassedSlot(slot))) {
            return true;
        }
    }
    return false;
}

} // namespace auradsp
