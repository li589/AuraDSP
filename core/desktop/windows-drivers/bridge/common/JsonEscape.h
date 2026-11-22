#pragma once
//
// JsonEscape.h — 桥层 JSON 字符串转义单一实现（2026-11-23 重复
// 代码收敛轮 D2：原 AsioBridge / VaioBridge 各一份逐字副本合并）。
//
// 细审 R-D L6：端点/驱动名含 " 或控制字符时，只换反斜杠的
// PathForJsonA 拼出的 JSON 会损坏，Dart 侧 jsonDecode 抛错被
// 吞、detect/status 整体按缺失处理（误报未检测到/状态丢失）。
// 名称类自由文本一律走本函数；路径仍用 PathForJsonA 的斜杠式
// （既有口径，不在本函数范围）。
//
// 控制面专用（状态 JSON 拼装），不进 RT 回调。
#include <cstdio>
#include <string>

namespace aurabridge {

inline void EscapeJsonA(const std::string& in, char* out, size_t cap) {
    size_t j = 0;
    auto put = [&](char c) { if (j + 1 < cap) out[j++] = c; };
    for (size_t i = 0; i < in.size(); ++i) {
        const unsigned char c = (unsigned char)in[i];
        if (c == '"' || c == '\\') { put('\\'); put((char)c); }
        else if (c < 0x20) {
            char u[8];
            snprintf(u, sizeof(u), "\\u%04x", c);
            for (const char* p = u; *p; ++p) put(*p);
        } else put((char)c);
    }
    out[j] = '\0';
}

}  // namespace aurabridge
