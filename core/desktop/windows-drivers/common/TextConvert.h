#pragma once
//
// TextConvert.h — windows-drivers 树共享宽窄字符串转换
// （2026-11-23 重复代码收敛轮 D3：原四处副本合并）。
//
// 语义口径（NUL 结尾式）：以 -1 长度调用 WideCharToMultiByte，
// 即在首个 NUL 处截断、结果不含结尾 NUL。原副本分布：
// VmRemoteLoader.cpp（wstring 形参）、ApoInspector.cpp /
// tone_play.cpp / VaioBridge.cpp（wchar_t* 形参，三份逐字
// 相同）；wstring 重载与指针重载等价（空串同为 {}），故只
// 留一份实现、两个入口。
//
// 刻意不并入的一处：03_system_apo/apo_config.cpp 的同名函数
// 是「显式长度式」（按 wstring.size() 全量转换、保留内嵌
// NUL），服务配置字符串的逐字保真，语义不同、只有一份，
// 保留原地并在彼处注明，勿按本头口径改它。
//
// 全部为控制面/工具面函数，不进 RT 回调。
#include <string>
#include <windows.h>

namespace auratext {

inline std::string WideToUtf8(const wchar_t* w) {
    if (!w || !*w) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return {};
    std::string s((size_t)n - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
    return s;
}

inline std::string WideToUtf8(const std::wstring& w) {
    return WideToUtf8(w.c_str());
}

}  // namespace auratext
