/* 平台端口：控制线程时间与自旋（CP-12，2026-11-01）。
 *
 * 背景：`plugins/driver/plugin_host_manager.cpp` 曾在 driver 层直接使用
 * `GetTickCount64` / `Sleep(1)` / `YieldProcessor`，违反 M2「Win32 调用收口到
 * platform/win32」的约定，也让 Linux/macOS 编译闭包多一个 `<windows.h>`。
 *
 * 本端口只提供标准库实现（无 OS 头）：
 *   - now_ms():    steady_clock 单调毫秒（对应 GetTickCount64 的墙钟语义）
 *   - sleep_ms():  std::this_thread::sleep_for
 *   - cpu_relax(): x86 pause / 其它架构编译器屏障
 *
 * 线程契约：仅限控制线程（卸载等待、扫描节流等）；严禁进入
 * auradsp_process 音频 RT 路径（RT 铁律：零系统调用）。
 */
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <thread>

#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <intrin.h>
#endif

namespace auradsp {
namespace platform {

/// 单调墙钟毫秒（进程内任意时刻均可用；不保证跨进程可比）。
inline uint64_t now_ms() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

/// 控制线程睡眠（ms）。0 表示仅让出时间片。
inline void sleep_ms(unsigned int ms) {
    if (ms == 0) {
        std::this_thread::yield();
        return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

/// CPU 自旋提示：让超线程/乱序核心降低争用，不产生系统调用。
inline void cpu_relax() noexcept {
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
    _mm_pause();
#elif (defined(__GNUC__) || defined(__clang__)) && \
    (defined(__x86_64__) || defined(__i386__))
    __builtin_ia32_pause();
#else
    std::atomic_signal_fence(std::memory_order_seq_cst);
#endif
}

} // namespace platform
} // namespace auradsp
