#pragma once
// plugin_host_util.h —— P1 主机拆分共享件：纯搬运 + 最小 linkage 调整。
//   InFlightGuard/kQuiesceSpinLimit —— 原匿名 ns，直放命名空间
//   ClapHostThreadType + t_clapThreadType —— enum 定义 + extern 声明
//   ModulePumpThread —— 整类搬入，static 成员改 inline static
//   utf8/normalize —— 原 static 自由函数改 inline
//   其余为跨 TU 引用的自由函数声明（定义各在一处）
#include "plugin_host.h"
#include "debug_log.h"  // B-1 统一调试日志宏

#include <windows.h>
#include <string>
#include <atomic>
#include <cstdint>
#include <thread>
#include <mutex>
#include <map>
#include <memory>
#include <functional>
#include <deque>
#include <set>
#include <filesystem>
#include <system_error>
#include <algorithm>

// VST3 接口声明（定义见 formats/plugin_instances.cpp 的静态锚点；多包含安全）
#include <steinberg/vst3/base/FUnknown.h>
#include <steinberg/vst3/base/IPluginFactory.h>
#include <steinberg/vst3/base/IPluginFactory2.h>
#include <steinberg/vst3/base/IPluginFactory3.h>
// CLAP 纯 C 接口头（多包含安全）
#include <clap/clap.h>

namespace fs = std::filesystem;

namespace auradsp {


/* RT 临界区守卫：进入时已由调用方 fetch_add(acq_rel) 计入 inFlight，
 * 析构时递减；若是最后一个离开者且控制线程正在等排空，则唤醒它。
 * 唤醒带 pend 检查，避免每块都触发一次无谓的 futex/WaitOnAddress 系统调用。 */
struct InFlightGuard {
    std::atomic<uint32_t>& counter;
    std::atomic<bool>& pending;
    InFlightGuard(std::atomic<uint32_t>& c, std::atomic<bool>& p) : counter(c), pending(p) {}
    ~InFlightGuard() {
        if (counter.fetch_sub(1, std::memory_order_release) == 1 &&
            pending.load(std::memory_order_relaxed)) {
            counter.notify_all();
        }
    }
    InFlightGuard(const InFlightGuard&) = delete;
    InFlightGuard& operator=(const InFlightGuard&) = delete;
};

/* 控制线程等待 RT 排空的自旋上限。正常路径 0~1 次 wait 即返回；
 * 超过上限视为「RT 线程异常滞留」，此时选择保留实例而不是冒险释放。 */
constexpr uint32_t kQuiesceSpinLimit = 4096;

enum class ClapHostThreadType {
    Main,
    Audio
};

static constexpr UINT_PTR kSizeSettleTimerId = 0x4143;  // 避免与 CLAP 插件自己的定时器 ID 冲突
extern thread_local ClapHostThreadType t_clapThreadType;

//------------------------------------------------------------------------------
// ModulePumpThread —— 按插件模块（DLL）共享的 plugin main 线程（C1 2026-10-12）
//------------------------------------------------------------------------------
// 背景（C1 多槽挂载同一插件）：Windows LoadLibrary 对同路径返回同一模块
// （引用计数），于是同 DLL 的两个实例共享全部静态状态——JUCE 系插件的
// MessageManager 即其一（message thread 归属在 entry->init 首次触达并固定）。
// B3 结构是「每实例一条泵线程」：槽 2 的实例自建第二条线程后，JUCE 的
// MessageManager 锁在两条线程间互等 → 死锁。修复：同一二进制只建一条泵
// 线程，实例经 shared_ptr 引用计数持有；最后一实例卸载时线程才停。
//
// 关键不变量：
// - acquireModulePump(key) 幂等：同 key 的并发/重复调用返回同一条线程；
// - PumpDeleter：stop 成功（线程 join 退出）才 delete 对象；失败则故意
//   泄漏，保住 this 与挂死线程栈上的引用（对齐 B3 隔离区哲学）；
// - SEH 守卫：任务内插件代码抛硬件异常（GUI 崩溃）时在本线程内捕获并
//   毒化队列——后续任务的 future 永不兑现，各实例 postTaskAndWait
//   超时后自行进入隔离，单插件崩溃不再炸整个进程；
// - abandoned（毒化/停失败）的泵永不被 registry 复用，新实例建新线程。
//
// 唤醒泵线程执行任务队列的消息（统一替换 B3 的 WM_APP_CLAP_TASK /
// WM_APP_VST3_TASK——泵线程已与格式解耦，不再需要每格式一条）。
constexpr UINT WM_APP_PUMP_TASK = WM_APP + 0x1A2;

class ModulePumpThread {
public:
    using Task = std::function<void()>;

    // 按规范化二进制路径取得（必要时新建）该模块的共享泵线程。
    // 返回 nullptr = 线程起不来（调用方按加载失败处理并释放模块）。
    static std::shared_ptr<ModulePumpThread> acquire(const std::string& key) {
        std::lock_guard<std::mutex> lock(s_registryMutex);
        auto it = s_registry.find(key);
        if (it != s_registry.end()) {
            if (auto existing = it->second.lock()) {
                if (!existing->m_abandoned.load(std::memory_order_acquire)) {
                    return existing;   // 同模块第二实例：共享同一线程
                }
                // 毒化的泵不复用（插件 DLL 可能已处于崩溃后的不一致态）。
            }
        }
        auto* raw = new ModulePumpThread();
        std::shared_ptr<ModulePumpThread> pump(raw, PumpDeleter{});
        if (!raw->start()) {
            // start 内部已尽力收尾；失败置 abandoned，PumpDeleter 将再次
            // 尝试 stop 并最终按挂死泄漏对象（绝不 delete 仍被引用的 this）。
            raw->m_abandoned.store(true, std::memory_order_release);
            return nullptr;
        }
        s_registry[key] = pump;
        return pump;
    }

    bool isReady() const { return m_ready.load(std::memory_order_acquire); }
    bool isAbandoned() const { return m_abandoned.load(std::memory_order_acquire); }
    DWORD threadId() const { return m_threadId; }

    // 提交任务到 plugin main 线程并等待完成（有界超时）。
    // 返回 false = 线程停摆/毒化或超时（调用方走废弃隔离路径）。
    bool postTaskAndWait(Task fn, DWORD timeoutMs) {
        if (m_stopRequested.load(std::memory_order_acquire) ||
            m_abandoned.load(std::memory_order_acquire)) {
            return false;
        }
        auto task = std::make_shared<std::packaged_task<void()>>(std::move(fn));
        auto fut = task->get_future();
        {
            std::lock_guard<std::mutex> lock(m_taskMutex);
            m_tasks.emplace_back([task]() { (*task)(); });
        }
        if (!PostThreadMessageW(m_threadId, WM_APP_PUMP_TASK, 0, 0)) {
            // Ready 已置位意味着 GetMessageW 已在跑、消息队列必已建立；
            // 此分支仅防御极端时序，短暂重试一次。
            Sleep(20);
            if (!PostThreadMessageW(m_threadId, WM_APP_PUMP_TASK, 0, 0)) {
                AURADSP_WARN_S("[DBG Pump] PostThreadMessage failed, err=" << GetLastError());
                return false;
            }
        }
        return fut.wait_for(std::chrono::milliseconds(timeoutMs)) == std::future_status::ready;
    }

    // 编辑器窗口登记：泵线程异常退出（毒化/停摆）时兜底销毁这些容器，
    // 避免留下无人消息泵的僵尸窗口。
    void registerEditor(HWND hwnd) {
        std::lock_guard<std::mutex> lock(m_editorMutex);
        m_editors.insert(hwnd);
    }
    void unregisterEditor(HWND hwnd) {
        std::lock_guard<std::mutex> lock(m_editorMutex);
        m_editors.erase(hwnd);
    }

private:
    ModulePumpThread() = default;
    ~ModulePumpThread() = default;

    // shared_ptr 的 deleter：引用计数归零（最后一实例卸载）时触发。
    struct PumpDeleter {
        void operator()(ModulePumpThread* p) const {
            if (p->stop()) {
                delete p;   // 线程已 join 退出，无引用残留
                return;
            }
            // 挂死：故意泄漏。p 仍被挂死线程的栈引用，delete = UAF。
            AURADSP_WARN("[DBG Pump] deleter: thread unresponsive; leaking pump object (quarantine)");
        }
    };
    friend struct PumpDeleter;

    bool start() {
        m_ready.store(false, std::memory_order_release);
        m_stopRequested.store(false, std::memory_order_release);
        m_abandoned.store(false, std::memory_order_release);
        m_thread = std::thread([this]() { mainLoop(); });
        for (int i = 0; i < 200 && !m_ready.load(std::memory_order_acquire); ++i) {
            Sleep(10);
        }
        if (!m_ready.load(std::memory_order_acquire)) {
            AURADSP_WARN("[DBG Pump] main thread failed to start");
            stop();
            return false;
        }
        return true;
    }

    // 请求线程退出并 join（有界）。返回 true = 已干净退出；
    // false = 挂死（调用方按泄漏处理，本对象不得 delete）。
    bool stop() {
        if (!m_thread.joinable()) return true;   // 已 join 或从未启动
        m_stopRequested.store(true, std::memory_order_release);
        PostThreadMessageW(m_threadId, WM_QUIT, 0, 0);
        HANDLE h = reinterpret_cast<HANDLE>(m_thread.native_handle());
        if (h && WaitForSingleObject(h, 3000) == WAIT_OBJECT_0) {
            m_thread.join();
            return true;
        }
        m_abandoned.store(true, std::memory_order_release);
        m_thread.detach();   // 挂死线程仍引用 this —— 对象交由 PumpDeleter 泄漏
        return false;
    }

    void mainLoop() {
        // CLAP host thread-check 回调据此识别 main thread（thread_local 默认
        // 即 Main；此处显式置位，语义不依赖默认值）。
        t_clapThreadType = ClapHostThreadType::Main;
        m_threadId = GetCurrentThreadId();
        m_ready.store(true, std::memory_order_release);
        MSG msg;
        for (;;) {
            BOOL r = GetMessageW(&msg, NULL, 0, 0);
            if (r <= 0) break;   // WM_QUIT（或错误）→ 退出
            if (msg.message == WM_APP_PUMP_TASK) {
                drainTasks();
                if (m_abandoned.load(std::memory_order_acquire)) {
                    break;   // 任务崩溃毒化：停止服务，让各实例超时隔离
                }
                continue;
            }
            // 编辑器容器窗口的 WM_CLOSE 由 WndProc 经 GWLP_USERDATA 分发到
            // 实例（onEditorWmClose），此处不再截获——泵与实例已解耦。
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        destroyRegisteredEditors();
    }

    void drainTasks() {
        for (;;) {
            std::function<void()> task;
            {
                std::lock_guard<std::mutex> lock(m_taskMutex);
                if (m_tasks.empty()) return;
                task = std::move(m_tasks.front());
                m_tasks.pop_front();
            }
            runTaskGuarded(&task);
            if (m_abandoned.load(std::memory_order_acquire)) {
                // 本任务崩溃：丢弃后续任务（其 packaged_task 永不兑现 →
                // 等待方超时 → 实例隔离），避免在崩溃后的插件状态上继续执行。
                std::lock_guard<std::mutex> lock(m_taskMutex);
                m_tasks.clear();
                return;
            }
        }
    }

    // SEH 任务守卫（C1）：MSVC 限制 __try 不能出现在需要 C++ 对象 unwind 的
    // 函数里（C2712），故隔离到本无对象成员函数；processSlotGuarded 同款手法。
    // 捕获 = 插件代码（多为 GUI 路径）抛硬件异常：毒化本泵（m_abandoned），
    // drainTasks 丢弃后续任务，进程存活；各实例随后的 postTaskAndWait 立即
    // 返回 false → 走各自的废弃隔离路径。
    void runTaskGuarded(std::function<void()>* task) {
#if defined(_MSC_VER)
        __try {
            (*task)();
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            AURADSP_WARN("[DBG Pump] task crashed (SEH); poisoning pump");
            m_abandoned.store(true, std::memory_order_release);
        }
#else
        try {
            (*task)();
        } catch (...) {
            AURADSP_WARN("[DBG Pump] task threw; poisoning pump");
            m_abandoned.store(true, std::memory_order_release);
        }
#endif
    }

    void destroyRegisteredEditors() {
        std::lock_guard<std::mutex> lock(m_editorMutex);
        for (HWND hwnd : m_editors) {
            if (hwnd && IsWindow(hwnd)) DestroyWindow(hwnd);
        }
        m_editors.clear();
    }

    std::thread m_thread;
    DWORD m_threadId = 0;
    std::atomic<bool> m_ready{false};
    std::atomic<bool> m_stopRequested{false};
    std::atomic<bool> m_abandoned{false};
    std::mutex m_taskMutex;
    std::deque<std::function<void()>> m_tasks;
    std::mutex m_editorMutex;
    std::set<HWND> m_editors;

    // registry：key = 规范化二进制路径（小写、canonical）。weak_ptr 使
    // 最后一实例卸载后条目自然过期；static 生命周期同进程（绝不在 exit()
    // 析构——泵线程可能仍挂死于插件代码）。
    inline static std::mutex s_registryMutex;
    inline static std::map<std::string, std::weak_ptr<ModulePumpThread>> s_registry;
};


// 规范化模块键：Windows 路径大小写不敏感（LoadLibrary 同路径同模块），
// canonical 化消解 junction/短名等别名。规范化失败时退化为小写原路径。

inline std::wstring utf8ToWide(const std::string& utf8) {
    if (utf8.empty()) return std::wstring();
    int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (size <= 0) return std::wstring();
    std::wstring wide(size - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], size);
    return wide;
}

inline std::string wideToUtf8(const std::wstring& wide) {
    if (wide.empty()) return std::string();
    int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) return std::string();
    std::string utf8(size - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, &utf8[0], size, nullptr, nullptr);
    return utf8;
}

inline std::string normalizeModuleKey(const std::wstring& wpath) {
    std::error_code ec;
    fs::path canonical = fs::weakly_canonical(fs::path(wpath), ec);
    std::string key = wideToUtf8(ec ? wpath : canonical.wstring());
    std::transform(key.begin(), key.end(), key.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return key;
}

int processSlotGuarded(PluginHostManager::PluginSlot& s, float* const* inChannels, float* const* outChannels, uint32_t numFrames);
void quarantineAbandonedInstance(std::unique_ptr<IPluginInstance> inst);
void ResizeDirectChildren(HWND hwnd);
void EnsureClapWindowClassRegistered();
void EnsureVst3WindowClassRegistered();
// 实例工厂（定义在 formats/plugin_instances.cpp；manager TU 只经此创建实例，
// 不直引具体类，保持 TU 边界干净）
std::unique_ptr<IPluginInstance> createClapInstance();
std::unique_ptr<IPluginInstance> createVst3Instance();
std::string escapeJsonString(const std::string& input);
std::string cidToHexString(const Steinberg::TUID tuid);
bool hexStringToCid(const std::string& hex, Steinberg::TUID tuid);
void setupPluginDllDirectories(const std::string& pluginPath);
std::string extractVendorFromPath(const std::string& filePath);
bool peIs64Bit(const std::wstring& binaryPath);
std::string extractCompanyFromVersionInfo(const std::wstring& binaryPath);
std::string extractProductVersionFromVersionInfo(const std::wstring& binaryPath);
std::string extractVendorFromLegalCopyright(const std::wstring& binaryPath);
void seedMetadataFromScan(PluginMetadata& dst, const PluginMetadata& src);
void applyClapDescriptor(PluginMetadata& meta, const clap_plugin_descriptor_t* d, const std::wstring& binaryPath, const std::string& bundlePath);
bool applyVstAudioEffectClass(PluginMetadata& meta, Steinberg::IPluginFactory* factory, Steinberg::IPluginFactory2* factory2, Steinberg::IPluginFactory3* factory3, Steinberg::int32 index, const std::wstring& binaryPath, const std::string& bundlePath, bool seeded = false, Steinberg::TUID* outTuid = nullptr);

} // namespace auradsp
