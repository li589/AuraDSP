/* 平台端口 Windows 实现：UTF-8 路径 fopen（M1 平台隔离，2026-10-29）。
 * 逐字保留原 read_text_file / read_bin_file 的 R-1 逻辑：UTF-8 → UTF-16
 * 后 _wfopen，避免 ANSI 代码页导致 CJK 路径失败。
 * R2（2026-10-30）：各失败分支经 FsOpenError 回传原因（转码失败 / OOM /
 * 打开失败），供调用方区分 E_PARAM 与 E_IO。 */
#include "platform/port/fs.h"

#ifndef _WIN32
#error "fs_win.cpp 仅用于 Windows 构建"
#endif

#include <windows.h>

#include <cstdlib>

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

    const int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, nullptr, 0);
    if (wlen <= 0) {
        set_err(err, FsOpenError::invalid_encoding);
        return nullptr;
    }
    wchar_t* wpath = (wchar_t*)malloc((size_t)wlen * sizeof(wchar_t));
    if (!wpath) {
        set_err(err, FsOpenError::out_of_memory);
        return nullptr;
    }
    MultiByteToWideChar(CP_UTF8, 0, utf8_path, -1, wpath, wlen);

    wchar_t wmode[8] = {};
    if (MultiByteToWideChar(CP_UTF8, 0, mode, -1, wmode, 8) <= 0) {
        free(wpath);
        set_err(err, FsOpenError::invalid_encoding);
        return nullptr;
    }

    FILE* fp = _wfopen(wpath, wmode);
    free(wpath);
    if (!fp) set_err(err, FsOpenError::open_failed);
    return fp;
}

} // namespace platform
} // namespace auradsp
