#pragma once

#include "plugin_host.h"
#include "plugin_host_client.h"

#include <atomic>
#include <cstdint>
#include <memory>

namespace auradsp {

class ProcessPluginProxy final : public IPluginInstance {
public:
    ProcessPluginProxy(std::shared_ptr<PluginHostClient> client, size_t slot,
                       double sampleRate, uint32_t maxBlockSize);
    ~ProcessPluginProxy() override;

    bool load(const std::string& path, const std::string& pluginId,
              const PluginMetadata* scanSeed = nullptr) override;
    void unload() override;
    bool activate(double sampleRate, uint32_t maxBlockSize) override;
    void deactivate() override;
    void process(float* const* inChannels, float* const* outChannels,
                 uint32_t numFrames) override;
    void processInterleaved(float* interleaved, uint32_t numFrames,
                            uint32_t channels, uint32_t mask) override;
    bool interleavedTransport() const override { return true; }
    void setChannelHint(int channels) override;
    bool isLoaded() const override;
    bool isBypassed() const override;
    bool hostTransportFailed() const override {
        return m_failed.load(std::memory_order_acquire);
    }
    void setBypass(bool bypass) override;
    uint32_t getLatency() const override;
    const PluginMetadata& getMetadata() const override;
    PluginBusInfo busInfo() const override { return m_busInfo; }

    bool showEditor(const std::string& title = "") override;
    void closeEditor() override;
    bool isEditorOpen() const override;

    bool savePreset(const std::string& filePath) override;
    bool loadPreset(const std::string& filePath) override;

    uint64_t inputOverflows() const;
    uint64_t outputOverflows() const;
    uint64_t chunksIn() const;
    uint64_t chunksOut() const;
    // F-4: output blocks lost upstream (host output-ring overflow, or
    // parameter-transition drops) counted via seq continuity checks.
    uint64_t seqGaps() const;
    // E15: 传输流水深不变量观测（inFlight 应恒 ∈{0,1}；maxInFlight==1 是
    // latency 上报绝对精确的前提；depthViolations>0 即上报不再可信）。
    uint32_t inFlight() const {
        return m_inFlight.load(std::memory_order_acquire);
    }
    uint32_t maxInFlight() const {
        return m_maxInFlight.load(std::memory_order_acquire);
    }
    uint32_t depthViolations() const {
        return m_depthViolations.load(std::memory_order_acquire);
    }
    uint32_t depthDrops() const {
        return m_depthDrops.load(std::memory_order_acquire);
    }
    // E15：当前上限（= 每次回调的传输块数；供 status 判定上报口径）。
    uint32_t depthTarget() const;
    bool remoteFailed() const {
        return m_failed.load(std::memory_order_acquire) ||
               (m_client && !m_client->alive());
    }
    // E15 v2：实际传输延迟 = 每次回调块数 × 块长（恒为 1 个回调；128 帧回调
    // 时仍是 128，多块回调时为 numFrames——UI 的「传输延迟」显示据此更真实）。
    uint32_t transportLatency() const {
        return m_targetInFlight.load(std::memory_order_acquire) *
               ipc::kTransportFrames;
    }

private:
    // F-4/F-5: channels/mask are per-call (block-level) parameters — they no
    // longer live in members. The session-level bus channel count stays in
    // m_transportChannels, owned exclusively by setChannelHint.
    bool submitChunk(uint32_t channels, uint32_t mask);
    bool pumpOutput(uint32_t channels, uint32_t mask);
    // E15：取回一块（含 stale/参数变更丢弃）= 深度 -1，钳制不下溢。
    void ConsumeDepthOne();
    void copyBypass(float* const* inChannels, float* const* outChannels,
                    uint32_t numFrames) const;

    std::shared_ptr<PluginHostClient> m_client;
    std::shared_ptr<SharedRegion> m_region;
    ipc::SlotAudioRing* m_ring = nullptr;
    /* F-6: 宿主音频线程唤醒事件的借用句柄（客户端所有，本类不关闭）。
     * load() 时在控制路径缓存一次，音频线程 submitChunk 成功后直接
     * SetEvent——不触碰客户端互斥锁，保持 RT-safe。宿主重启后此副本
     * 失效（指向上一代事件，信号无害丢失，宿主 2 ms 超时兜底），下次
     * load() 重新缓存。 */
    HANDLE m_wakeEvent = nullptr;
    size_t m_slot = 0;
    double m_sampleRate = 48000.0;
    uint32_t m_maxBlock = 1024;
    PluginMetadata m_metadata;
    PluginBusInfo m_busInfo;

    std::atomic<bool> m_loaded{false};
    std::atomic<bool> m_bypassed{false};
    std::atomic<bool> m_failed{false};
    std::atomic<bool> m_editorOpen{false};
    std::atomic<uint32_t> m_latency{0};

    // Proxy-side scratch buffers stay PLANAR (same layout as ipc::AudioBlock):
    // sample index for channel ch at frame i is ch * kTransportFrames + i.
    // Interleaving only happens at the public processInterleaved() boundary.
    float m_inPlanar[ipc::kChannels * ipc::kTransportFrames] = {};
    uint32_t m_inFill = 0;
    uint64_t m_nextSeq = 0;

    float m_outPlanar[ipc::kChannels * ipc::kTransportFrames] = {};
    uint32_t m_outFill = 0;
    uint32_t m_outPos = 0;
    uint32_t m_outChannels = 2;
    uint32_t m_outMask = 0xFF;

    /* F-5: bus channel count — written only by setChannelHint (control
     * thread), read by the audio thread (bypass width in copyBypass /
     * process()). Atomic because the two are different threads; the old
     * plain member was a data race between them. */
    std::atomic<uint32_t> m_transportChannels{2};

    // F-4: output-side seq continuity tracking (audio thread writes; status
    // reads from the control thread — both atomic).
    uint64_t m_nextSeqOut = 0;
    bool m_outSynced = false;
    std::atomic<uint64_t> m_seqGaps{0};
    std::atomic<uint32_t> m_missStreak{0};

    /* E12: 本传输块内是否取得过任何输出块（音频线程私有，块边界评估后清零）。
     * 饥饿信号的正确口径是「流水建立后整块零输出」；旧实现把块尾 prefetch
     * 失败当饥饿计数——那是健康流水下的常态（帧首已消费上一块结果，本块
     * 刚提交的块不可能微秒级返回），导致 missStreak 每块自增、~64 块后误判
     * 宿主死亡永久 bypass。 */
    bool m_gotOutputThisBlock = false;

    /* E14: 本传输块内是否发生过直通帧（无输出可用 → 输入原样保留）。
     * 直通块在块边界被**丢弃不提交**——直通内容已被上层听见，再提交会让
     * 宿主处理结果（回声）稍后再次进入输出流，同一段音频听到两遍。 */
    bool m_blockHadPassthrough = false;

    /* E15（2026-10-23）确定性流水深：把「动态流水深」变成**可断言的不变量**。
     * inFlight = 已提交 - 已取回（含 stale/参数变更丢弃的取回），正常应恒
     * ∈ {0,1}。E14 的直通块丢弃已在结构上阻止深度涨到 2；本记账把它变成
     * 可观测事实——**maxInFlight==1 时上报的 latency（+1×kTransportFrames）
     * 才绝对精确**，一旦越界 status 里立刻看得见（depthViolations）。
     * 音频线程读写、status 从控制线程读 → atomic。 */
    std::atomic<uint32_t> m_inFlight{0};
    std::atomic<uint32_t> m_maxInFlight{0};
    std::atomic<uint32_t> m_depthViolations{0};
    /* 因深度已满（宿主尚未消化上一块）而未提交的块数。健康 paced 流水应≈0；
     * 持续增长 = 宿主算力不足，此时直通替代排队。 */
    std::atomic<uint32_t> m_depthDrops{0};

    /* E15（2026-10-23 v2）确定性流水深 = **每次回调的传输块数 N**
     * （N = ceil(numFrames / kTransportFrames)，随回调块大小自适应）。
     *
     * 为什么不能固定 1：消费是「帧到即取」，一次 auradsp_process 调用在微秒内
     * 跑完但代表 N×2.67ms 音频——宿主不可能在该调用内部产出。所以固定深度 1
     * 时，N 块的回调只有 1 块能拿到湿声，其余必须直通；实测延迟也随 N 线性
     * 漂移（128→128、256→256、512→768、1024→1792 帧）。
     * 深度 = N 时：本次回调提交的 N 块由下一次回调开头一次性消费 → **延迟恰为
     * 1 个回调（numFrames）**，与 N 无关地恒定，且可精确上报。
     * 插件自身延迟另计（m_pluginLatency）。 */
    std::atomic<uint32_t> m_targetInFlight{1};
    std::atomic<uint32_t> m_pluginLatency{0};
};

} // namespace auradsp
