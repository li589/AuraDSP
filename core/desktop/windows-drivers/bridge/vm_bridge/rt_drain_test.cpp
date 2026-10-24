// rt_drain_test.cpp — D2 验收：RT 在途守卫 + 确定性排空（不依赖任何驱动）。
//
// 背景：三个桥的「释放前等在途 RT 退出」原本有三种写法——VmBridge 是
// `for (i<3000) Sleep(1)`（名义 3s，实际因 Sleep(1) 粒度 5-15ms 可达
// 15-45s），ASIO/VAIO 是 `Sleep(50)`（纯猜测：重载时不够 → free 掉 RT 仍在
// 读的缓冲 = UAF；空闲时白等 50ms）。现统一为 RtInBlockGuard（RAII 保证
// 成对增减）+ WaitRtDrained（GetTickCount64 墙钟上界）。
//
// 本测试只打 helper 层（驱动无关，CI 可跑），验证四件事：
//   ① Guard 成对性——含多条提前 return 的路径，计数归零（漏增/漏减都会
//      让排空等待失效：漏增→立即通过，漏减→必然超时）；
//   ② Guard 可嵌套（计数语义，不是布尔位）；
//   ③ WaitRtDrained 的三种结局——已归零立即返回 / 稍后归零则等待返回 true /
//      永不归零则按墙钟上界返回 false；
//   ④ 模拟「RT 每块进出 + 主线程排空」：停止信号后必须在远小于 50ms 内返回
//      （这正是 Sleep(50) 做不到的——它总是固定睡满）。
//
// 输出：末行单行 JSON（smoke_d2_rt_drain.py 消费）。退出码 0 = 全过。
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <thread>

#include "../../02_voicemeeter_client/VmPumpCore.h"

using namespace vmcore;

namespace {

std::atomic<int> g_fail{0};
std::atomic<int> g_pass{0};

void Check(bool ok, const char* what) {
    if (ok) {
        ++g_pass;
        std::printf("ok   %s\n", what);
    } else {
        ++g_fail;
        std::printf("FAIL %s\n", what);
    }
}

/// 毫秒级单调计时（与 WaitRtDrained 同源时钟，避免跨时钟域噪声）。
double ElapsedMs(ULONGLONG t0) {
    return (double)(GetTickCount64() - t0);
}

/// 用 QPC 自旋模拟一块 DSP 的耗时。刻意不用 Sleep(2)：默认 timer resolution
/// 下 Sleep(2) 实际是 15.6ms，模拟出来的"块"比真实块长一个数量级，排空延迟
/// 与块数都会被这个假粒度主导。
void SpinMs(double ms) {
    LARGE_INTEGER f, t0, t;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    const double target = ms * 0.001 * (double)f.QuadPart;
    do {
        QueryPerformanceCounter(&t);
    } while ((double)(t.QuadPart - t0.QuadPart) < target);
}

// ① 三条提前 return 路径各持有 guard，返回后计数必须归零。
// 这是真实现场形态：BridgeSink 有 frames<=0 / userBypass / 无引擎三条 return。
int FakeSinkPath(int kind, volatile LONG* c) {
    {
        RtInBlockGuard inBlock(c);
        if (kind == 0) return 0;  // 无块
        if (kind == 1) return 1;  // 用户旁路
        // 正常路径
    }
    return 2;
}

void TestGuardPairs() {
    volatile LONG c = 0;
    for (int k = 0; k < 3; ++k) {
        LONG peak = 0;
        {
            RtInBlockGuard g(&c);
            peak = InterlockedCompareExchange(&c, 0, 0);
        }
        char note[96];
        std::snprintf(note, sizeof(note), "guard raises count inside (path %d, peak=%ld)", k,
                      (long)peak);
        Check(peak == 1 && InterlockedCompareExchange(&c, 0, 0) == 0, note);
    }
    // 三条 return 路径：每次调用后计数必须回零
    bool allZero = true;
    for (int k = 0; k < 3; ++k) {
        FakeSinkPath(k, &c);
        if (InterlockedCompareExchange(&c, 0, 0) != 0) allZero = false;
    }
    Check(allZero, "early-return paths leave counter at zero");

    // ② 嵌套 = 计数语义（1 → 2 → 1 → 0），不是布尔位
    LONG s1 = 0, s2 = 0, s3 = 0, s4 = 0;
    {
        RtInBlockGuard a(&c);
        s1 = InterlockedCompareExchange(&c, 0, 0);
        {
            RtInBlockGuard b(&c);
            s2 = InterlockedCompareExchange(&c, 0, 0);
        }
        s3 = InterlockedCompareExchange(&c, 0, 0);
    }
    s4 = InterlockedCompareExchange(&c, 0, 0);
    Check(s1 == 1 && s2 == 2 && s3 == 1 && s4 == 0, "nested guards count 1-2-1-0");
}

void TestWaitAlreadyDrained() {
    volatile LONG c = 0;
    const ULONGLONG t0 = GetTickCount64();
    const bool ok = WaitRtDrained(&c, 3000);
    const double ms = ElapsedMs(t0);
    char note[96];
    std::snprintf(note, sizeof(note), "already drained returns immediately (%.1fms)", ms);
    Check(ok && ms < 15.0, note);  // 15ms 容忍调度抖动，但远小于 50ms
}

void TestWaitThenDrain() {
    volatile LONG c = 1;
    const ULONGLONG t0 = GetTickCount64();
    std::thread releaser([&c]() {
        Sleep(120);
        InterlockedExchange(&c, 0);
    });
    const bool ok = WaitRtDrained(&c, 3000);
    const double ms = ElapsedMs(t0);
    releaser.join();
    char note[128];
    std::snprintf(note, sizeof(note), "waits until released, not fixed sleep (%.1fms, want 120~700)",
                  ms);
    Check(ok && ms >= 100.0 && ms <= 700.0, note);
}

void TestWaitTimeout() {
    volatile LONG c = 1;  // 永不归零（模拟 RT 卡死）
    const ULONGLONG t0 = GetTickCount64();
    const bool ok = WaitRtDrained(&c, 100);
    const double ms = ElapsedMs(t0);
    char note[128];
    std::snprintf(note, sizeof(note), "bounded by wall clock on stuck RT (%.1fms, want 100~600)",
                  ms);
    // 下限 100（maxMs）；上限 600 容忍 Sleep 粒度 + 调度，证明不是无限等待
    Check(!ok && ms >= 90.0 && ms <= 600.0, note);
}

// ④ 端到端：RT 每 ~2ms 进出一次块，主线程置 stop 后应当只等「当前块跑完」，
// 也就是几毫秒级返回；Sleep(50) 则无论如何都睡满 50ms。
void TestDrainLatency() {
    volatile LONG inBlock = 0;
    volatile LONG stop = 0;
    std::atomic<int> blocks{0};

    std::thread rt([&]() {
        while (!InterlockedCompareExchange(&stop, 0, 0)) {
            {
                RtInBlockGuard g(&inBlock);
                SpinMs(2.0);  // 模拟一块 DSP（2ms 纯计算，非睡眠）
            }
            ++blocks;
        }
    });
    Sleep(30);  // 让 RT 先跑起来（确保排空时确有可能在途）
    const ULONGLONG t0 = GetTickCount64();
    InterlockedExchange(&stop, 1);
    const bool ok = WaitRtDrained(&inBlock, 3000);
    const double ms = ElapsedMs(t0);
    rt.join();
    char note[160];
    std::snprintf(note, sizeof(note),
                  "drain latency after stop signal %.1fms (want <50, blocks=%d)", ms,
                  blocks.load());
    // 关键断言：< 50ms —— 若实现回退成 Sleep(50)，这里必然 ≥50ms 而判红
    Check(ok && ms < 50.0, note);
    Check(blocks.load() >= 5, "RT thread actually ran blocks before stop");
}

}  // namespace

int main() {
    std::printf("=== D2 RT in-block guard / deterministic drain ===\n");
    TestGuardPairs();
    TestWaitAlreadyDrained();
    TestWaitThenDrain();
    TestWaitTimeout();
    TestDrainLatency();

    const int fail = g_fail.load(), pass = g_pass.load();
    std::printf("\n{\"pass\":%d,\"fail\":%d,\"ok\":%s}\n", pass, fail, fail == 0 ? "true" : "false");
    return fail == 0 ? 0 : 1;
}
