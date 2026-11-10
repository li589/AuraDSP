// APO 风味专用空实现（Part I Q1，2026-11-10）。
//
// plugin_gui_win32.cpp 的编辑器窗口辅助（win32_util.h 声明的五
// 个函数）在 audiodg 内无意义：编辑器永不在 APO 侧打开（编辑
// 器类 C ABI 已由 AURADSP_NO_PLUGIN_EDITOR 在 plugin_abi 边界
// 关闭，影子实例在 App 侧）。但三格式实例的编辑器方法仍引用
// 这五个符号，本 TU 只为 auradsp_engine_apo 目标提供空实现使
// 链接成立——函数永不被调用（全部调用点都在编辑器路径内，
// 而编辑器路径在 APO 风味不可达）。主引擎与插件宿主不编本
// 文件（它们编 plugin_gui_win32.cpp 的真实实现）。
#include <windows.h>

#include "win32_util.h"

namespace auradsp {

void ResizeDirectChildren(HWND) {}
void FlashEditorToFront(HWND) {}
void EnsureClapWindowClassRegistered() {}
void EnsureVst3WindowClassRegistered() {}
void EnsureVst2WindowClassRegistered() {}

} // namespace auradsp
