/* 平台端口：环境变量读取（M1 平台隔离，2026-10-29）。
 *
 * 控制线程专用（create 初始化一次性调用），不进 RT 路径。
 * 返回 false = 未设置或写入失败；buf 恒以 NUL 结尾。 */
#pragma once

#include <cstddef>

namespace auradsp {
namespace platform {

bool get_env(const char* name, char* buf, size_t cap);

} // namespace platform
} // namespace auradsp
