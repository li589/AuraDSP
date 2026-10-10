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
#include <array>

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

    // GUI Editor Window (Win32)
    virtual bool showEditor(void* parentHwnd = nullptr) = 0;
    virtual void closeEditor() = 0;
    virtual bool isEditorOpen() const = 0;

    // Presets (State serialization)
    virtual bool savePreset(const std::string& filePath) = 0;
    virtual bool loadPreset(const std::string& filePath) = 0;
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
    static constexpr size_t kMaxPluginSlots = 2;

    struct PluginSlot {
        std::unique_ptr<IPluginInstance> instance;
        std::atomic<bool> hasActive{false};
        std::atomic<bool> bypassed{false};
        std::atomic<uint32_t> latency{0};
        std::atomic<int> insertStage{3}; // 0=Pre-DSP, 1=Pre-Vendor, 2=Post-Vendor, 3=Post-Reverb, 4=Post-Limiter
        /* RT 临界区握手计数器（修复 use-after-free）。
         * 契约：RT 侧进入 processSlot 时先 fetch_add(acq_rel) 再读 hasActive；
         * 控制侧卸载时先 hasActive=false(release) + destroyPending=true，
         * 加 acquire 栅栏后等 inFlight 归零才允许销毁 instance。
         * 二者构成 Dekker 式握手，杜绝「RT 已通过检查但实例被 reset」的竞争。 */
        std::atomic<uint32_t> inFlight{0};
        std::atomic<bool> destroyPending{false};
    };

    PluginHostManager();
    ~PluginHostManager();

    // Scanning & Cache
    int scanPlugins(const std::string& extraDirsJson, bool deepScan);
    size_t getScannedCount() const;
    std::string getScannedItemJson(size_t index) const;
    std::string getAllScannedJson() const;

    // Slot-Aware Lifecycle & Control (slot = 0 .. kMaxPluginSlots-1)
    bool loadPluginSlot(size_t slot, const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize);
    void unloadPluginSlot(size_t slot);
    void setBypassSlot(size_t slot, bool bypass);
    bool isBypassedSlot(size_t slot) const;
    uint32_t getLatencySlot(size_t slot) const;
    bool hasActivePluginSlot(size_t slot) const;
    std::string getStatusJsonSlot(size_t slot) const;

    // Slot GUI & Presets
    bool showEditorSlot(size_t slot);
    void closeEditorSlot(size_t slot);
    bool isEditorOpenSlot(size_t slot) const;
    bool savePresetSlot(size_t slot, const std::string& filePath);
    bool loadPresetSlot(size_t slot, const std::string& filePath);

    // Slot Chain Insertion Stage (0=Pre-DSP, 1=Pre-Vendor, 2=Post-Vendor, 3=Post-Reverb, 4=Post-Limiter)
    void setInsertStageSlot(size_t slot, int stage);
    int getInsertStageSlot(size_t slot) const;

    // Process single slot (RT-Safe)
    void processSlot(size_t slot, float* const* inChannels, float* const* outChannels, uint32_t numFrames);

    // Legacy single-slot helper. Only loadPlugin() is still referenced
    // (test/smoke/test_plugin_direct.cpp); the other six forwards were removed
    // as dead code -- the C ABI keeps its own single-slot compatibility symbols
    // (auradsp_plugin_load etc.), which forward to the *Slot functions
    // directly and never went through these members.
    bool loadPlugin(const std::string& path, const std::string& pluginId, double sampleRate, uint32_t maxBlockSize);

    // Sample rate / block size update
    void updateFormat(double sampleRate, uint32_t maxBlockSize);

    void unloadPluginSlotLocked(size_t slot);

    std::vector<PluginMetadata> m_scannedPlugins;
    std::array<PluginSlot, kMaxPluginSlots> m_slots;
    double m_sampleRate{48000.0};
    uint32_t m_maxBlockSize{1024};
    mutable std::recursive_mutex m_hostMutex;
};

} // namespace auradsp

#endif // AURADSP_PLUGIN_HOST_H
