#pragma once

#include "plugin_ipc_protocol.h"
#include "plugin_shared_region.h"

#include <windows.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace auradsp {

class PluginHostClient {
public:
    PluginHostClient();
    ~PluginHostClient();

    PluginHostClient(const PluginHostClient&) = delete;
    PluginHostClient& operator=(const PluginHostClient&) = delete;

    /* Reads AURA_PLUGIN_HOST_MODE. Returns true when process mode was requested. */
    bool start();
    void shutdown();

    bool processMode() const { return m_processMode.load(std::memory_order_acquire); }
    bool alive() const;
    bool ensureHost();

    std::shared_ptr<SharedRegion> region() const;
    uint32_t hostPid() const { return m_hostPid.load(std::memory_order_acquire); }
    uint64_t generation() const { return m_generation.load(std::memory_order_acquire); }

    /* F-6: 宿主音频线程的唤醒事件（自动重置，命名 <shmName>.wake）。
     * 借用句柄：ProcessPluginProxy 在 load()（控制路径）缓存后由音频线程
     * SetEvent 唤醒宿主，缓存方不得关闭。宿主重启后旧句柄指向上一代事件
     * （信号无害丢失），宿主等待自带 2 ms 超时兜底，下次 load 重新缓存。
     * 调用约定：仅在 load() 成功后的控制路径读取（此时无并发写者）。 */
    HANDLE wakeEvent() const { return m_wakeEvent; }

    bool load(uint32_t slot, const std::string& path, const std::string& pluginId,
              double sampleRate, uint32_t maxBlockSize,
              ipc::RemotePluginInfo& outInfo, std::string& outError);
    bool unload(uint32_t slot);
    bool setBypass(uint32_t slot, bool bypass);
    bool getBypass(uint32_t slot, bool& bypass);
    uint32_t getLatency(uint32_t slot);
    bool showEditor(uint32_t slot, const std::string& title);
    bool closeEditor(uint32_t slot);
    bool isEditorOpen(uint32_t slot);
    bool savePreset(uint32_t slot, const std::string& path);
    bool loadPreset(uint32_t slot, const std::string& path);
    bool setStage(uint32_t slot, int stage);
    int getStage(uint32_t slot);
    bool updateFormat(double sampleRate, uint32_t maxBlockSize);
    bool setChannelHint(uint32_t channels);

    int scanPlugins(const std::string& extraDirsJson, bool deepScan);
    int scanBegin(const std::string& extraDirsJson, bool deepScan);
    int scanStep(int maxItems);
    int scanEnd();
    int scanProcessed();
    int scanTotal();
    int getScannedCount();
    std::string getScannedItemJson(uint32_t index);
    std::string getAllScannedJson();

private:
    bool launchLocked();
    bool ensureHostLocked();
    void closeHostHandlesLocked();
    bool connectPipeLocked();
    /* timeoutMs：等宿主回复的上界（2026-10-28）。深扫单项可能让宿主卡在
     * LoadLibrary/实例化（无响应），旧实现阻塞 ReadFile 永久等待，UI 永远
     * 停在「正在扫描」。超时 = 认为宿主失联：杀进程 + 标记管道失效，下次
     * 调用 ensureHostLocked 会重启一个干净宿主。 */
    bool requestLocked(ipc::Op op, const std::vector<uint8_t>& payload,
                       std::string* outPayload, int32_t* outStatus,
                       int timeoutMs = 60000);
    bool request(ipc::Op op, const std::vector<uint8_t>& payload,
                 std::string* outPayload, int32_t* outStatus,
                 int timeoutMs = 60000);
    bool simple(ipc::Op op, const std::vector<uint8_t>& payload,
                int32_t* outStatus, int timeoutMs = 60000);

    std::atomic<bool> m_processMode{false};
    std::atomic<uint32_t> m_hostPid{0};
    std::atomic<uint64_t> m_generation{0};

    mutable std::mutex m_mutex;
    std::shared_ptr<SharedRegion> m_region;
    HANDLE m_pipe = nullptr;
    HANDLE m_process = nullptr;
    HANDLE m_job = nullptr;
    // F-6: 宿主音频线程唤醒事件。m_mutex 保护写（launchLocked /
    // closeHostHandlesLocked），控制路径经 wakeEvent() 读。
    HANDLE m_wakeEvent = nullptr;
    std::wstring m_pipeName;
    std::wstring m_shmName;
    bool m_pipeHealthy = false;
    uint32_t m_requestId = 1;
};

} // namespace auradsp
