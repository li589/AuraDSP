// VaioBridge.h — AuraVAIO 虚拟声卡模式持久桥 C ABI（app isolate 经 FFI 调用）。
//
// 契约镜像 bridge/vm_bridge/VmBridge.h 与 bridge/asio_bridge/AsioBridge.h：
//   vaio_detect / vaio_start / vaio_stop / vaio_status / vaio_set_param /
//   vaio_set_param_str / vaio_get_param / vaio_get_param_str / vaio_viz_read /
//   vaio_bypass / vaio_test_start / vaio_test_stop
//
// 线程模型：
// - RT 泵线程：AvSetMmThreadCharacteristicsW("Pro Audio")，从内核共享环形缓冲读渲染帧，
//   送入 auradsp_process 处理，并直接写入 WASAPI 物理音频端点缓冲（零锁零动态分配）。
// - Dart 线程：start/stop/set_param/test/viz/status/detect（全部在控制线程执行，不阻塞 RT）。
#pragma once

#include <stdint.h>

#if defined(_WIN32)
#define VAB_API __declspec(dllexport)
#else
#define VAB_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 公共导出面已收敛为 common/aurabridge.h 的 ab_*（2026-10-30 清理）。
// 旧前缀实现体（vaio_detect/vaio_start/.../vaio_bypass）仍在本桥内部使用，
// 但**不再导出**；VAIO 专属面（vaio_abi / 插件槽）保留。

// §7-2（P-028）桥 ABI 协商：返回桥编译所依据的引擎 ABI 版本（viz 帧布局代际，
// 当前 2）。加载桥后与引擎 auradsp_abi() 比对；不一致时调用方不得解析 viz 帧。
VAB_API unsigned vaio_abi(void);

// ---- 插件槽（单引擎）----
// 与 auradsp_plugin_slot_* 同语义（1=成功/0=失败）；桥未运行或无引擎时 0。
VAB_API int vaio_plugin_slot_load(int slot, const char* path,
                                  const char* plugin_id);
VAB_API int vaio_plugin_slot_unload(int slot);
VAB_API int vaio_plugin_slot_set_bypass(int slot, int bypass);
VAB_API int vaio_plugin_slot_get_bypass(int slot);
VAB_API unsigned vaio_plugin_slot_get_latency(int slot);
VAB_API int vaio_plugin_slot_get_status(int slot, char* out, int cap);
VAB_API int vaio_plugin_slot_show_editor(int slot, const char* title);
VAB_API int vaio_plugin_slot_close_editor(int slot);
VAB_API int vaio_plugin_slot_is_editor_open(int slot);
VAB_API int vaio_plugin_slot_save_preset(int slot, const char* path);
VAB_API int vaio_plugin_slot_load_preset(int slot, const char* path);
VAB_API int vaio_plugin_slot_set_insert_stage(int slot, int stage);
VAB_API int vaio_plugin_slot_get_insert_stage(int slot);
VAB_API int vaio_plugin_slot_set_channels(int slot, int channels);
VAB_API int vaio_plugin_slot_get_channels(int slot);

#ifdef __cplusplus
}
#endif
