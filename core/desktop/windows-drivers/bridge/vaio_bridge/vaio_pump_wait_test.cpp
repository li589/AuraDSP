// vaio_pump_wait_test.cpp — D3 验收：VAIO 泵的节拍等待（不依赖任何驱动）。
//
// 背景：泵循环原本用 `Sleep(1)` / `Sleep(2)` 节流。Windows 的 Sleep 只保证
// "至少睡这么久"，实际唤醒粒度取决于系统定时器分辨率（默认 15.6ms），而这段
// WASAPI 缓冲只有 20ms —— 睡过头就是必然欠载。代码里写 1ms/2ms 极具误导性：
// 读代码完全看不出真实延迟。现改为 WASAPI 事件驱动（EVENTCALLBACK +
// SetEventHandle），等待带上界只为能定期回看 stopEvent。
//
// 计时口径（踩过的坑）：第一版用 GetTickCount64 量毫秒，结果是 15.0ms 这种
// 整刻度值 —— 它的分辨率本身就是 15.6ms，量不了亚毫秒；而且信号线程里的
// `Sleep(3)` 同样被量化到 15.6ms，被测的"3ms 后置位"根本没发生过。故：
//   · 全部计时走 QueryPerformanceCounter；
//   · 信号线程用 QPC 自旋到 3ms 再 SetEvent（不 Sleep）；
//   · 并列测一条 `Sleep(1)` 的真实耗时作为**同机基线**，断言事件唤醒显著
//     快于它 —— 这样结论不依赖具体机器的定时器分辨率。
//
// 输出：末行单行 JSON（smoke_d3_vaio_pump_wait.py 消费）。退出码 0 = 全过。
#include <windows.h>

#include <atomic>
#include <cstdio>
#include <thread>

#include "vaio_pump_wait.h"

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

LARGE_INTEGER g_freq;

double QpcMs() {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)g_freq.QuadPart;
}

/// 不睡的自旋等待（QPC 墙钟），用于让"信号在 3ms 后到"这件事真的成立。
void SpinUntilMs(double targetMs) {
    while (QpcMs() < targetMs) {
        ::SwitchToThread();
    }
}

/// 同机基线：Sleep(1) 的真实耗时。默认定时器分辨率下会是 ~15.6ms。
double MeasureSleepBaselineMs() {
    const double t0 = QpcMs();
    Sleep(1);
    return QpcMs() - t0;
}

/// ① 事件在信号时刻唤醒（不是按定时器粒度）。
void TestWakesOnSignal() {
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    Check(ev != nullptr, "CreateEventW ok");
    if (!ev) return;

    const double base = QpcMs();
    std::thread t([base, ev]() {
        SpinUntilMs(base + 3.0);
        SetEvent(ev);
    });
    const WaitOutcome r = WaitAudioPeriod(ev, 200);
    const double ms = QpcMs() - base;
    t.join();

    char note[200];
    std::snprintf(note, sizeof(note),
                  "wake latency after a 3ms signal = %.2fms (Sleep(1) baseline %.2fms)",
                  ms, MeasureSleepBaselineMs());
    Check(r == WaitOutcome::Signaled, "signaled outcome");
    // 3ms 置位 → 唤醒应在其后 1ms 内（QPC 实测 3.0-3.6ms）；给 6ms 容差
    // 只为覆盖调度抖动，仍远小于 15.6ms 粒度。
    Check(ms >= 2.9 && ms < 6.0, note);
    CloseHandle(ev);
}

/// ② 事件唤醒必须显著快于 Sleep(1)：这就是"回退成睡眠轮询"的判红点。
/// 若本机定时器已是 1ms 精度（基线 < 5ms），则该机器上 Sleep 缺陷本不成立，
/// 改用绝对阈值 6ms（事件唤醒仍是亚毫秒级）。
void TestFasterThanSleep() {
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!ev) return;
    // 先测基线（放在事件测试之前，避免受前面测例影响）
    const double sleepMs = MeasureSleepBaselineMs();

    const double base = QpcMs();
    std::thread t([base, ev]() {
        SpinUntilMs(base + 3.0);
        SetEvent(ev);
    });
    const WaitOutcome r = WaitAudioPeriod(ev, 200);
    const double wakeMs = QpcMs() - base;
    t.join();

    char note[220];
    std::snprintf(note, sizeof(note),
                  "event wake %.2fms vs Sleep(1) %.2fms (timer granularity on this host)",
                  wakeMs, sleepMs);
    if (sleepMs >= 5.0) {
        Check(wakeMs < sleepMs - 5.0, note);
    } else {
        Check(wakeMs < 6.0, note);
    }
    Check(r == WaitOutcome::Signaled, "signaled outcome (baseline case)");
    CloseHandle(ev);
}

/// ③ 无信号 → 按上界返回（不是卡死，也不是立刻空转）。
void TestTimesOutAtUpperBound() {
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!ev) return;
    const double t0 = QpcMs();
    const WaitOutcome r = WaitAudioPeriod(ev, 40);
    const double ms = QpcMs() - t0;
    char note[160];
    std::snprintf(note, sizeof(note),
                  "timeout wait = %.2fms (upper=40ms, timer granularity adds up to a tick)", ms);
    Check(r == WaitOutcome::TimedOut, "timed-out outcome");
    Check(ms >= 38.0 && ms < 100.0, note);
    CloseHandle(ev);
}

/// ④ 句柄缺失 → NoEvent，且立即返回（不许死等）。
void TestMissingEventHandle() {
    const double t0 = QpcMs();
    const WaitOutcome r = WaitAudioPeriod(nullptr, 200);
    const double ms = QpcMs() - t0;
    Check(r == WaitOutcome::NoEvent, "null handle -> NoEvent");
    Check(ms < 1.0, "null handle returns immediately");
    Check(WaitAudioPeriod(INVALID_HANDLE_VALUE, 200) == WaitOutcome::NoEvent,
          "INVALID_HANDLE_VALUE -> NoEvent");
}

/// ⑤ auto-reset 语义：每次 SetEvent 只唤醒一次等待（泵能按周期推进）。
void TestPerPeriodSignaling() {
    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!ev) return;
    SetEvent(ev);
    const WaitOutcome a = WaitAudioPeriod(ev, 200);
    const WaitOutcome b = WaitAudioPeriod(ev, 20);
    SetEvent(ev);
    const WaitOutcome c = WaitAudioPeriod(ev, 200);
    Check(a == WaitOutcome::Signaled, "first wait consumes the signal");
    Check(b == WaitOutcome::TimedOut, "auto-reset: second wait finds nothing (no stale spin)");
    Check(c == WaitOutcome::Signaled, "next period signal wakes again");
    CloseHandle(ev);
}

/// ⑥ 上界常量必须远小于"设备死掉后必须被发现的"量级。
void TestUpperBoundConstant() {
    char note[128];
    std::snprintf(note, sizeof(note), "kAudioWaitUpperMs = %lu (want 10..200)",
                  (unsigned long)kAudioWaitUpperMs);
    Check(kAudioWaitUpperMs >= 10 && kAudioWaitUpperMs <= 200, note);
}

}  // namespace

int main() {
    QueryPerformanceFrequency(&g_freq);
    std::printf("=== D3 VAIO pump wait (event-driven, bounded) ===\n");
    std::printf("info Sleep(1) real duration on this host = %.2fms\n", MeasureSleepBaselineMs());
    TestWakesOnSignal();
    TestFasterThanSleep();
    TestTimesOutAtUpperBound();
    TestMissingEventHandle();
    TestPerPeriodSignaling();
    TestUpperBoundConstant();

    const int fail = g_fail.load(), pass = g_pass.load();
    std::printf("\n{\"pass\":%d,\"fail\":%d,\"ok\":%s}\n", pass, fail, fail == 0 ? "true" : "false");
    return fail == 0 ? 0 : 1;
}
