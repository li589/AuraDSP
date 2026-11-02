#pragma once
// win32_util.h —— POSIX 平台对应物（二期阶段一，2026-11-02）。
//
// 与 platform/win32/win32_util.h 同名同签名：插件层各源文件以裸名
// include 本头，构建按平台把 platform/win32 或 platform/posix 放进
// include 路径（二选一），源码零改动。语义按 Linux 重表达：
//   - 路径原生 UTF-8，宽字符仅作编解码过桥（Linux wchar_t 为
//     UTF-32）；
//   - peIs64Bit 改判 ELF class（与双宿主架构的位数路由同语义）；
//   - PE 版本资源在 ELF 无对应物，三个提取函数返回空——插件
//     元数据的主路径是加载后查工厂信息（CLAP/VST3 皆然），本组
//     函数在 Windows 也只是预加载富化，缺失不改变元数据正确性；
//   - DLL 搜索目录在 dlopen 语义下为空操作（依赖解析走
//     DT_NEEDED/RPATH，与 AddDllDirectory 无对应关系）；
//   - 默认搜索路径返回 Linux 插件目录（与 App 侧预置目录对齐）。
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include "win32_compat.h"

namespace fs = std::filesystem;

namespace auradsp {

constexpr UINT_PTR kSizeSettleTimerId = 0x4143;  // 与 Win32 版同值

// UTF-8 ↔ UTF-32（Linux wchar_t）逐码点转换。
inline std::wstring utf8ToWide(const std::string& utf8) {
    std::wstring out;
    for (size_t i = 0; i < utf8.size();) {
        unsigned char c = static_cast<unsigned char>(utf8[i]);
        uint32_t cp = 0;
        size_t n = 1;
        if (c < 0x80) { cp = c; n = 1; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; n = 2; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; n = 3; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; n = 4; }
        else { cp = 0xFFFD; n = 1; }
        for (size_t k = 1; k < n && i + k < utf8.size(); ++k) {
            cp = (cp << 6) |
                 (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
        }
        i += n;
        out.push_back(static_cast<wchar_t>(cp));
    }
    return out;
}

inline std::string wideToUtf8(const std::wstring& wide) {
    std::string out;
    for (wchar_t wc : wide) {
        uint32_t cp = static_cast<uint32_t>(wc);
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

inline std::string normalizeModuleKey(const std::wstring& wpath) {
    std::error_code ec;
    fs::path canonical = fs::weakly_canonical(fs::path(wpath), ec);
    std::string key = wideToUtf8(ec ? wpath : canonical.wstring());
    std::transform(key.begin(), key.end(), key.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return key;
}

std::vector<std::string> defaultPluginSearchPaths();

std::string extractVendorFromPath(const std::string& filePath);
// 二进制位数探测（双宿主路由用）：64 / 32 / 0（未知或不可读）。
// peIs64Bit 对未知格式回退 true 不适合路由决策，故另设本函数
// 以 ELF class 给出三态。
int pluginBinaryBitness(const std::wstring& binaryPath);
bool peIs64Bit(const std::wstring& binaryPath);
std::string extractCompanyFromVersionInfo(const std::wstring& binaryPath);
std::string extractProductVersionFromVersionInfo(const std::wstring& binaryPath);
std::string extractVendorFromLegalCopyright(const std::wstring& binaryPath);

void setupPluginDllDirectories(const std::string& pluginPath);
void releasePluginDllDirectories(const std::string& pluginPath);
size_t pluginDllDirectoryCount();
std::vector<std::string> pluginDllDirectoryList();
size_t pluginDllDirectoryRefs();
void ResizeDirectChildren(HWND hwnd);
void FlashEditorToFront(HWND hwnd);
void EnsureClapWindowClassRegistered();
void EnsureVst3WindowClassRegistered();

} // namespace auradsp
