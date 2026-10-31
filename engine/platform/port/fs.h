/* 平台端口：UTF-8 路径文件打开（M1 平台隔离，2026-10-29）。
 *
 * 控制线程专用：fopen/_wfopen 非 RT-safe，严禁进入 auradsp_process 调用图。
 * Windows 实现内部 UTF-8 → UTF-16 后走 _wfopen（CJK 路径，R-1 修复同源）；
 * 其他平台实现可直接 fopen。调用方负责 fclose。
 *
 * R2（M6 审查遗留，2026-10-30）：失败原因经 out 参数回传，恢复 M1 端口化
 * 前调用方可区分的错误语义（UTF-8 非法 → E_PARAM，OOM/打开失败 → E_IO），
 * 避免一律退化成 "cannot open"。不传 out 参数时行为与旧签名完全一致。 */
#pragma once

#include <cstdio>

namespace auradsp {
namespace platform {

/// 打开失败原因（port 纯声明，无 OS 依赖）。
enum class FsOpenError {
    none,             // 成功（或未请求错误信息）
    invalid_path,     // 路径/模式参数为空
    invalid_encoding, // 路径不是合法 UTF-8（转码失败）
    out_of_memory,    // 实现内部缓冲分配失败
    open_failed,      // 路径合法但文件打不开（不存在/无权限等）
};

/// 打开 UTF-8 路径文件。失败返回 nullptr，[err]（可选）带具体原因。
FILE* fopen_utf8(const char* utf8_path, const char* mode,
                 FsOpenError* err = nullptr);

} // namespace platform
} // namespace auradsp
