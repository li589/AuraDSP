/* 平台端口 Windows 实现：环境变量读取（M1 平台隔离，2026-10-29）。
 * 用 Win32 API 而非 getenv，避开 MSVC C4996（与 P2 静音门控原实现一致）。 */
#include "platform/port/env.h"

#ifndef _WIN32
#error "env_win.cpp 仅用于 Windows 构建"
#endif

#include <windows.h>

namespace auradsp {
namespace platform {

bool get_env(const char* name, char* buf, size_t cap) {
    if (!buf || cap == 0) return false;
    buf[0] = '\0';
    if (!name || !name[0]) return false;
    const DWORD n = GetEnvironmentVariableA(name, buf, (DWORD)cap);
    return n > 0 && n < cap;
}

} // namespace platform
} // namespace auradsp
