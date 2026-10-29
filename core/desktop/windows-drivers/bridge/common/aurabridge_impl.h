// aurabridge_impl.h — 统一 `ab_*` → 旧前缀的过渡转发实现（P5）。
//
// 三桥的公共导出语义本来就同构，P5 不再复制 13 份实现：每座桥 cpp 尾部只做
//     #define AB_LEGACY vb
//     #define AB_CAPS_JSON "{...}"
//     static int AbStartAdapt(...) { ... }   // start 的宿主参数映射
//     #include "aurabridge_impl.h"
// 一个版本后（旧 App 淘汰）：删掉本文件与 .def 里的旧前缀，各桥直接把旧前缀
// 实现改名成 ab_*（或保留本文件、去掉 AB_OLD 宏）。
#pragma once

#ifndef AB_LEGACY
#error "aurabridge_impl.h 需要先 #define AB_LEGACY（vb/asio/vaio）"
#endif
#ifndef AB_CAPS_JSON
#error "aurabridge_impl.h 需要先 #define AB_CAPS_JSON"
#endif

#include "aurabridge.h"

#include <cstring>

#define AB_PASTE2(a, b) a##b
#define AB_PASTE(a, b) AB_PASTE2(a, b)
#define AB_OLD(name) AB_PASTE(AB_LEGACY, name)

extern "C" {

unsigned ab_abi_version(void) { return AURABRIDGE_ABI; }

int ab_capabilities(char* out, int cap) {
    if (!out || cap <= 0) return -1;
    const char* s = AB_CAPS_JSON;
    const size_t n = std::strlen(s);
    if ((int)n >= cap) return -1;
    std::memcpy(out, s, n);
    out[n] = '\0';
    return (int)n;
}

int ab_detect(char* out, int cap) { return AB_OLD(_detect)(out, cap); }

int ab_start(const char* engine_dll, const char* params_json,
             const char* config_json) {
    return AbStartAdapt(engine_dll, params_json, config_json);
}

int ab_stop(void) { return AB_OLD(_stop)(); }

int ab_status(char* out, int cap) { return AB_OLD(_status)(out, cap); }

int ab_set_param(const char* id, int isFloat, const void* v4) {
    return AB_OLD(_set_param)(id, isFloat, v4);
}

int ab_set_param_str(const char* id, const char* utf8, int bytes) {
    return AB_OLD(_set_param_str)(id, utf8, bytes);
}

int ab_get_param(const char* id, int isFloat, void* out4) {
    return AB_OLD(_get_param)(id, isFloat, out4);
}

int ab_get_param_str(const char* id, char* out, int cap) {
    return AB_OLD(_get_param_str)(id, out, cap);
}

int ab_viz_read(void* out1600, int count) {
    return AB_OLD(_viz_read)(out1600, count);
}

int ab_bypass(int on) { return AB_OLD(_bypass)(on); }

int ab_test_start(int kind, const float* pcm, int frames, int ch, int rate) {
    return AB_OLD(_test_start)(kind, pcm, frames, ch, rate);
}

int ab_test_stop(void) { return AB_OLD(_test_stop)(); }

}  // extern "C"
