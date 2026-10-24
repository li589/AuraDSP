#pragma once
// Win32/UTF/PE/版本资源工具。Phase 2 从 plugin_host_util.h 抽出；
// 本头不包含 VST3/CLAP SDK。

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace auradsp {

constexpr UINT_PTR kSizeSettleTimerId = 0x4143;  // 避免与 CLAP 插件自己的定时器 ID 冲突

inline std::wstring utf8ToWide(const std::string& utf8) {
    if (utf8.empty()) return std::wstring();
    int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (size <= 0) return std::wstring();
    std::wstring wide(size - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], size);
    return wide;
}

inline std::string wideToUtf8(const std::wstring& wide) {
    if (wide.empty()) return std::string();
    int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) return std::string();
    std::string utf8(size - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, &utf8[0], size, nullptr, nullptr);
    return utf8;
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
bool peIs64Bit(const std::wstring& binaryPath);
std::string extractCompanyFromVersionInfo(const std::wstring& binaryPath);
std::string extractProductVersionFromVersionInfo(const std::wstring& binaryPath);
std::string extractVendorFromLegalCopyright(const std::wstring& binaryPath);

void setupPluginDllDirectories(const std::string& pluginPath);
void ResizeDirectChildren(HWND hwnd);
/// Z16：编辑器窗口「闪现置顶」。插件宿主进程与 Flutter App 是不同进程，
/// SetForegroundWindow 受前台进程限制常静默失败（用户观感：插件界面
/// 压在 App 下面）。TOPMOST→NOTOPMOST 瞬间抬升不依赖前台权限，且立即
/// 降级非常驻置顶（不挡屏、不招投诉）。
void FlashEditorToFront(HWND hwnd);
void EnsureClapWindowClassRegistered();
void EnsureVst3WindowClassRegistered();

} // namespace auradsp
