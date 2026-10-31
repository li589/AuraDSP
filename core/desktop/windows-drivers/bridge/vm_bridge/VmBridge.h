// VmBridge.h — VB-Callback 持久桥 C ABI（app isolate 经 FFI 调用）。
//
// 与 vm_pump_test 的“跑 N 秒即退”不同：本桥常驻（start 后 VB 线程持续回调，
// stop 前不退），供 UI APP 切换音频模式后实时处理。RT 铁律沿用泵：
// 回调内零锁零分配；控制面（start/stop/param/test/viz/status）全在
// Dart 线程或桥内 monitor 线程，无一在 RT 线程分配/等待。
#pragma once

#include <stdint.h>

#if defined(_WIN32)
#define VBB_API __declspec(dllexport)
#else
#define VBB_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 公共导出面已收敛为 common/aurabridge.h 的 ab_*（2026-10-30 清理）。
// 旧前缀实现体（vb_detect/vb_start/.../vb_bypass）仍在本桥内部使用，但**不再
// 导出**；VB 专属面（vb_abi / vb_set_bus_mask / vb_test_change / 插件槽）保留。

// 模拟一次 VM CHANGE（VB 推 kCbChange 时置位同标志），供 smoke 回归重建路径。
VBB_API int vb_test_change();

// §7-2（P-028）桥 ABI 协商：返回桥编译所依据的引擎 ABI 版本（viz 帧布局代际，
// 当前 2）。加载桥后与引擎 auradsp_abi() 比对；不一致时调用方不得解析 viz 帧。
VBB_API unsigned vb_abi(void);

// 总线处理掩码：bit g 置位 = 第 g 组（即第 g 条总线）进 DSP，清零 = 该总线直通。
// 电平表照常计量；CHANGE 重建/session 内保持。返回生效后的掩码，<0=桥未运行。
VBB_API int vb_set_bus_mask(int mask);

// ---- 插件槽（BUGFIX 2026-10-22：写操作同步全部组引擎，读/编辑器 eng[0]）----
// 与 auradsp_plugin_slot_* 同语义（1=成功/0=失败）；桥未运行或无引擎时 0。
// load 成功会写入桥内镜像，VM CHANGE 重建后自动回放到全部新引擎。
VBB_API int vb_plugin_slot_load(int slot, const char* path,
                                const char* plugin_id);
VBB_API int vb_plugin_slot_unload(int slot);
VBB_API int vb_plugin_slot_set_bypass(int slot, int bypass);
VBB_API int vb_plugin_slot_get_bypass(int slot);
VBB_API unsigned vb_plugin_slot_get_latency(int slot);
VBB_API int vb_plugin_slot_get_status(int slot, char* out, int cap);
VBB_API int vb_plugin_slot_show_editor(int slot, const char* title);
VBB_API int vb_plugin_slot_close_editor(int slot);
VBB_API int vb_plugin_slot_is_editor_open(int slot);
/* 按路编辑器（2026-10-22 v2）：VB 模式下每 8 声道一组建独立引擎（433963a
 * 已逐组加载插件实例），上述三函数恒作用于 eng[0]（A1）。_g 变体作用于
 * 组 g 的引擎实例——"调某一路的插件就打开那一路的界面"。
 * group 越界或该组无引擎时返回 0（不崩）。 */
VBB_API int vb_plugin_slot_show_editor_g(int slot, int group, const char* title);
VBB_API int vb_plugin_slot_close_editor_g(int slot, int group);
VBB_API int vb_plugin_slot_is_editor_open_g(int slot, int group);
VBB_API int vb_plugin_slot_save_preset(int slot, const char* path);
VBB_API int vb_plugin_slot_load_preset(int slot, const char* path);
/* P2-1（v3.3 A/B 预设）：per-group state 读写（VB 各路 A/B 独立存储）。 */
VBB_API int vb_plugin_slot_save_preset_g(int slot, int group, const char* path);
VBB_API int vb_plugin_slot_load_preset_g(int slot, int group, const char* path);
VBB_API int vb_plugin_slot_set_insert_stage(int slot, int stage);
VBB_API int vb_plugin_slot_get_insert_stage(int slot);
VBB_API int vb_plugin_slot_set_channels(int slot, int channels);
VBB_API int vb_plugin_slot_get_channels(int slot);
/* P1-3 per-group Ch（2026-10-22 v3.1）：VB 各路独立声道选择记忆。
 * group 越界/无引擎返回 0。 */
VBB_API int vb_plugin_slot_set_channels_g(int slot, int group, int channels);

// ---- 按路插件处理掩码（2026-10-22）----
// bit g = 组 g 的总线是否吃插件链（1=吃，0=直通，厂商 DSP 不受影响）。
// 默认 0xFF 全开。引擎无链开关符号（旧 DLL）时接受掩码但无实效。
VBB_API int vb_plugin_group_enable(int mask);
VBB_API int vb_plugin_group_mask();

/* 诊断（2026-10-23 挂载提速）：组 g 的 slot 是否已就绪（1=实例已挂）。
 * 挂载先同步 eng[0]、其余组后台补齐——本函数用于冒烟验证补齐进度与
 * 排障（Dart 侧不需要）。group/slot 越界返回 0。 */
VBB_API int vb_plugin_slot_group_ready(int slot, int group);

// ---- Z12 超预算自动保护（2026-10-23）：用户开关 + 测试注入口 ----
// 一直在 .def 里导出、cpp 里有实现，唯独头文件没有声明 —— 于是任何
// include 本头的调用方都拿不到原型（隐式声明/链接错误），而 Dart 侧
// audio_vbridge.dart 其实已在调用 vb_plugin_auto_protect。on < 0 = 查询；
// 否则置位。关闭时若保护已激活，立即恢复用户掩码。
VBB_API int vb_plugin_auto_protect(int on);
// 测试注入（smoke_vm_protect.py）：直接喂守卫观测值（emaUs / overStreak）。
// overStreak < 0 退出测试模式并清零观测。仅测试用，Dart 侧不需要。
VBB_API int vb_protect_test(int emaUs, int overStreak);

#ifdef __cplusplus
}
#endif
