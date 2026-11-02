/* 平台端口 Linux 实现：UTF-8 路径 fopen（M1 平台隔离，2026-10-29 契约；
 * S2 Linux 落地，2026-11-01）。
 * glibc 按字节传递路径，Linux 文件名本身即 UTF-8 字节串，无需 Windows
 * 侧的 UTF-8 → UTF-16 转码，直接 fopen 直通（契约见
 * engine/platform/linux/README.md）。
 * 错误语义与 fs_win.cpp 逐项对齐：路径/模式非法 → invalid_path；
 * 打开失败 → open_failed。invalid_encoding / out_of_memory 在直通实现
 * 下不会出现（无转码、无内部缓冲）。 */
#include "platform/port/fs.h"

#ifdef _WIN32
#error "fs_linux.cpp 仅用于非 Windows 构建"
#endif

namespace auradsp {
namespace platform {

namespace {
void set_err(FsOpenError* out, FsOpenError v) {
    if (out) *out = v;
}
} // namespace

FILE* fopen_utf8(const char* utf8_path, const char* mode, FsOpenError* err) {
    set_err(err, FsOpenError::none);
    if (!utf8_path || !utf8_path[0] || !mode) {
        set_err(err, FsOpenError::invalid_path);
        return nullptr;
    }

    FILE* fp = fopen(utf8_path, mode);
    if (!fp) set_err(err, FsOpenError::open_failed);
    return fp;
}

} // namespace platform
} // namespace auradsp
