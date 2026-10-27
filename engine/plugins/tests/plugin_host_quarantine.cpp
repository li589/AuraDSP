// plugin_host_quarantine.cpp — B3 验收：RT 异常滞留时卸载必须「保留实例」。
//
// 背景（审查 B3，P1）：unload/detach 的"强制排空安全兜底"把 inFlight 硬清零
// 后照常 closeEditor/deactivate/unload + 析构实例。若 RT 真的在途（计数非零
// 的原始原因），那是对在途实例的 use-after-free，与 inflight_guard.h 的契约
// （"超过上限视为 RT 异常滞留，此时选择保留实例而不是冒险释放"）正好相反。
// 且原等待谓词 inFlight.wait(0) 语义写错（atomic::wait 只在"值 == old"时阻塞，
// 而这里值恒非零）= 立即返回的几十 µs 空转，正常在途块必然超限。
//
// 注入：假实例 process() 在事件上阻塞（模拟插件死锁在音频线程内）。
// 断言：
//   1) 卸载按墙钟上界返回（约 kQuiesceWaitMs，不永久挂控制线程；换成原来的
//      立即返回实现则 <5ms —— 反向验证判据之一）；
//   2) 实例未被析构、也未被 closeEditor/deactivate/unload（保留实例契约；
//      反向验证：还原"硬清零后照常销毁"时 dtor 在 process 未返回时就跑到）；
//   3) 槽计数清零，滞留线程返回后不下溢（仍为 0）；
//   4) 槽未被毒化：紧接着装卸新实例走正常销毁路径（dtor 计数 +1）。
//
// 输出：末行单行 JSON；退出码 0 = 全过。
#include <windows.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

#include "plugin_host.h"

using namespace auradsp;

namespace {

std::atomic<int> g_dtorCount{0};
std::atomic<int> g_destroyedWhileInside{0};

// 假实例：gate 非空时 process() 阻塞到事件（10s 兜底自愈，防测试自身挂死）。
class FakeInstance : public IPluginInstance {
public:
    explicit FakeInstance(HANDLE gate) : m_gate(gate) {}
    ~FakeInstance() override {
        if (m_inside.load()) g_destroyedWhileInside.fetch_add(1);
        g_dtorCount.fetch_add(1);
    }
    bool load(const std::string&, const std::string&, const PluginMetadata*) override {
        return true;
    }
    void unload() override { ++m_unloads; }
    bool activate(double, uint32_t) override { return true; }
    void deactivate() override { ++m_deactivates; }
    void process(float* const*, float* const*, uint32_t) override {
        m_inside.store(true);
        if (m_gate) WaitForSingleObject(m_gate, 10000);
        m_inside.store(false);
    }
    bool isLoaded() const override { return true; }
    bool isBypassed() const override { return false; }
    void setBypass(bool) override {}
    uint32_t getLatency() const override { return 0; }
    const PluginMetadata& getMetadata() const override { return m_meta; }
    bool showEditor(const std::string&) override { return false; }
    void closeEditor() override { ++m_closes; }
    bool isEditorOpen() const override { return false; }
    bool savePreset(const std::string&) override { return false; }
    bool loadPreset(const std::string&) override { return false; }

    bool Inside() const { return m_inside.load(); }
    int Closes() const { return m_closes; }
    int Unloads() const { return m_unloads; }
    int Deactivates() const { return m_deactivates; }

private:
    HANDLE m_gate = nullptr;
    PluginMetadata m_meta;
    std::atomic<bool> m_inside{false};
    int m_closes = 0;
    int m_unloads = 0;
    int m_deactivates = 0;
};

struct Fail {
    bool ok = true;
    std::string why;
    void Check(bool cond, const char* what) {
        if (!cond && ok) {
            ok = false;
            why = what;
        }
    }
};

}  // namespace

int main() {
    Fail f;
    HANDLE gate = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!gate) {
        printf("{\"ok\":false,\"note\":\"CreateEventW failed\"}\n");
        return 1;
    }
    PluginHostManager mgr;

    // ---- 场景 1：RT 滞留 —— 卸载必须隔离而不是销毁 ----
    auto* fake = new FakeInstance(gate);
    mgr.m_slots[0].instance.reset(fake);
    mgr.m_slots[0].hasActive.store(true, std::memory_order_release);

    std::thread rt([&mgr] {
        float inL[128] = {0}, inR[128] = {0}, outL[128] = {0}, outR[128] = {0};
        float* in[2] = {inL, inR};
        float* out[2] = {outL, outR};
        mgr.processSlot(0, in, out, 128);  // 进入 process() 后滞留
    });
    // 等 RT 真正进入临界区并阻塞在 process 内（inFlight==1 且 inside）
    for (int i = 0; i < 3000; ++i) {
        if (mgr.m_slots[0].inFlight.load() != 0 && fake->Inside()) break;
        Sleep(1);
    }
    f.Check(mgr.m_slots[0].inFlight.load() != 0, "rt never entered critical section");
    f.Check(fake->Inside(), "rt never blocked inside process");

    const ULONGLONG tUnload = GetTickCount64();
    mgr.unloadPluginSlot(0);  // 控制线程角色
    const ULONGLONG unloadMs = GetTickCount64() - tUnload;

    const auto dtor1 = g_dtorCount.load();
    const auto destroyedInside = g_destroyedWhileInside.load();
    const auto slotInFlight1 = mgr.m_slots[0].inFlight.load();
    const bool slotCleared = (mgr.m_slots[0].instance == nullptr);
    const int calls = fake->Closes() + fake->Unloads() + fake->Deactivates();

    // 1) 有界等待：既不能立即返回（原 wait(0) 缺陷），也不能永久挂住
    f.Check(unloadMs >= 50, "unload returned too fast (quiesce wait not effective)");
    f.Check(unloadMs <= 2000, "unload blocked too long");
    // 2) 保留实例契约：不析构、不调实例方法
    f.Check(slotCleared, "slot instance not detached");
    f.Check(dtor1 == 0, "instance destroyed while RT still inside process");
    f.Check(destroyedInside == 0, "destructor ran inside process (use-after-free)");
    f.Check(calls == 0, "instance methods called on a stuck instance");
    // 3) 计数清零（滞留线程晚些退出不得下溢）
    f.Check(slotInFlight1 == 0, "inFlight not cleared after quarantine");

    // 放行滞留线程：其 InFlightGuard 析构必须饱和递减（0 不变，不下溢）
    SetEvent(gate);
    rt.join();
    Sleep(20);
    const auto slotInFlight2 = mgr.m_slots[0].inFlight.load();
    f.Check(slotInFlight2 == 0, "inFlight underflowed after straggler exit");

    // ---- 场景 2：正常路径（无在途）必须照常销毁 ----
    auto* fake2 = new FakeInstance(nullptr);
    mgr.m_slots[0].instance.reset(fake2);
    mgr.m_slots[0].hasActive.store(true, std::memory_order_release);
    mgr.unloadPluginSlot(0);
    const auto dtor2 = g_dtorCount.load();
    f.Check(dtor2 == 1, "quiesced unload did not destroy instance");
    f.Check(fake2->Closes() == 1 && fake2->Unloads() == 1 && fake2->Deactivates() == 1,
            "quiesced unload did not run teardown calls");

    CloseHandle(gate);
    printf("{\"ok\":%s,\"unloadMs\":%llu,\"dtorStuck\":%d,"
           "\"destroyedWhileInside\":%d,\"slotInFlightAfterStuck\":%d,"
           "\"stuckInstanceCalls\":%d,\"inFlightAfterStraggler\":%d,"
           "\"normalDtor\":%d,\"note\":\"%s\"}\n",
           f.ok ? "true" : "false", (unsigned long long)unloadMs, (int)dtor1,
           (int)destroyedInside, (int)slotInFlight1, calls,
           (int)slotInFlight2, (int)dtor2, f.why.c_str());
    return f.ok ? 0 : 1;
}
