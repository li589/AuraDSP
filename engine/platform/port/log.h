/* 平台端口：宿主调试日志（M1 平台隔离，2026-10-29）。
 *
 * 仅限宿主控制线程（load / unload / editor 生命周期路径）；严禁进入
 * auradsp_process 音频 RT 路径（RT-Safe：零分配零锁零系统调用）。
 * 级别：0=静默 1=仅 WARN 2=全量；log_level() 首次读取 AURADSP_LOG 后粘性缓存。
 * 输出通道由平台实现决定（Windows：OutputDebugStringA）。 */
#pragma once

namespace auradsp {
namespace platform {

int log_level();
void log_emit(int min_level, const char* file, int line, const char* msg);

} // namespace platform
} // namespace auradsp
