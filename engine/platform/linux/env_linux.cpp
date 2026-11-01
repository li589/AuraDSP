/* 平台端口 Linux 实现：环境变量读取（M1 平台隔离，2026-10-29 契约；
 * S2 Linux 落地，2026-11-01）。
 * 语义与 env_win.cpp 逐项对齐：未设置、空值或值（含 NUL）放不进 buf
 * 时返回 false；无论成败 buf 恒以 NUL 结尾（buf 为空指针 / cap 为 0
 * 时直接返回 false，不写 buf）。 */
#include "platform/port/env.h"

#ifdef _WIN32
#error "env_linux.cpp 仅用于非 Windows 构建"
#endif

#include <cstdlib>
#include <cstring>

namespace auradsp {
namespace platform {

bool get_env(const char* name, char* buf, size_t cap) {
    if (!buf || cap == 0) return false;
    buf[0] = '\0';
    if (!name || !name[0]) return false;

    const char* v = getenv(name);
    if (!v) return false;
    const size_t n = strlen(v);
    if (n == 0 || n >= cap) return false;
    memcpy(buf, v, n + 1);
    return true;
}

} // namespace platform
} // namespace auradsp
