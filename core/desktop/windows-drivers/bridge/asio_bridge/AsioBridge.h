// AsioBridge.h — ASIO-Client 常驻桥 C ABI（app isolate 经 FFI 调用）。
//
// 本文件是 **Client 线**：打开第三方 ASIO 驱动，处理其输入→输出。与未来的
// **Driver 线**（自身作为 ASIO 驱动被 DAW 打开，见 docs/20-执行双线规划）是
// 两条线，不要混在一个目录里演进（Driver 线立项时单开目录，不进 bridge/）。
//
//
// 契约镜像 bridge/vm_bridge/VmBridge.h（同款 detect/start/stop/status/set_param/
// viz_read/bypass/test_start/test_stop 九件套），差异仅在：
//   1. start 增加两个宿主参数 buf_size / out_pair（ASIO 驱动缓冲档与输出声道对，
//      VM 桥没有对应物；Spec §2.3“通道对选择列入 P2 参数面”的落地）；
//   2. detect 输出驱动清单而非 Voicemeeter 版本（给设置页驱动选择器用）。
//
// 线程模型（与 05 同款三线程，职责分离）：
// - ASIO RT 线程：驱动 bufferSwitch → AsioHost::process_io → 本桥 sink
//   （零锁零分配零 syscall；仅原子量 + scratch + engine process）。
// - Dart 线程：start/stop/set_param/test/viz/status/detect（直接调，无一进 RT）。
// - 无 monitor 线程：ASIO 的采样率/缓冲变化走 asioMessage/sampleRateDidChange，
//   v1 不重建引擎（ Spec 风险 R-3：stop 幂等 + 在途等待由 close 保证）。
//
// 单实例约束（SDK 进程级全局驱动模型）：同进程同时只允许一个桥会话；
// start 已在跑时幂等返回 0（同 vb_start 语义）。
#pragma once

#include <stdint.h>

#if defined(_WIN32)
#define ASB_API __declspec(dllexport)
#else
#define ASB_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 公共导出面已收敛为 common/aurabridge.h 的 ab_*（2026-10-30 清理）。
// 旧前缀实现体（asio_detect/asio_start_ex/.../asio_bypass）仍在本桥内部使用，
// 但**不再导出**；ASIO 专属面（asio_abi / 插件槽）保留。

// §7-2（P-028）桥 ABI 协商：返回桥编译所依据的引擎 ABI 版本（viz 帧布局代际，
// 当前 2）。加载桥后与引擎 auradsp_abi() 比对；不一致时调用方不得解析 viz 帧。
ASB_API unsigned asio_abi(void);

// ---- 插件槽（单引擎）----
// 与 auradsp_plugin_slot_* 同语义（1=成功/0=失败）；桥未运行或无引擎时 0。
ASB_API int asio_plugin_slot_load(int slot, const char* path,
                                  const char* plugin_id);
ASB_API int asio_plugin_slot_unload(int slot);
ASB_API int asio_plugin_slot_set_bypass(int slot, int bypass);
ASB_API int asio_plugin_slot_get_bypass(int slot);
ASB_API unsigned asio_plugin_slot_get_latency(int slot);
ASB_API int asio_plugin_slot_get_status(int slot, char* out, int cap);
ASB_API int asio_plugin_slot_show_editor(int slot, const char* title);
ASB_API int asio_plugin_slot_close_editor(int slot);
ASB_API int asio_plugin_slot_is_editor_open(int slot);
ASB_API int asio_plugin_slot_save_preset(int slot, const char* path);
ASB_API int asio_plugin_slot_load_preset(int slot, const char* path);
ASB_API int asio_plugin_slot_set_insert_stage(int slot, int stage);
ASB_API int asio_plugin_slot_get_insert_stage(int slot);
ASB_API int asio_plugin_slot_set_channels(int slot, int channels);
ASB_API int asio_plugin_slot_get_channels(int slot);

#ifdef __cplusplus
}
#endif
