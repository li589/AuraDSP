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
    bool requestLocked(ipc::Op op, const std::vector<uint8_t>& payload,
                       std::string* outPayload, int32_t* outStatus);
    bool request(ipc::Op op, const std::vector<uint8_t>& payload,
                 std::string* outPayload, int32_t* outStatus);
    bool simple(ipc::Op op, const std::vector<uint8_t>& payload, int32_t* outStatus);

    std::atomic<bool> m_processMode{false};
    std::atomic<uint32_t> m_hostPid{0};
    std::atomic<uint64_t> m_generation{0};

    mutable std::mutex m_mutex;
    std::shared_ptr<SharedRegion> m_region;
    HANDLE m_pipe = nullptr;
    HANDLE m_process = nullptr;
    HANDLE m_job = nullptr;
    std::wstring m_pipeName;
    std::wstring m_shmName;
    bool m_pipeHealthy = false;
    uint32_t m_requestId = 1;
};

} // namespace auradsp
