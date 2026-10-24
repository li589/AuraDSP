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

// 环境检测：JSON 写入 out（UTF-8），返回写入字节数（不含尾零），<0=失败。
// {"found":true,"edition":3,"editionName":"Potato","installDir":"...",
//  "appVersion":"...","remoteVersion":"...","tierReached":2}
VBB_API int vb_detect(char* out, int cap);

// 启动常驻泵。engine_dll="" 则自动搜索；params_json="" 则不预下发，
// 格式 "id=f1.5;id2=i3"（float 含 '.'/'e'，其余按 int），失败条目计数进 status。
// 返回：0=ok；1=OUT 槽被占；<0=失败（见 note）。非阻塞（VB 回调自有线程）。
VBB_API int vb_start(const char* engine_dll, const char* params_json);

// 停止：stop + logout + unreg + 销毁引擎 + 释放（与 start 严格配对，幂等）。
VBB_API int vb_stop();

// 状态 JSON（调用方 buffer，无分配）：
// {"running":true,"frames":N,"sr":48000,"nbs":512,"groups":8,"handles":8,
//  "peakIn":0.0,"maxCbUs":0.0,"startRc":0,"note":"","testKind":0,"edition":3}
VBB_API int vb_status(char* out, int cap);

// 参数即时下发到全部 live handle（引擎 set_param 本就支持 live 调用，
// isolate 侧同契约）。返回成功 handle 数，<0=桥未运行。
VBB_API int vb_set_param(const char* id, int isFloat, const void* v4);

// 字符串参数（liveprog.code / arbmag.string）：同 auradsp_set_param 的字节语义
// （UTF-8 字节串，不含 NUL；调用返回后调用方缓冲可释放，引擎内部已拷贝编译）。
// 下发全部 live handle 并记入镜像（CHANGE 重建后回放）。返回成功 handle 数。
VBB_API int vb_set_param_str(const char* id, const char* utf8, int bytes);

// 参数回读（group0，诊断/回归用：CHANGE 重建后验证参数真的还在）。
// out4 为 4 字节缓冲；返回 0=ok，<0=失败。
VBB_API int vb_get_param(const char* id, int isFloat, void* out4);

// 字符串参数回读（group0）：out 为调用方缓冲，cap 为容量；返回写入字节数
// （不含 NUL），<0=失败（空间不足/无此参数/桥未运行）。
VBB_API int vb_get_param_str(const char* id, char* out, int cap);

// 模拟一次 VM CHANGE（VB 推 kCbChange 时置位同标志），供 smoke 回归重建路径。
VBB_API int vb_test_change();

// 从 group0 handle 读可视化帧（1600B/帧 = sizeof(auradsp_viz_frame) ABI v2，
// 与 auradsp_viz_read 同布局透传，Dart 侧已有解析）。返回读到帧数，0=无引擎/未运行。
// 注意：桥不做帧长协商，调用方缓冲必须按 1600B/帧分配（旧 408B 分配会堆越界）。
VBB_API int vb_viz_read(void* out1600, int count);

// 用户旁路开关（与进程内 bypass 同义：跳过 process，输入直通）。
// 返回 0；桥未运行时返回 <0。
VBB_API int vb_bypass(int on);

// 总线处理掩码：bit g 置位 = 第 g 组（即第 g 条总线）进 DSP，清零 = 该总线直通。
// 电平表照常计量；CHANGE 重建/session 内保持。返回生效后的掩码，<0=桥未运行。
VBB_API int vb_set_bus_mask(int mask);

// 测试注入：kind 1=正弦440 2=粉噪 3=文件。kind=3 时拷贝 pcm
//（交织立体声 float32，frames 帧，ch 声道，rate 采样率；语义同 FileSource）。
// 启动即静音主通道 VB 输入，测试信号进同一条 DSP 链。返回 0=ok，<0=未运行。
VBB_API int vb_test_start(int kind, const float* pcm, int frames, int ch, int rate);
// 停止测试：先清 kind（RT 可见），等 50ms 让在途回调退出，再释放文件缓冲。
VBB_API int vb_test_stop();

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

#ifdef __cplusplus
}
#endif
