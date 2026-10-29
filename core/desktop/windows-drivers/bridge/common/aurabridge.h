// aurabridge.h — 统一桥契约（P5：`ab_*` C ABI）。
//
// 目的（docs/10-架构/桥惰性加载与全后端静音门控及DSP解耦落地方案-2026-10-29.md
// §4.1）：三桥（VM/ASIO/VAIO）的公共导出面收敛为同一组符号名与同一套签名，
// Dart 只依赖本契约 + 桥注册项；新平台新后端 = 实现本契约 + 注册一项，
// 不动引擎、不动 UI（§4.3）。
//
// 过渡期（一个版本，写进验收）：三桥同时导出旧前缀（vb_*/asio_*/vaio_*），
// 本文件的实现由 aurabridge_impl.h 转发到旧前缀——行为逐字相同，零语义差。
// Dart 侧 audio_bridge.dart 优先探测 ab_abi_version，缺失则回落旧前缀：
// 新 App + 旧桥（回落）、旧 App + 新桥（旧前缀仍在）两边都不炸。
//
// 插件槽面（`<prefix>_plugin_slot_*`）**不**进本契约：它经 PluginBridge.h 的
// 前缀无关 Fns 表转发，Dart 已按 prefix 统一绑定，改成 ab_* 只有改名的收益。
//
// start 的各桥差异经 config_json 归一（字符串按键取值、整数按键取值）：
//   VM   : 无专属字段，config_json 可传 "" / "{}"
//   ASIO : {"driver":"FL Studio ASIO","bufSize":512,"outPair":0,"channels":2}
//   VAIO : {"endpoint":"Speakers"}
#pragma once

#include <stdint.h>

/// 统一桥契约版本（Dart audio_bridge.dart 侧期望值）。
/// 只在「导出面/签名」变更时递增；viz 帧布局代际仍由各桥 `<prefix>_abi` 管。
#define AURABRIDGE_ABI 1

#if defined(_WIN32)
#define AB_API __declspec(dllexport)
#else
#define AB_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 契约版本：恒返回 AURABRIDGE_ABI。宿主以此判断「该桥是否支持 ab_* 面」，
// 返回 0/缺失 → 回落旧前缀（老桥）。
AB_API unsigned ab_abi_version(void);

// 能力清单 JSON（调用方 buffer，无分配；返回字节数不含尾零，<0=容量不足）：
// {"bridge":"vm","busGroups":8,"pluginGroups":8,"autoProtect":true,"gating":true}
// 字段面向诊断与设置页；未知键的调用方必须忽略（只增不删）。
AB_API int ab_capabilities(char* out, int cap);

// 环境/设备检测：JSON 写入 out（UTF-8），返回字节数（不含尾零），<0=失败。
// 形状随桥而异（VM=版本信息 / ASIO=驱动清单 / VAIO=端点列表），见各桥头注释。
AB_API int ab_detect(char* out, int cap);

// 启动常驻桥。engine_dll="" 则桥内自动搜索；params_json="" 则不预下发
// （"id=f1.5;id2=i3"）；config_json 承载桥专属宿主参数（见文件头）。
// 返回：0=ok；1=OUT 槽被占（VM）；<0=失败（note 见 status）。非阻塞。
AB_API int ab_start(const char* engine_dll, const char* params_json,
                    const char* config_json);

// 停止（与 start 严格配对，幂等）。
AB_API int ab_stop(void);

// 状态 JSON（调用方 buffer，无分配）。公共键：running/frames/sr/nbs/peakIn/
// note/testKind/bypass；P3 起三桥统一带 "gated"/"idleMs"。
AB_API int ab_status(char* out, int cap);

// 参数即时下发。返回成功 handle 数（VM）或 0/-1（单引擎桥），<0=未运行。
AB_API int ab_set_param(const char* id, int isFloat, const void* v4);

// 字符串参数（UTF-8 字节串，不含 NUL；调用返回后调用方缓冲可释放）。
AB_API int ab_set_param_str(const char* id, const char* utf8, int bytes);

// 参数回读（group0）：out4 为 4 字节缓冲；0=ok，<0=失败。
AB_API int ab_get_param(const char* id, int isFloat, void* out4);

// 字符串参数回读：返回写入字节数（不含 NUL），<0=失败。
AB_API int ab_get_param_str(const char* id, char* out, int cap);

// 读可视化帧（1600B/帧 = sizeof(auradsp_viz_frame) ABI v2，与
// auradsp_viz_read 同布局透传）。返回帧数，0=无引擎/未运行。
AB_API int ab_viz_read(void* out1600, int count);

// 用户旁路（跳过 process，输入直通）。0=ok，<0=未运行。
AB_API int ab_bypass(int on);

// 测试注入：kind 1=正弦440 2=粉噪 3=文件（pcm 交织 float32，桥内拷贝）。
AB_API int ab_test_start(int kind, const float* pcm, int frames, int ch,
                         int rate);
AB_API int ab_test_stop(void);

#ifdef __cplusplus
}
#endif

// ---------------------------------------------------------------------------
// config_json 的最小读取：只认 "key":"字符串" 与 "key":整数，仅控制线程使用
// （start 路径，非 RT）。刻意不引入 JSON 库——本工程桥内零第三方依赖。
// ---------------------------------------------------------------------------
#ifdef __cplusplus

#include <cstdlib>

namespace abcfg {

// p 指向键名首字符（开引号之后）；匹配完整键名且其后紧跟闭合引号。
inline bool KeyMatch(const char* p, const char* key) {
    for (; *key; ++p, ++key) {
        if (*p != *key) return false;
    }
    return *p == '"';
}

inline bool IsSpace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// 返回 key 对应值的起点（已跳过冒号、空白与字符串开引号）；未找到返回 nullptr。
inline const char* Find(const char* json, const char* key) {
    if (!json || !key) return nullptr;
    for (const char* p = json; *p; ++p) {
        if (*p != '"' || !KeyMatch(p + 1, key)) continue;
        const char* q = p + 1;
        while (*q && *q != '"') ++q;  // 键名闭合引号
        if (!*q) return nullptr;
        ++q;
        while (IsSpace(*q)) ++q;
        if (*q != ':') continue;
        ++q;
        while (IsSpace(*q)) ++q;
        if (*q == '"') ++q;
        return q;
    }
    return nullptr;
}

// 字符串值拷贝进 out（处理 \\ \" \/ 三种转义），缺失/超长截断时写 def。
inline void StrInto(const char* json, const char* key, char* out, int cap,
                    const char* def) {
    if (!out || cap <= 0) return;
    const char* v = Find(json, key);
    if (!v) {
        int i = 0;
        for (; def && def[i] && i + 1 < cap; ++i) out[i] = def[i];
        out[i] = '\0';
        return;
    }
    int n = 0;
    while (*v && *v != '"' && n + 1 < cap) {
        if (*v == '\\' && (v[1] == '"' || v[1] == '\\' || v[1] == '/')) ++v;
        out[n++] = *v++;
    }
    out[n] = '\0';
}

// 整数值；缺失或非数字时返回 def。
inline long Long(const char* json, const char* key, long def) {
    const char* v = Find(json, key);
    if (!v) return def;
    char* end = nullptr;
    const long n = std::strtol(v, &end, 10);
    return end == v ? def : n;
}

}  // namespace abcfg

#endif  // __cplusplus
