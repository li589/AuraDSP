#pragma once

#include "plugin_ipc_protocol.h"
#include "plugin_shared_region.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/types.h>
// POSIX 唤醒信号量类型（见 posix/host/plugin_host_client_posix.cpp
// 的 F-6 对应说明）。sem_t 在 glibc 是 typedef 而非 struct 标签，
// 无法前置声明，直接包含 <semaphore.h>。
#include <semaphore.h>
#endif

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace auradsp {

/* 双宿主架构（《插件双宿主架构与跨格式扩展方案》§2）：远程客户端
 * 按目标位数分工——X64 客户端驱动 64 位宿主（Windows 现名
 * auradsp_plugin_host.exe，Linux 为 plugin_host_x64），X86 客户端
 * 驱动 32 位桥宿主 plugin_host_x86[.exe]。manager 按插件二进制
 * 位数在两个客户端间分派（见 PluginHostManager::remoteClientFor）。 */
enum class HostArch : uint8_t { X64, X86 };

class PluginHostClient {
public:
    explicit PluginHostClient(HostArch arch = HostArch::X64);
    ~PluginHostClient();

    HostArch arch() const { return m_arch; }

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

    /* F-6: 宿主音频线程的唤醒信号（自动重置事件，命名 <shmName>.wake）。
     * 借用句柄：ProcessPluginProxy 在 load()（控制路径）缓存后由音频线程
     * 唤醒宿主（Win32 SetEvent / POSIX sem_post），缓存方不得关闭。
     * 宿主重启后旧句柄指向上一代信号（无害丢失），宿主等待自带 2 ms
     * 超时兜底，下次 load 重新缓存。
     * 调用约定：仅在 load() 成功后的控制路径读取（此时无并发写者）。
     * POSIX 侧类型为 sem_t*（命名信号量），语义对应见平台实现。 */
#if defined(_WIN32)
    HANDLE wakeEvent() const { return m_wakeEvent; }
#else
    sem_t* wakeEvent() const { return m_wakeEvent; }
#endif

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

    const HostArch m_arch;
    std::atomic<bool> m_processMode{false};
    std::atomic<uint32_t> m_hostPid{0};
    std::atomic<uint64_t> m_generation{0};

    mutable std::mutex m_mutex;
    std::shared_ptr<SharedRegion> m_region;
#if defined(_WIN32)
    HANDLE m_pipe = nullptr;
    HANDLE m_process = nullptr;
    HANDLE m_job = nullptr;
    // F-6: 宿主音频线程唤醒事件。m_mutex 保护写（launchLocked /
    // closeHostHandlesLocked），控制路径经 wakeEvent() 读。
    HANDLE m_wakeEvent = nullptr;
    std::wstring m_pipeName;
    std::wstring m_shmName;
#else
    int m_pipe = -1;             // Unix domain socket fd
    pid_t m_process = 0;         // 宿主进程 pid（0 = 无）
    // F-6: 宿主音频线程唤醒信号量（命名 POSIX 信号量）。m_mutex
    // 保护写（launchLocked / closeHostHandlesLocked）。
    sem_t* m_wakeEvent = nullptr;
    std::string m_pipeName;      // socket 文件系统路径
    std::string m_shmName;       // shm_open 名称（/ 开头）
#endif
    bool m_pipeHealthy = false;
    uint32_t m_requestId = 1;
};

} // namespace auradsp
