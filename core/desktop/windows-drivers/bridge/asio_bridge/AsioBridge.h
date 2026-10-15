// AsioBridge.h — ASIO 常驻桥 C ABI（app isolate 经 FFI 调用）。
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

// 驱动清单 JSON（UTF-8，写入 out，返回字节数不含尾零，<0=失败）：
// {"count":N,"drivers":[{"name":"FL Studio ASIO",
//   "dll":"C:/.../FLStudioASIO.dll","clsid":"{...}"}, ...]}
// name 为 UTF-8 显示名（中文驱动名正确显示）——asio_start 传回此值即可，
// 桥内按 SDK 语义完成"显示名 → 注册表原始名"映射（SDK load 键不暴露给 UI）。
ASB_API int asio_detect(char* out, int cap);

// 启动常驻桥。driver_name 为 detect 的 name（UTF-8 显示名；内部按 SDK 语义
// 用注册表原始名 load——中文名驱动请传 name 字段，桥内完成映射）。
// engine_dll="" 则自动搜索（复用 05 的 TryLoadEngine 候选路径）。
// params_json="" 则不预下发，格式 "id=f1.5;id2=i3"（float 含 '.'/'e'，
// 其余按 int），失败条目计数进 status.paramsFailed。
// buf_size<=0 用驱动 preferredSize；out_pair 为输出对起始声道（L=R+1 配对），
// <0 按 0。返回：0=ok；<0=失败（note 见 status）。非阻塞（ASIO 回调自有线程）。
ASB_API int asio_start(const char* driver_name, const char* engine_dll,
                       const char* params_json, long buf_size, long out_pair);

// 停止：ASIOStop → disposeBuffers → ASIOExit → removeDriver → 销毁引擎 →
// 释放（与 start 严格配对，幂等）。
ASB_API int asio_stop();

// 状态 JSON（调用方 buffer，无分配；driverRaw 为注册表原始字节，不保证合法
// UTF-8，故不上屏——只进 note 排障）：
// {"running":true,"switches":N,"sr":48000,"nbs":512,"driver":"...",
//  "outPair":0,"inCh":8,"outCh":8,"inLatency":0,"outLatency":0,
//  "peakIn":0.0,"peakOut":0.0,"maxCbUs":0.0,"startRc":0,"note":"",
//  "bypass":0,"testKind":0,"paramsApplied":0,"paramsFailed":0,
//  "engine":"C:/.../auradsp_engine.dll","engineOk":true}
ASB_API int asio_status(char* out, int cap);

// 参数即时下发到引擎 handle（引擎 set_param 本就支持 live 调用）。
// 返回 0=ok，<0=桥未运行/参数缺失。
ASB_API int asio_set_param(const char* id, int isFloat, const void* v4);

// 读可视化帧（408B/帧，与 auradsp_viz_read 同布局，Dart 侧已有解析）。
// 返回读到帧数，0=无引擎/未运行。
ASB_API int asio_viz_read(void* out408, int count);

// 用户旁路开关（跳过 engine process，输入直通输出；测试注入仍生效：
// 先填测试信号再直通，与进程内 bypass 同义）。返回 0，<0=桥未运行。
ASB_API int asio_bypass(int on);

// 测试注入：kind 1=正弦440 2=粉噪 3=文件。kind=3 时拷贝 pcm
// （交织立体声 float32，frames 帧，ch 声道，rate 采样率；语义同 FileSource，
// 复用 05 FillTestSignal）。启动即静音 ASIO 输入，测试信号进同一条 DSP 链。
// 返回 0=ok，<0=未运行/参数错。
ASB_API int asio_test_start(int kind, const float* pcm, int frames, int ch, int rate);
// 停止测试：先清 kind（RT 可见），等 50ms 让在途回调退出，再释放文件缓冲。
ASB_API int asio_test_stop();

#ifdef __cplusplus
}
#endif
