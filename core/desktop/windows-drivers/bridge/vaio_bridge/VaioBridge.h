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

// 环境检测与端点枚举：JSON 写入 out（UTF-8），返回写入字节数（不含尾零），<0=失败。
// 格式：
// {"found":true,"driverVersion":"1.0.1","track":"modern","kmdf":"1.15",
//  "sampleRate":48000,"channels":2,"activeRender":0,"activeCapture":0,
//  "endpoints":[{"name":"Speakers (Realtek Audio)","id":"..."},...]}
VAB_API int vaio_detect(char* out, int cap);

// 启动常驻桥。
// engine_dll: 引擎 DLL 路径，若为 "" 则自动按标准候选路径搜索。
// params_json: 初始参数 "id=f1.5;id2=i3"，空字符串表示不预设。
// output_endpoint_substr: 物理输出端点名子串匹配（空则使用系统默认物理输出设备）。
// 返回：0=成功；<0=失败（status.note 见失败详情）。
VAB_API int vaio_start(const char* engine_dll, const char* params_json, const char* output_endpoint_substr);

// 停止桥：停止 RT 泵、释放 WASAPI、销毁引擎、解映射共享内存、关闭控制设备（与 start 严格配对，幂等）。
VAB_API int vaio_stop();

// 状态 JSON（调用方 buffer，无内部堆分配）：
// {"running":true,"frames":N,"sr":48000,"channels":2,"bits":32,
//  "peakIn":0.0,"peakOut":0.0,"maxPumpUs":0.0,"startRc":0,"note":"",
//  "outputEndpoint":"...","engineOk":true,"enginePath":"...",
//  "paramsApplied":0,"paramsFailed":0,"bypass":0,"testKind":0}
VAB_API int vaio_status(char* out, int cap);

// 参数即时下发到引擎 handle。返回 0=成功，<0=桥未运行/失败。
VAB_API int vaio_set_param(const char* id, int isFloat, const void* v4);

// 字符串参数（liveprog.code / arbmag.string）：下发到引擎并记录镜像。返回 0=成功，<0=失败。
VAB_API int vaio_set_param_str(const char* id, const char* utf8, int bytes);

// 参数回读（诊断/回归用）。out4 为 4 字节缓冲；返回 0=ok，<0=失败。
VAB_API int vaio_get_param(const char* id, int isFloat, void* out4);

// 字符串参数回读：out 为调用方缓冲，cap 为容量；返回写入字节数（不含 NUL），<0=失败。
VAB_API int vaio_get_param_str(const char* id, char* out, int cap);

// 从引擎读可视化帧（536B/帧，与 auradsp_viz_read 同布局，Dart 侧已有解析）。
// 返回读到帧数，0=无引擎/未运行。
VAB_API int vaio_viz_read(void* out536, int count);

// 用户旁路开关（跳过 auradsp_process，输入直通输出）。返回 0，<0=桥未运行。
VAB_API int vaio_bypass(int on);

// 测试注入：kind 1=正弦440 2=粉噪 3=文件。
// 启动即静音 VAIO 虚拟输入，测试信号进同一条 DSP 链。返回 0=ok，<0=未运行。
VAB_API int vaio_test_start(int kind, const float* pcm, int frames, int ch, int rate);

// 停止测试信号。
VAB_API int vaio_test_stop();

#ifdef __cplusplus
}
#endif
