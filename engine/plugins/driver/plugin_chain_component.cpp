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
    return true;
}

void PluginChainComponent::reset() {
    if (!m_host) return;
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        m_host->unloadPluginSlot(slot);
    }
}

void PluginChainComponent::process(int stage, float* const* in,
                                   float* const* out,
                                   uint32_t frames) noexcept {
    if (!m_host || !in || !out || !in[0] || !in[1] || !out[0] || !out[1] ||
        frames == 0 || frames > m_maxBlock) {
        return;
    }

    if (!stageHasActive(stage)) {
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
            m_host->isBypassedSlot(slot) ||
            m_host->getInsertStageSlot(slot) != stage) {
            continue;
        }

        float* src[2] = {srcL, srcR};
        float* dst[2] = {dstL, dstR};
        copyPlanar(dst, src, frames);

        const double inSum = planarRmsSum(srcL, srcR, frames);
        m_host->processSlot(slot, src, dst, frames);

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

        const double denom = frames > 0 ? static_cast<double>(frames) * 2.0 : 1.0;
        m_host->recordTelemetry(
            slot,
            static_cast<float>(std::sqrt(inSum / denom)),
            static_cast<float>(std::sqrt(outSum / denom)),
            maxDiff,
            frames);

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
    if (!m_host || !interleaved || frames == 0 || frames > m_maxBlock) return;
    if (!stageHasActive(stage)) return;

    for (uint32_t i = 0; i < frames; ++i) {
        m_chanInL[i] = interleaved[i * 2];
        m_chanInR[i] = interleaved[i * 2 + 1];
    }

    float* in[2] = {m_chanInL.get(), m_chanInR.get()};
    float* out[2] = {m_chanOutL.get(), m_chanOutR.get()};
    process(stage, in, out, frames);

    for (uint32_t i = 0; i < frames; ++i) {
        interleaved[i * 2] = m_chanOutL[i];
        interleaved[i * 2 + 1] = m_chanOutR[i];
    }
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
    uint32_t total = 0;
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (m_host->hasActivePluginSlot(slot) &&
            !m_host->isBypassedSlot(slot) &&
            m_host->getInsertStageSlot(slot) == stage) {
            total += m_host->getLatencySlot(slot);
        }
    }
    return total;
}

uint32_t PluginChainComponent::totalLatency() const noexcept {
    if (!m_host) return 0;
    uint32_t total = 0;
    for (size_t slot = 0; slot < PluginHostManager::kMaxPluginSlots; ++slot) {
        if (m_host->hasActivePluginSlot(slot) &&
            !m_host->isBypassedSlot(slot)) {
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
            !m_host->isBypassedSlot(slot) &&
            m_host->getInsertStageSlot(slot) == stage) {
            return true;
        }
    }
    return false;
}

} // namespace auradsp
