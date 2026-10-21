#include "plugins/driver/plugin_chain_component.h"

#include <cmath>
#include <cstring>
#include <new>

namespace auradsp {
namespace {

bool allocFloats(std::unique_ptr<float[]>& out, uint32_t count) {
    out.reset(new (std::nothrow) float[count]());
    return static_cast<bool>(out);
}

void copyPlanar(float* const* dst, float* const* src, uint32_t frames) {
    if (frames == 0) return;
    if (dst[0] != src[0]) {
        std::memcpy(dst[0], src[0], static_cast<size_t>(frames) * sizeof(float));
    }
    if (dst[1] != src[1]) {
        std::memcpy(dst[1], src[1], static_cast<size_t>(frames) * sizeof(float));
    }
}

double planarRmsSum(const float* left, const float* right, uint32_t frames) {
    double sum = 0.0;
    for (uint32_t i = 0; i < frames; ++i) {
        const double l = left[i];
        const double r = right[i];
        sum += l * l + r * r;
    }
    return sum;
}

} // namespace

PluginChainComponent::PluginChainComponent() = default;
PluginChainComponent::~PluginChainComponent() = default;

bool PluginChainComponent::prepare(double sampleRate, uint32_t maxBlockSize) {
    if (maxBlockSize == 0) return false;

    if (!m_host) {
        m_host.reset(new (std::nothrow) PluginHostManager());
        if (!m_host) return false;
    }
    m_host->updateFormat(sampleRate, maxBlockSize);

    if (m_maxBlock == maxBlockSize && m_chanInL && m_chanInR &&
        m_chanOutL && m_chanOutR && m_workAL && m_workAR &&
        m_workBL && m_workBR) {
        return true;
    }

    std::unique_ptr<float[]> chanInL;
    std::unique_ptr<float[]> chanInR;
    std::unique_ptr<float[]> chanOutL;
    std::unique_ptr<float[]> chanOutR;
    std::unique_ptr<float[]> workAL;
    std::unique_ptr<float[]> workAR;
    std::unique_ptr<float[]> workBL;
    std::unique_ptr<float[]> workBR;

    if (!allocFloats(chanInL, maxBlockSize) ||
        !allocFloats(chanInR, maxBlockSize) ||
        !allocFloats(chanOutL, maxBlockSize) ||
        !allocFloats(chanOutR, maxBlockSize) ||
        !allocFloats(workAL, maxBlockSize) ||
        !allocFloats(workAR, maxBlockSize) ||
        !allocFloats(workBL, maxBlockSize) ||
        !allocFloats(workBR, maxBlockSize)) {
        return false;
    }

    m_chanInL = std::move(chanInL);
    m_chanInR = std::move(chanInR);
    m_chanOutL = std::move(chanOutL);
    m_chanOutR = std::move(chanOutR);
    m_workAL = std::move(workAL);
    m_workAR = std::move(workAR);
    m_workBL = std::move(workBL);
    m_workBR = std::move(workBR);
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

void PluginChainComponent::process(int stage, float* const* in,
                                   float* const* out,
                                   uint32_t frames) noexcept {
    /* F-8b 契约执行点（契约全文见头文件）：立体声平面专用——in/out 必须
     * 至少提供 2 个非空通道指针。任一为空或帧数越界时静默早退、不写 out、
     * 不记日志（音频 RT 路径禁系统调用，debug_log.h 铁律）；调用方违反
     * 契约的后果是输出保持原值（非静音零值），便于上层比对发现。 */
    if (!m_host || !in || !out || !in[0] || !in[1] || !out[0] || !out[1] ||
        frames == 0 || frames > m_maxBlock) {
        return;
    }

    const bool pdc = m_pdcEnabled.load(std::memory_order_acquire);
    if (!stageHasActiveOrPdc(stage)) {
        copyPlanar(out, in, frames);
        return;
    }

    float* srcL = in[0];
    float* srcR = in[1];
    float* dstL = m_workAL.get();
    float* dstR = m_workAR.get();
    bool dstIsA = true;

    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (!m_host->hasActivePluginSlot(slot) ||
            m_host->getInsertStageSlot(slot) != stage) {
            continue;
        }

        const bool bypassed = m_host->isBypassedSlot(slot);

        if (pdc && bypassed) {
            m_delayLines[slot].setDelay(m_host->getLatencySlot(slot));
            float* src[2] = {srcL, srcR};
            float* dst[2] = {dstL, dstR};
            m_delayLines[slot].process(src, dst, frames);
        } else {
            if (pdc) {
                float* src[2] = {srcL, srcR};
                m_delayLines[slot].pushOnly(src, frames);
            }
            if (bypassed) continue;

            float* src[2] = {srcL, srcR};
            float* dst[2] = {dstL, dstR};
            copyPlanar(dst, src, frames);

            /* F-8a：遥测测量按块抽取（kTelemetryDecimation，门控实现在
             * PluginHostManager::claimTelemetrySample）。插件音频处理不受
             * 影响；未命中抽取点时跳过 RMS/diff 双循环。 */
            const bool sampleTelemetry = m_host->claimTelemetrySample(slot);
            const double inSum =
                sampleTelemetry ? planarRmsSum(srcL, srcR, frames) : 0.0;
            m_host->processSlot(slot, src, dst, frames);

            if (sampleTelemetry) {
                double outSum = 0.0;
                float maxDiff = 0.0f;
                for (uint32_t i = 0; i < frames; ++i) {
                    const float outL = dstL[i];
                    const float outR = dstR[i];
                    const double ol = outL;
                    const double orr = outR;
                    outSum += ol * ol + orr * orr;
                    const float dl = std::fabs(outL - srcL[i]);
                    const float dr = std::fabs(outR - srcR[i]);
                    if (dl > maxDiff) maxDiff = dl;
                    if (dr > maxDiff) maxDiff = dr;
                }

                const double denom =
                    frames > 0 ? static_cast<double>(frames) * 2.0 : 1.0;
                m_host->recordTelemetry(
                    slot,
                    static_cast<float>(std::sqrt(inSum / denom)),
                    static_cast<float>(std::sqrt(outSum / denom)),
                    maxDiff,
                    frames);
            }
        }

        srcL = dstL;
        srcR = dstR;
        if (dstIsA) {
            dstL = m_workBL.get();
            dstR = m_workBR.get();
        } else {
            dstL = m_workAL.get();
            dstR = m_workAR.get();
        }
        dstIsA = !dstIsA;
    }

    float* finalSrc[2] = {srcL, srcR};
    copyPlanar(out, finalSrc, frames);
}

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
