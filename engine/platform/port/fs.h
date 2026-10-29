/* 平台端口：UTF-8 路径文件打开（M1 平台隔离，2026-10-29）。
 *
 * 控制线程专用：fopen/_wfopen 非 RT-safe，严禁进入 auradsp_process 调用图。
 * Windows 实现内部 UTF-8 → UTF-16 后走 _wfopen（CJK 路径，R-1 修复同源）；
 * 其他平台实现可直接 fopen。调用方负责 fclose。 */
#pragma once

#include <cstdio>

namespace auradsp {
namespace platform {

FILE* fopen_utf8(const char* utf8_path, const char* mode);

} // namespace platform
} // namespace auradsp
