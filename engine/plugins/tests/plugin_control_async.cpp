#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <functional>
#include <initializer_list>
#include <mutex>
#include <string>
#include <thread>

#include "plugin_host.h"

using namespace auradsp;

namespace {

class Gate {
public:
    void EnterAndWait() {
        std::unique_lock<std::mutex> lock(mutex);
        entered = true;
        cv.notify_all();
        cv.wait_for(lock, std::chrono::seconds(5), [this] { return released; });
    }

    bool WaitEntered() {
        std::unique_lock<std::mutex> lock(mutex);
        return cv.wait_for(lock, std::chrono::seconds(1), [this] { return entered; });
    }

    void Release() {
        std::lock_guard<std::mutex> lock(mutex);
        released = true;
        cv.notify_all();
    }

private:
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
    bool released = false;
};

class BlockingInstance : public IPluginInstance {
public:
    BlockingInstance(Gate* bypass, Gate* hint, Gate* secondBypass = nullptr)
        : m_bypass(bypass), m_hint(hint), m_secondBypass(secondBypass) {}

    bool load(const std::string&, const std::string&, const PluginMetadata*) override { return true; }
    void unload() override {}
    bool activate(double, uint32_t) override { return true; }
    void deactivate() override {}
    void process(float* const*, float* const*, uint32_t) override {}
    bool isLoaded() const override { return true; }
    bool isBypassed() const override { return false; }
    void setBypass(bool) override {
        const int call = m_bypassCalls.fetch_add(1, std::memory_order_relaxed);
        Gate* gate = call == 0 ? m_bypass : (call == 1 ? m_secondBypass : nullptr);
        if (gate) gate->EnterAndWait();
    }
    uint32_t getLatency() const override { return 0; }
    const PluginMetadata& getMetadata() const override { return m_meta; }
    void setChannelHint(int) override {
        if (m_hint) m_hint->EnterAndWait();
    }
    bool showEditor(const std::string&) override { return false; }
    void closeEditor() override {}
    bool isEditorOpen() const override { return false; }
    bool savePreset(const std::string&) override { return false; }
    bool loadPreset(const std::string&) override { return false; }

private:
    Gate* m_bypass;
    Gate* m_hint;
    Gate* m_secondBypass;
    std::atomic<int> m_bypassCalls{0};
    PluginMetadata m_meta;
};

bool WaitTrue(const std::atomic<bool>& flag) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    while (!flag.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < deadline)
        std::this_thread::yield();
    return flag.load(std::memory_order_acquire);
}

bool ReturnsQuickly(const std::function<void()>& call, Gate* release) {
    std::atomic<bool> returned{false};
    std::thread worker([&] {
        call();
        returned.store(true, std::memory_order_release);
    });
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    while (!returned.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < deadline)
        std::this_thread::yield();
    const bool quick = returned.load(std::memory_order_acquire);
    if (!quick) release->Release();
    worker.join();
    return quick;
}

int RunBypass() {
    Gate gate;
    PluginHostManager manager;
    manager.m_slots[0].instance = std::make_unique<BlockingInstance>(&gate, nullptr);
    manager.m_slots[0].hasActive.store(true, std::memory_order_release);

    std::atomic<bool> firstReturned{false};
    std::thread first([&] {
        manager.setBypassSlot(0, false);
        firstReturned.store(true, std::memory_order_release);
    });
    const bool entered = gate.WaitEntered();
    const bool quick = entered && WaitTrue(firstReturned) &&
                       ReturnsQuickly([&] { manager.setBypassSlot(0, true); }, &gate);
    const bool published = manager.isBypassedSlot(0);
    gate.Release();
    first.join();
    if (!quick || !published) {
        std::fprintf(stderr, "FAIL: bypass publication blocked behind plugin call\n");
        return 1;
    }
    puts("plugin bypass publication: nonblocking");
    return 0;
}

int RunStatus() {
    Gate gate;
    PluginHostManager manager;
    manager.m_slots[0].instance = std::make_unique<BlockingInstance>(&gate, nullptr);
    manager.m_slots[0].hasActive.store(true, std::memory_order_release);
    const std::string primed = manager.getStatusJsonSlot(0);

    std::thread first([&] { manager.setBypassSlot(0, false); });
    const bool entered = gate.WaitEntered();
    std::string status;
    const bool quick = entered && ReturnsQuickly([&] { status = manager.getStatusJsonSlot(0); }, &gate);
    const bool retained = status.find("\"slot\":0") != std::string::npos;
    gate.Release();
    first.join();
    if (!quick || !retained || primed.find("\"slot\":0") == std::string::npos) {
        std::fprintf(stderr, "FAIL: status polling blocked or lost cached state\n");
        return 1;
    }
    puts("plugin status polling: nonblocking cached snapshot");
    return 0;
}

int RunChannelHint() {
    Gate gate;
    PluginHostManager manager;
    manager.m_slots[0].instance = std::make_unique<BlockingInstance>(nullptr, &gate);
    manager.m_slots[0].hasActive.store(true, std::memory_order_release);
    manager.m_slots[0].bypassReady.store(true, std::memory_order_release);

    std::atomic<bool> firstReturned{false};
    std::thread first([&] {
        manager.setChannelHint(8);
        firstReturned.store(true, std::memory_order_release);
    });
    const bool entered = gate.WaitEntered();
    const bool published = manager.getChannelHint() == 8;
    const bool gated = manager.isBypassedSlot(0);
    const bool quick = entered && WaitTrue(firstReturned) &&
                       ReturnsQuickly([&] { manager.setChannelHint(6); }, &gate);
    gate.Release();
    first.join();
    if (!quick || !published || !gated || manager.getChannelHint() != 6) {
        std::fprintf(stderr, "FAIL: channel-hint publication blocked behind plugin call\n");
        return 1;
    }
    puts("plugin channel-hint publication: nonblocking");
    return 0;
}

int RunReuse() {
    PluginHostManager manager;
    for (int terminal : {2, 3}) {
        manager.m_slots[0].taskState.store(terminal, std::memory_order_release);
        PluginHostManager::ControlTask task;
        task.slot = 0;
        task.type = PluginHostManager::ControlTask::Type::Unload;
        if (!manager.submitTaskLocked(std::move(task))) {
            std::fprintf(stderr, "FAIL: terminal task state %d rejected slot reuse\n", terminal);
            return 1;
        }
    }
    puts("plugin task terminal states: slot reuse accepted");
    return 0;
}

int RunFallbackStatus() {
    PluginHostManager manager;
    manager.m_slots[0].instance = std::make_unique<BlockingInstance>(nullptr, nullptr);
    manager.m_slots[0].hasActive.store(true, std::memory_order_release);
    std::string status;
    Gate held;
    std::thread holder([&] {
        std::lock_guard<std::recursive_mutex> lock(manager.m_hostMutex);
        held.EnterAndWait();
    });
    const bool lockHeld = held.WaitEntered();
    if (lockHeld) status = manager.getStatusJsonSlot(0);
    held.Release();
    holder.join();
    if (status.find("\"hasActive\":") == std::string::npos ||
        status.find("\"plugin\":") == std::string::npos) {
        std::fprintf(stderr, "FAIL: empty-cache status fallback is not valid JSON contract\n");
        return 1;
    }
    puts("plugin status fallback: valid atomic snapshot");
    return 0;
}

int RunBypassGeneration() {
    Gate first;
    Gate second;
    PluginHostManager manager;
    manager.m_slots[0].instance = std::make_unique<BlockingInstance>(&first, nullptr, &second);
    manager.m_slots[0].hasActive.store(true, std::memory_order_release);
    manager.setBypassSlot(0, true);
    const bool firstEntered = first.WaitEntered();
    manager.setBypassSlot(0, false);
    first.Release();
    const bool secondEntered = second.WaitEntered();
    const bool ready = manager.m_slots[0].bypassReady.load(std::memory_order_acquire);
    second.Release();
    if (!firstEntered || !secondEntered || ready) {
        std::fprintf(stderr, "FAIL: stale bypass worker published readiness for newer request\n");
        return 1;
    }
    puts("plugin bypass generation: stale completion cannot publish readiness");
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    const char* mode = (argc > 1) ? argv[1] : "bypass";
    if (strcmp(mode, "status") == 0) return RunStatus();
    if (strcmp(mode, "hint") == 0) return RunChannelHint();
    if (strcmp(mode, "reuse") == 0) return RunReuse();
    if (strcmp(mode, "fallback") == 0) return RunFallbackStatus();
    if (strcmp(mode, "generation") == 0) return RunBypassGeneration();
    return RunBypass();
}
