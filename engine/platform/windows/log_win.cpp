/* 平台端口 Windows 实现：宿主调试日志（M1 平台隔离，2026-10-29）。
 * 级别缓存与格式 "[AuraDSP][file:line] msg\n" 逐字保留原 debug_log.h 行为；
 * 输出通道 OutputDebugStringA（GUI 进程内无控制台也可靠）。 */
#include "platform/port/log.h"

#ifndef _WIN32
#error "log_win.cpp 仅用于 Windows 构建"
#endif

#include <windows.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>

namespace auradsp {
namespace platform {
namespace {

std::atomic<int>& cached_level() {
    static std::atomic<int> lvl{-1};
    return lvl;
}

} // namespace

int log_level() {
    int v = cached_level().load(std::memory_order_relaxed);
    if (v < 0) {
        char buf[8] = {};
        const DWORD n = GetEnvironmentVariableA("AURADSP_LOG", buf, (DWORD)sizeof(buf));
        v = 2; // 默认全量（编译期已选择开启，默认应可见）
        if (n > 0 && n < (DWORD)sizeof(buf)) {
            v = atoi(buf);
            if (v < 0) v = 0;
            if (v > 2) v = 2;
        }
        cached_level().store(v, std::memory_order_relaxed);
    }
    return v;
}

void log_emit(int min_level, const char* file, int line, const char* msg) {
    if (log_level() < min_level) return;
    const char* base = file ? file : "";
    for (const char* p = base; *p; ++p)
        if (*p == '\\' || *p == '/') base = p + 1;
    char out[640];
    snprintf(out, sizeof(out), "[AuraDSP][%s:%d] %s\n", base, line, msg ? msg : "");
    OutputDebugStringA(out);
}

} // namespace platform
} // namespace auradsp
