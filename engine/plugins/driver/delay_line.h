#pragma once

#include <cstdint>
#include <cstring>
#include <array>
#include <memory>

namespace auradsp {

class MultiDelayLine {
public:
    static constexpr uint32_t kMaxDelay = 65536;
    static constexpr uint32_t kMaxChannels = 8;

    bool prepare(uint32_t maxDelay) {
        if (maxDelay == 0) maxDelay = 1;
        if (maxDelay > kMaxDelay) maxDelay = kMaxDelay;
        const uint32_t size = maxDelay + 1;
        for (auto& buf : m_bufs) {
            buf.reset(new (std::nothrow) float[size]());
            if (!buf) {
                /* 分配失败：释放已成功的部分，保持 m_size=0，RT 路径全部
                 * 直通（pushOnly/process 首行即返回），不会出现 %0。 */
                for (auto& b : m_bufs) b.reset();
                m_size = 0;
                m_writePos = 0;
                m_delay = 0;
                return false;
            }
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
        if (!interleaved || m_size == 0 || !m_bufs[0] || channels == 0) return;
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
