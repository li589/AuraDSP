#pragma once
// ModulePumpThread —— 按插件模块（DLL）共享的 plugin main 线程（C1）。
// Phase 2：从 platform/win32/plugin_host_util.h 抽出；只依赖 Win32 与通用线程角色，
// 不含 VST3/CLAP SDK 头。

#include "debug_log.h"
#include "plugin_thread.h"

#include <windows.h>

#include <atomic>
#include <chrono>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>

namespace auradsp {

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
// - acquire(key) 幂等：同 key 的并发/重复调用返回同一条线程；
// - PumpDeleter：stop 成功（线程 join 退出）才 delete 对象；失败则故意
//   泄漏，保住 this 与挂死线程栈上的引用（对齐 B3 隔离区哲学）；
// - SEH 守卫：任务内插件代码抛硬件异常（GUI 崩溃）时在本线程内捕获并
//   毒化队列——后续任务的 future 永不兑现，各实例 postTaskAndWait
//   超时后自行进入隔离，单插件崩溃不再炸整个进程；
// - abandoned（毒化/停失败）的泵永不被 registry 复用，新实例建新线程。
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
        t_pluginThreadRole = PluginThreadRole::Main;
        m_threadId = GetCurrentThreadId();
        // 泵线程同时是 JUCE MessageManager（本 DLL 全部编辑器窗口消息/绘制/
        // 定时器）的执行线程。系统繁忙（多编辑器同开 + DSP 满载）时 NORMAL
        // 优先级会被同层线程抢调度，表现为拧旋钮/切模块不跟手。抬到
        // ABOVE_NORMAL(1)——远低于音频 RT 线程（15=TIME_CRITICAL），
        // 音频保护不受影响；消息循环阻塞等待，无空转代价。
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
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

} // namespace auradsp
