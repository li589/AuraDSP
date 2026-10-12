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
#include <unordered_map>
#include <utility>

namespace auradsp {

enum class PluginFormat {
    Unknown = 0,
    VST3,
    CLAP
};

struct PluginMetadata {
    std::string path;         // Absolute file/bundle path
    std::string id;           // Unique ID (URI for CLAP, CID hex for VST3)
    std::string name;         // Plugin self-reported name (CLAP descriptor->name / VST3 classInfo.name)
    std::string bundleName;   // Bundle/file stem — what the user actually picked ("KV-Element-FX")
    std::string vendor;       // Vendor name
    std::string version;      // Version string
    std::string category;     // Real category (CLAP features / VST3 subCategories). NOT a free-text description.
    std::string description;  // Free-text description (CLAP descriptor->description). Display only.
    PluginFormat format = PluginFormat::Unknown;
    bool is64Bit = true;
    uint32_t latency = 0;
    bool isCompatible = true;
    std::string errorMessage;

    /* 只序列化。反序列化在 Dart 侧（PluginMetadata.fromJson），C++ 侧曾有
     * 一个从未实现的 fromJson 声明，加字段后必然失真，故直接删除而非留死代码。 */
    std::string toJson() const;
};

class IPluginInstance {
public:
    virtual ~IPluginInstance() = default;
    /* scanSeed: 扫描期已确认的元数据（PluginHostManager 的 m_scannedPlugins 命中项）。
     * 传入后以扫描值为基准，descriptor 只补空字段、绝不覆盖 —— 这是
     * 「扫描值 == 加载值」的结构性保证；无种子（如从会话恢复直接加载）时
     * 完全依赖描述符路径，且两条路径共用同一填充函数，优先级一致。 */
    virtual bool load(const std::string& path, const std::string& pluginId,
                      const PluginMetadata* scanSeed = nullptr) = 0;
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
    /* title: 窗口标题，由调用方（Dart）决定；为空时退化为插件自报名。
     * 历史上此处是从未使用的 void* parentHwnd 死参数（E1），Dart FFI 的
     * 第三个参数一直是 title 但被 C ABI 丢弃——本次一并接通。 */
    virtual bool showEditor(const std::string& title = "") = 0;
    virtual void closeEditor() = 0;
    virtual bool isEditorOpen() const = 0;

    // Presets (State serialization)
    virtual bool savePreset(const std::string& filePath) = 0;
    virtual bool loadPreset(const std::string& filePath) = 0;

    /* B3（2026-10-12）：实例内部线程挂死时置位。挂死线程仍引用实例，
     * 析构 = use-after-free；manager 据此把整个实例移入静态隔离区
     * （可控泄漏换不可控崩溃），绝不释放。 */
    virtual bool abandoned() const { return false; }

    /* C1（2026-10-12）：编辑器容器窗口收到 WM_CLOSE（用户点 X）时，由容器
     * WndProc 经 GWLP_USERDATA 在 plugin main 线程上回调。默认空实现——
     * 两个具体类必须覆写为「已在泵线程，直接执行收尾」的版本；绝不可
     * 默认转发 closeEditor()（那会 postTaskAndWait 到当前线程 → 死锁）。 */
    virtual void onEditorWmClose() {}
};

class PluginScanner {
public:
    /* C2（2026-10-12）：扫描拆成"枚举"与"取元数据"两阶段。
     * 枚举只遍历目录（无 PE 读取、无 LoadLibrary），成本低且可在 UI 线程
     * 之外一次性做完；取元数据才是耗时部分（深扫每个 DLL 都要 LoadLibrary，
     * 实测 76 个插件 3.6s），必须能被切成小步、由调用方在步间让出线程。 */
    struct ScanCandidate {
        std::string path;         // 对外标识（bundle 根路径）
        std::string binaryPath;   // 真实二进制（bundle 内解析结果）
        std::string displayName;  // stem（快扫拿不到自报名时用）
        PluginFormat format = PluginFormat::Unknown;
    };

    static std::vector<std::string> getDefaultSearchPaths();
    /* 只做目录枚举：返回候选列表，不做任何元数据 I/O。 */
    static std::vector<ScanCandidate> enumerate(const std::vector<std::string>& searchPaths);
    static std::vector<PluginMetadata> scan(const std::vector<std::string>& searchPaths, bool deepScan);
    static bool queryMetadata(const std::string& filePath, PluginFormat format, std::vector<PluginMetadata>& outPlugins);
    /* 解析 bundle 内的真实二进制。探测顺序：x86_64-win（本进程架构）→
     * x86-win（32 位，仅识别不加载）。outArch 非空时写入命中目录名
     * （"x86_64-win" / "x86-win"），未命中留空——D1 的根因就是旧实现
     * 只探测 x86_64-win，缺失即 return ""，32 位 bundle 被静默丢弃。 */
    static std::string resolveBundleBinary(const std::string& bundlePath, PluginFormat format,
                                           std::string* outArch = nullptr);
};

class PluginHostManager {
public:
    static constexpr size_t kMaxPluginSlots = 4;

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

    /* ---- C2 分块扫描（2026-10-12）----
     * 背景：一次性 scanPlugins 是单个长 FFI 调用——快扫 ~120ms（76 个）尚可，
     * 深扫要 LoadLibrary 每个 DLL（3.6s），期间调用方线程（音频 isolate）
     * 完全无法让出，音频泵停摆、进度无从上报。分块后：
     *   scanBegin 枚举候选（便宜）→ scanStep 每次只处理少量候选 →
     *   调用方在步间让出事件循环 → scanEnd 收尾并提交缓存。
     * 结果同时渐进写入 m_scannedPlugins，因此扫描过程中 get_all 即返回
     * 已扫到的部分（列表边扫边长）。 */
    int scanBegin(const std::string& extraDirsJson, bool deepScan);  // 返回候选总数
    int scanStep(int maxItems);                                      // 返回本步处理数（<=0 = 结束）
    int scanProcessed() const;                                       // 已处理候选数（无任务返回 -1）
    int scanTotal() const;                                           // 候选总数（无任务返回 -1）
    int scanEnd();                                                   // 收尾，返回最终插件数
    void scanAbort();                                                // 丢弃任务（保留已扫到的部分）

private:
    // 分块扫描内部辅助：解析搜索目录；扫描结束后重建元数据缓存。
    std::vector<std::string> collectSearchPathsLocked(const std::string& extraDirsJson) const;
    void rebuildScanCacheFromResults(bool deep);

public:
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
    bool showEditorSlot(size_t slot, const std::string& title = "");
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

    // ---- C2 分块扫描状态与元数据缓存 ----
    struct ScanJob {
        std::vector<PluginScanner::ScanCandidate> candidates;
        size_t cursor = 0;
        bool deep = false;
    };
    std::unique_ptr<ScanJob> m_scanJob;
    /* 上次扫描结果按二进制路径缓存（含文件大小+修改时间戳）。
     * 重扫时若文件未变且缓存的扫描深度足够（深扫结果可服务快扫，反之不可以），
     * 直接复用——彻底跳过 PE 版本资源读取与（深扫的）LoadLibrary，
     * 于是"再扫一次"接近瞬时。 */
    /* 值是**列表**而非单条：一个二进制（.vst3 bundle / CLAP bundle）可含多个
     * 插件类，深扫会枚举出 N 条同 path 的元数据。若按单条缓存，重扫命中缓存时
     * 会把 N 折叠成 1，导致"深扫冷 79 / 热 76"这种条目凭空消失的回归。 */
    std::unordered_map<std::string, std::vector<PluginMetadata>> m_scanCache;
    std::unordered_map<std::string, std::pair<uint64_t, int64_t>> m_scanStamps;
    /* 缓存条目是否是深扫产出（用于上面"深度足够"判定）。 */
    std::unordered_map<std::string, bool> m_scanCacheDeep;
};

} // namespace auradsp

#endif // AURADSP_PLUGIN_HOST_H
