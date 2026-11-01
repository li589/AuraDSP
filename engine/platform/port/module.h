/* 平台端口：动态模块（插件二进制）加载（M2 插件平台归类，2026-10-29）。
 *
 * 控制线程专用：LoadLibrary/FreeLibrary 非 RT-safe，严禁进入 auradsp_process 调用图。
 * Windows 实现位于 plugins/platform/win32/plugin_module.cpp：UTF-8 → UTF-16 后
 * LoadLibraryExW(LOAD_WITH_ALTERED_SEARCH_PATH)，保持插件依赖 DLL 的搜索语义；
 * 其他平台实现后补。
 *
 * 句柄是不透明指针，仅可回传给 module_symbol / module_close。 */
#pragma once

namespace auradsp {
namespace platform {

void* module_open_utf8(const char* utf8_path);
void* module_symbol(void* module, const char* symbol_name);
void module_close(void* module);
unsigned long module_last_error();

/* 最近一次失败的可读文本（含平台错误码/系统文案）。
 * Windows：GetLastError + FormatMessage（失败时退化为 "Win32 error N"）。
 * Linux/Android：dlerror() 捕获串（读取即清除，实现需在失败点就地快照）。
 * 线程契约：返回线程局部缓冲，仅控制线程可用；无错误时返回空串（非 null）。
 * CP-11（2026-11-01）：与 module_last_error 并存——数值用于机器判断，
 * 文本用于诊断展示，避免 Linux 的 dlerror 文本被迫塞进 unsigned long。 */
const char* module_last_error_text();

} // namespace platform
} // namespace auradsp
