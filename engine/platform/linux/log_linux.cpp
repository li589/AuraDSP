/* 平台端口 Linux 实现：宿主调试日志（M1 平台隔离，2026-10-29 契约；
 * S2 Linux 落地，2026-11-01）。
 * 与 log_win.cpp 同构：级别经 AURADSP_LOG 首次读取后粘性缓存，默认 2
 * （全量），钳位 0–2；输出格式 "[AuraDSP][file:line] msg\n" 逐字保留，
 * file 取基名（'/' 与 '\\' 均作分隔符，与 Windows 版一致）。
 * 输出通道由 OutputDebugStringA 改为 stderr（Linux 契约，见
 * engine/platform/linux/README.md）。 */
#include "platform/port/log.h"

#ifdef _WIN32
#error "log_linux.cpp 仅用于非 Windows 构建"
#endif

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
        v = 2; // 默认全量（编译期已选择开启，默认应可见）
        const char* e = getenv("AURADSP_LOG");
        if (e && e[0]) {
            v = atoi(e);
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
    fputs(out, stderr);
}

} // namespace platform
} // namespace auradsp
