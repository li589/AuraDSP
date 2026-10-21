#pragma once

#include <cstdint>
#include <cstring>
#include <array>
#include <memory>

namespace auradsp {

class DelayLine {
public:
    static constexpr uint32_t kMaxDelay = 65536;

    bool prepare(uint32_t maxDelay) {
        if (maxDelay == 0) maxDelay = 1;
        if (maxDelay > kMaxDelay) maxDelay = kMaxDelay;
        const uint32_t size = maxDelay + 1;
        m_bufL.reset(new (std::nothrow) float[size]());
        m_bufR.reset(new (std::nothrow) float[size]());
        if (!m_bufL || !m_bufR) return false;
        m_size = size;
        m_writePos = 0;
        m_delay = 0;
        return true;
    }

    void setDelay(uint32_t samples) {
        if (samples >= m_size) samples = m_size - 1;
        m_delay = samples;
    }

    uint32_t delay() const { return m_delay; }

    void reset() {
        if (m_bufL) std::memset(m_bufL.get(), 0, m_size * sizeof(float));
        if (m_bufR) std::memset(m_bufR.get(), 0, m_size * sizeof(float));
        m_writePos = 0;
    }

    void pushOnly(float* const* in, uint32_t frames) {
        if (!in || !in[0] || !in[1] || !m_bufL) return;
        for (uint32_t i = 0; i < frames; ++i) {
            m_bufL[m_writePos] = in[0][i];
            m_bufR[m_writePos] = in[1][i];
            m_writePos = (m_writePos + 1) % m_size;
        }
    }

    void process(float* const* in, float* const* out, uint32_t frames) {
        if (!in || !out || !in[0] || !in[1] || !out[0] || !out[1] || !m_bufL) return;
        if (m_delay == 0) {
            if (in[0] != out[0]) std::memcpy(out[0], in[0], static_cast<size_t>(frames) * sizeof(float));
            if (in[1] != out[1]) std::memcpy(out[1], in[1], static_cast<size_t>(frames) * sizeof(float));
            return;
        }
        for (uint32_t i = 0; i < frames; ++i) {
            m_bufL[m_writePos] = in[0][i];
            m_bufR[m_writePos] = in[1][i];
            const uint32_t rp = (m_writePos + m_size - m_delay) % m_size;
            out[0][i] = m_bufL[rp];
            out[1][i] = m_bufR[rp];
            m_writePos = (m_writePos + 1) % m_size;
        }
    }

private:
    std::unique_ptr<float[]> m_bufL;
    std::unique_ptr<float[]> m_bufR;
    uint32_t m_size = 0;
    uint32_t m_writePos = 0;
    uint32_t m_delay = 0;
};

class MultiDelayLine {
public:
    static constexpr uint32_t kMaxDelay = DelayLine::kMaxDelay;
    static constexpr uint32_t kMaxChannels = 8;

    bool prepare(uint32_t maxDelay) {
        if (maxDelay == 0) maxDelay = 1;
        if (maxDelay > kMaxDelay) maxDelay = kMaxDelay;
        const uint32_t size = maxDelay + 1;
        for (auto& buf : m_bufs) {
            buf.reset(new (std::nothrow) float[size]());
            if (!buf) return false;
        }
        m_size = size;
        m_writePos = 0;
        m_delay = 0;
        return true;
    }

    void setDelay(uint32_t samples) {
        if (m_size == 0) {
            m_delay = 0;
            return;
        }
        if (samples >= m_size) samples = m_size - 1;
        m_delay = samples;
    }

    uint32_t delay() const { return m_delay; }

    void reset() {
        for (auto& buf : m_bufs) {
            if (buf) std::memset(buf.get(), 0, m_size * sizeof(float));
        }
        m_writePos = 0;
    }

    void pushOnly(const float* interleaved, uint32_t frames, uint32_t channels,
                  uint32_t mask) {
        if (!interleaved || !m_bufs[0] || channels == 0) return;
        if (channels > kMaxChannels) channels = kMaxChannels;
        const uint32_t useMask = mask & ((1u << channels) - 1u);
        if (useMask == 0) return;
        for (uint32_t i = 0; i < frames; ++i) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                if (useMask & (1u << ch)) {
                    m_bufs[ch][m_writePos] = interleaved[i * channels + ch];
                }
            }
            m_writePos = (m_writePos + 1) % m_size;
        }
    }

    void process(float* interleaved, uint32_t frames, uint32_t channels,
                 uint32_t mask) {
        if (!interleaved || !m_bufs[0] || channels == 0) return;
        if (channels > kMaxChannels) channels = kMaxChannels;
        const uint32_t useMask = mask & ((1u << channels) - 1u);
        if (useMask == 0 || m_delay == 0) return;
        for (uint32_t i = 0; i < frames; ++i) {
            for (uint32_t ch = 0; ch < channels; ++ch) {
                if (!(useMask & (1u << ch))) continue;
                float* buf = m_bufs[ch].get();
                buf[m_writePos] = interleaved[i * channels + ch];
                const uint32_t rp = (m_writePos + m_size - m_delay) % m_size;
                interleaved[i * channels + ch] = buf[rp];
            }
            m_writePos = (m_writePos + 1) % m_size;
        }
    }

private:
    std::array<std::unique_ptr<float[]>, kMaxChannels> m_bufs;
    uint32_t m_size = 0;
    uint32_t m_writePos = 0;
    uint32_t m_delay = 0;
};

} // namespace auradsp
