/*
 * auradsp_plugin_host.h — AuraDSP M1 Plugin Host Engine (VST3 / CLAP 64-bit)
 *
 * Implements in-process plugin hosting for:
 *   - CLAP (Clever Audio Plugin) via pure C ABI (clap/clap.h)
 *   - VST3 via Steinberg C++ SDK (steinberg/vst3.h)
 *
 * Provides:
 *   - Plugin directory scanner (quick scan / deep scan)
 *   - Host lifecycle management (load, activate, process, deactivate, unload)
 *   - RT-safe audio processing with bypass and crash protection
 *   - JSON serialization for Dart FFI / UI integration
 */

#ifndef AURADSP_PLUGIN_HOST_H
#define AURADSP_PLUGIN_HOST_H

#include <string>
#include <vector>
#include <memory>
#include <cstdint>
#include <mutex>
#include <atomic>

namespace auradsp {

enum class PluginFormat {
    Unknown = 0,
    VST3,
    CLAP
};

struct PluginMetadata {
    std::string path;         // Absolute file/bundle path
    std::string id;           // Unique ID (URI for CLAP, CID hex for VST3)
    std::string name;         // Display name
    std::string vendor;       // Vendor name
    std::string version;      // Version string
    std::string category;     // e.g. "Fx|Reverb", "Effect", etc.
    PluginFormat format = PluginFormat::Unknown;
    bool is64Bit = true;
    uint32_t latency = 0;
    bool isCompatible = true;
    std::string errorMessage;

    std::string toJson() const;
    static PluginMetadata fromJson(const std::string& json);
};

class IPluginInstance {
public:
    virtual ~IPluginInstance() = default;
    virtual bool load(const std::string& path, const std::string& pluginId) = 0;
    virtual void unload() = 0;
    virtual bool activate(double sampleRate, uint32_t maxBlockSize) = 0;
    virtual void deactivate() = 0;
    virtual void process(float* const* inChannels, float* const* outChannels, uint32_t numFrames) = 0;
    virtual bool isLoaded() const = 0;
    virtual bool isBypassed() const = 0;
    virtual void setBypass(bool bypass) = 0;
    virtual uint32_t getLatency() const = 0;
    virtual const PluginMetadata& getMetadata() const = 0;
};

class PluginScanner {
public:
    static std::vector<std::string> getDefaultSearchPaths();
    static std::vector<PluginMetadata> scan(const std::vector<std::string>& searchPaths, bool deepScan);
    static bool queryMetadata(const std::string& filePath, PluginFormat format, std::vector<PluginMetadata>& outPlugins);
    static std::string resolveBundleBinary(const std::string& bundlePath, PluginFormat format);
};

class PluginHostManager {
public:
    PluginHostManager();
    ~PluginHostManager();

    // Scanning & Cache
    int scanPlugins(const std::string& extraDirsJson, bool deepScan);
    size_t getScannedCount() const;
    std::string getScannedItemJson(size_t index) const;
    std::string getAllScannedJson() const;

    // Lifecycle
    bool loadPlugin(const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize);
    void unloadPlugin();

    // Runtime Control
    void setBypass(bool bypass);
    bool isBypassed() const;
    uint32_t getLatency() const;
    bool hasActivePlugin() const;
    std::string getStatusJson() const;

    // RT-Safe audio processing
    void process(float* const* inChannels, float* const* outChannels, uint32_t numFrames);

    // Sample rate / block size update
    void updateFormat(double sampleRate, uint32_t maxBlockSize);

    void unloadPluginLocked();

    std::vector<PluginMetadata> m_scannedPlugins;
    std::unique_ptr<IPluginInstance> m_activePlugin;
    std::atomic<bool> m_hasActivePlugin{false};
    std::atomic<bool> m_bypassed{false};
    std::atomic<uint32_t> m_latency{0};
    double m_sampleRate{48000.0};
    uint32_t m_maxBlockSize{1024};
    mutable std::recursive_mutex m_hostMutex;
};

} // namespace auradsp

#endif // AURADSP_PLUGIN_HOST_H
