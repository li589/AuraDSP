// vaio_pump_wait.h — D3：VAIO 泵线程的节拍等待策略（设备无关，可单测）。
//
// 背景（审查 D3）：泵循环用 `Sleep(1)` / `Sleep(2)` 做节流。Windows 的 Sleep
// 只保证"至少睡这么久"，实际调度粒度取决于系统定时器分辨率——未抬
// timeBeginPeriod 时是 1~15.6ms。而这段 WASAPI 缓冲只有 20ms：
//   · 睡过头 → 缓冲被播放引擎抽空 → 必然欠载（爆音/断续）；
//   · 代码里写的是 1ms、2ms，读代码的人会以为节拍很细 —— 这才是最坏的地方：
//     睡眠时间与真实唤醒延迟之间没有任何关系，读代码看不出来。
//
// 正解是让 WASAPI 自己驱动节拍：`Initialize` 时带
// AUDCLNT_STREAMFLAGS_EVENTCALLBACK + `SetEventHandle`，播放引擎每消费完一个
// 周期就把事件置位，泵线程按事件唤醒 —— 唤醒延迟由音频引擎保证（微秒级），
// 不依赖系统定时器。
//
// 等待仍必须带**上界**：设备失效（DEVICE_INVALIDATED）后事件永不再来，
// 无上界的等待就是永久卡死，stopEvent 也永远看不到。上界不是"预期会超时"，
// 而是"至少要定期回看停止标志"。
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace vmcore {

/// 等待上界（毫秒）。正常运行时每个 WASAPI 周期都会有信号，远小于它；
/// 这个值只决定"设备死掉后多久能发现 stopEvent"。
constexpr DWORD kAudioWaitUpperMs = 50;

enum class WaitOutcome {
    Signaled,  // 有信号：播放引擎已消费一个周期，可以继续填
    TimedOut,  // 上界到：回去查 stopEvent / 重新取 padding
    NoEvent,   // 事件句柄缺失（只可能出现在启动失败路径）
};

/// 等下一周期。TimedOut 与 WAIT_FAILED 同一处理（不区分：两者都只表示
/// "这次没拿到节拍"，循环回去重新判断即可）。
inline WaitOutcome WaitAudioPeriod(HANDLE hEvent, DWORD upperMs = kAudioWaitUpperMs) {
    if (hEvent == nullptr || hEvent == INVALID_HANDLE_VALUE) {
        return WaitOutcome::NoEvent;
    }
    const DWORD r = WaitForSingleObject(hEvent, upperMs);
    return (r == WAIT_OBJECT_0) ? WaitOutcome::Signaled : WaitOutcome::TimedOut;
}

}  // namespace vmcore
