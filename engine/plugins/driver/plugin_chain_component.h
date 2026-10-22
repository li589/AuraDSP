#pragma once

#include "plugin_host.h"
#include "delay_line.h"

#include <atomic>
#include <array>
#include <cstdint>
#include <memory>

namespace auradsp {

class PluginChainComponent {
public:
    PluginChainComponent();
    ~PluginChainComponent();

    PluginChainComponent(const PluginChainComponent&) = delete;
    PluginChainComponent& operator=(const PluginChainComponent&) = delete;

    bool prepare(double sampleRate, uint32_t maxBlockSize);
    void reset();

    /* E16（2026-10-22）：平面 4 参 process() 已删除。该入口为 Phase 3 重构前
     * 遗留路径，全库无生产调用方（引擎链经 plugin_chain_adapter 只走
     * processInterleavedN；C++ 一致性测试亦只用 processInterleaved），
     * 且其立体声硬边界（copyPlanar/planarRmsSum 按 [0]/[1] 硬编码）是
     * F-8b 记录过的误路由隐患。>2 声道/交错一律走 processInterleavedN()。 */
    void processInterleaved(int stage, float* interleaved,
                            uint32_t frames) noexcept;
    void processInterleavedN(int stage, float* interleaved, uint32_t frames,
                             uint32_t channels) noexcept;
    void setChannelHint(int channels) noexcept;

    void setBypass(int slot, bool bypass) noexcept;
    bool bypass(int slot) const noexcept;
    uint32_t latency(int slot) const noexcept;
    uint32_t stageLatency(int stage) const noexcept;
    uint32_t totalLatency() const noexcept;
    bool hasActive(int slot) const noexcept;

    void setPdc(bool enable) noexcept { m_pdcEnabled.store(enable, std::memory_order_release); }
    bool pdc() const noexcept { return m_pdcEnabled.load(std::memory_order_acquire); }

    /* 链级启用开关（VB 多总线按路插件处理，2026-10-22）。关闭 = 该 handle
     * 上全部插入阶段的插件（含 PDC 延迟补偿）都不进音频路径：插件不收
     * 输入、零插件 CPU；槽位挂载状态与厂商 DSP 链不受影响。原子布尔，
     * 控制线程写 / 音频线程读。关闭期间 stageLatency/totalLatency 计 0
     * （不处理的插件不得贡献 PDC 延迟）。重新启用时复位各槽延迟线——
     * 关闭期间延迟线内容已陈旧，直接续用会注入旧音频。 */
    void setEnabled(bool enable) noexcept;
    bool enabled() const noexcept { return m_chainEnabled.load(std::memory_order_acquire); }

    PluginHostManager& host() noexcept { return *m_host; }
    const PluginHostManager& host() const noexcept { return *m_host; }

private:
    bool stageHasActive(int stage) const noexcept;
    bool stageHasActiveOrPdc(int stage) const noexcept;

    std::unique_ptr<PluginHostManager> m_host;
    /* E16：平面专用工作缓冲（m_chanIn/m_chanOut/m_work 系列共 8 块）随平面
     * process() 一并删除——交错路径全部原地工作，无额外缓冲需求。 */
    uint32_t m_maxBlock = 0;

    std::atomic<bool> m_pdcEnabled{false};
    std::atomic<bool> m_chainEnabled{true};
    std::array<DelayLine, PluginHostManager::kMaxPluginSlots> m_delayLines;
    std::array<MultiDelayLine, PluginHostManager::kMaxPluginSlots> m_multiDelayLines;
    std::array<uint32_t, PluginHostManager::kMaxPluginSlots> m_lastMasks{};
};

} // namespace auradsp
