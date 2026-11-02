#pragma once
// ModulePumpThread —— POSIX 对应物（二期阶段一，2026-11-02）。
//
// 与 platform/win32/module_pump.h 同类名、同公共 API、同本质不变量：
//   - 按规范化模块路径共享一条 plugin main 线程（同 .so 多实例
//     共享静态状态，线程必须唯一——C1 的原始动机在 ELF 世界同样
//     成立：dlopen 同路径返回同一句柄）；
//   - acquire 幂等；毒化（任务抛异常）的泵永不复用；
//   - PumpDeleter：线程停得下来才 delete，停不下来故意泄漏
//     （挂死线程栈上仍有引用，delete 即 UAF——隔离区哲学同
//     Win32 版）。
// 实现差异：Win32 消息循环 → 条件变量任务队列（编辑器窗口消息
// 分发在 Linux 编辑器阶段另行接入）；编辑器登记为空操作。
// 任务守卫：Win32 版用 SEH 捕获硬件异常，POSIX 无等价物，用
// C++ 异常捕获兜底（探针实测通路成立；段错误级崩溃的隔离由
// 进程外宿主阶段四承担，与架构分工一致）。
#include "debug_log.h"
#include "plugin_thread.h"
#include "win32_compat.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

namespace auradsp {

class ModulePumpThread {
public:
    using Task = std::function<void()>;

    // 按规范化二进制路径取得（必要时新建）该模块的共享泵线程。
    // 返回 nullptr = 线程起不来（调用方按加载失败处理）。
    static std::shared_ptr<ModulePumpThread> acquire(const std::string& key) {
        std::lock_guard<std::mutex> lock(s_registryMutex);
        auto it = s_registry.find(key);
        if (it != s_registry.end()) {
            if (auto existing = it->second.lock()) {
                if (!existing->m_abandoned.load(std::memory_order_acquire)) {
                    return existing;
                }
            }
        }
        auto* raw = new ModulePumpThread();
        std::shared_ptr<ModulePumpThread> pump(raw, PumpDeleter{});
        if (!raw->start()) {
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
        m_cv.notify_one();
        return fut.wait_for(std::chrono::milliseconds(timeoutMs)) ==
               std::future_status::ready;
    }

    // 编辑器登记：POSIX 版无窗口兜底销毁需求（编辑器阶段另行
    // 接入），空操作。
    void registerEditor(HWND) {}
    void unregisterEditor(HWND) {}

private:
    ModulePumpThread() = default;
    ~ModulePumpThread() = default;

    struct PumpDeleter {
        void operator()(ModulePumpThread* p) const {
            if (p->stop()) {
                delete p;
                return;
            }
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
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        if (!m_ready.load(std::memory_order_acquire)) {
            AURADSP_WARN("[DBG Pump] main thread failed to start");
            stop();
            return false;
        }
        return true;
    }

    // 请求线程退出并等待（有界 3 秒）。true = 已干净退出；
    // false = 挂死（调用方按泄漏处理，本对象不得 delete）。
    bool stop() {
        if (!m_thread.joinable()) return true;
        m_stopRequested.store(true, std::memory_order_release);
        m_cv.notify_all();
        auto done = std::make_shared<std::atomic<bool>>(false);
        std::thread waiter([this, done]() {
            if (m_thread.joinable()) m_thread.join();
            done->store(true, std::memory_order_release);
        });
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(3);
        while (!done->load(std::memory_order_acquire)) {
            if (std::chrono::steady_clock::now() > deadline) {
                m_abandoned.store(true, std::memory_order_release);
                waiter.detach();
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        waiter.join();
        return true;
    }

    void mainLoop() {
        // CLAP host thread-check 回调据此识别 main thread（与
        // Win32 版同语义：显式置位，不依赖默认值）。
        t_pluginThreadRole = PluginThreadRole::Main;
        m_threadId = 1; // POSIX 无 Win32 tid 语义；调用方只作诊断
        m_ready.store(true, std::memory_order_release);
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(m_taskMutex);
                m_cv.wait(lock, [this]() {
                    return !m_tasks.empty() ||
                           m_stopRequested.load(std::memory_order_acquire);
                });
                if (m_tasks.empty()) {
                    if (m_stopRequested.load(std::memory_order_acquire)) break;
                    continue;
                }
                task = std::move(m_tasks.front());
                m_tasks.pop_front();
            }
            runTaskGuarded(&task);
            if (m_abandoned.load(std::memory_order_acquire)) {
                // 本任务崩溃：丢弃后续任务（等待方超时 → 实例隔离）。
                std::lock_guard<std::mutex> lock(m_taskMutex);
                m_tasks.clear();
                break;
            }
        }
    }

    void runTaskGuarded(std::function<void()>* task) {
        try {
            (*task)();
        } catch (...) {
            AURADSP_WARN("[DBG Pump] task threw; poisoning pump");
            m_abandoned.store(true, std::memory_order_release);
        }
    }

    std::thread m_thread;
    DWORD m_threadId = 0;
    std::atomic<bool> m_ready{false};
    std::atomic<bool> m_stopRequested{false};
    std::atomic<bool> m_abandoned{false};
    std::mutex m_taskMutex;
    std::condition_variable m_cv;
    std::deque<std::function<void()>> m_tasks;

    // registry：key = 规范化二进制路径（小写、canonical）。
    // weak_ptr 使最后一实例卸载后条目自然过期；static 声明为
    // inline 以与 Win32 版同生命周期语义（进程级）。
    inline static std::mutex s_registryMutex;
    inline static std::map<std::string, std::weak_ptr<ModulePumpThread>> s_registry;
};

} // namespace auradsp
