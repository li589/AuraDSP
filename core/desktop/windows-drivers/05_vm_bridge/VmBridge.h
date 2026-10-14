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

// 从 group0 handle 读可视化帧（408B/帧，与 auradsp_viz_read 同布局，
// Dart 侧已有解析）。返回读到帧数，0=无引擎/未运行。
VBB_API int vb_viz_read(void* out408, int count);

// 用户旁路开关（与进程内 bypass 同义：跳过 process，输入直通）。
// 返回 0；桥未运行时返回 <0。
VBB_API int vb_bypass(int on);

// 测试注入：kind 1=正弦440 2=粉噪 3=文件。kind=3 时拷贝 pcm
//（交织立体声 float32，frames 帧，ch 声道，rate 采样率；语义同 FileSource）。
// 启动即静音主通道 VB 输入，测试信号进同一条 DSP 链。返回 0=ok，<0=未运行。
VBB_API int vb_test_start(int kind, const float* pcm, int frames, int ch, int rate);
// 停止测试：先清 kind（RT 可见），等 50ms 让在途回调退出，再释放文件缓冲。
VBB_API int vb_test_stop();

#ifdef __cplusplus
}
#endif
