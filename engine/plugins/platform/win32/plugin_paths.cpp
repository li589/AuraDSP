#include "win32_util.h"

#include <windows.h>

#include <algorithm>
#include <string>
#include <vector>

namespace auradsp {
namespace {

void addExisting(std::vector<std::string>& paths, const std::string& path) {
    if (path.empty()) return;
    std::error_code ec;
    if (!fs::exists(path, ec)) return;
    if (std::find(paths.begin(), paths.end(), path) == paths.end()) {
        paths.push_back(path);
    }
}

std::string envValue(const char* name) {
    char buf[MAX_PATH * 2] = {0};
    const DWORD n = GetEnvironmentVariableA(name, buf, static_cast<DWORD>(sizeof(buf)));
    if (n == 0 || n >= sizeof(buf)) return {};
    return std::string(buf, n);
}

// VST2 传统安装位置由注册表登记（VSTPluginsPath）。分别读 HKCU / HKLM
// 的 32 位与 64 位视图——老插件常把路径写进 WOW6432Node。
std::string readVst2RegistryPath(HKEY root, REGSAM view) {
    HKEY key = nullptr;
    if (RegOpenKeyExA(root, "SOFTWARE\\VST", 0, KEY_READ | view, &key) != ERROR_SUCCESS) {
        return {};
    }
    char buf[MAX_PATH * 2] = {0};
    DWORD type = 0;
    DWORD size = static_cast<DWORD>(sizeof(buf));
    const LONG rc = RegQueryValueExA(key, "VSTPluginsPath", nullptr, &type,
                                     reinterpret_cast<LPBYTE>(buf), &size);
    RegCloseKey(key);
    if (rc != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) || size == 0) {
        return {};
    }
    buf[sizeof(buf) - 1] = '\0';
    if (type == REG_EXPAND_SZ) {
        char expanded[MAX_PATH * 2] = {0};
        if (ExpandEnvironmentStringsA(buf, expanded, static_cast<DWORD>(sizeof(expanded))) > 0) {
            return std::string(expanded);
        }
    }
    return std::string(buf);
}

} // namespace

std::vector<std::string> defaultPluginSearchPaths() {
    std::vector<std::string> paths;

    // 1. %CommonProgramFiles%\VST3 / CLAP / VST2
    const std::string commonPf = envValue("CommonProgramFiles");
    if (!commonPf.empty()) {
        addExisting(paths, commonPf + "\\VST3");
        addExisting(paths, commonPf + "\\CLAP");
        addExisting(paths, commonPf + "\\VST2");
    } else {
        // 路径兜底禁写死盘符（F1 反模式）：由 SystemDrive 派生。
        const std::string sysDrive = envValue("SystemDrive");
        if (!sysDrive.empty()) {
            const std::string fallback = sysDrive + "\\Program Files\\Common Files";
            addExisting(paths, fallback + "\\VST3");
            addExisting(paths, fallback + "\\CLAP");
            addExisting(paths, fallback + "\\VST2");
        }
    }

    // 2. %LOCALAPPDATA%\Programs\Common\VST3 / CLAP / VST2
    const std::string localApp = envValue("LOCALAPPDATA");
    if (!localApp.empty()) {
        addExisting(paths, localApp + "\\Programs\\Common\\VST3");
        addExisting(paths, localApp + "\\Programs\\Common\\CLAP");
        addExisting(paths, localApp + "\\Programs\\Common\\VST2");
    }

    // 3. VST2 传统目录：Program Files 与 Program Files (x86) 下的 VstPlugins
    const std::string programFiles = envValue("ProgramFiles");
    if (!programFiles.empty()) addExisting(paths, programFiles + "\\VstPlugins");
    const std::string programFilesX86 = envValue("ProgramFiles(x86)");
    if (!programFilesX86.empty()) addExisting(paths, programFilesX86 + "\\VstPlugins");

    // 4. 注册表登记的 VST2 路径（HKCU/HKLM × 32/64 位视图）
    addExisting(paths, readVst2RegistryPath(HKEY_CURRENT_USER, KEY_WOW64_64KEY));
    addExisting(paths, readVst2RegistryPath(HKEY_CURRENT_USER, KEY_WOW64_32KEY));
    addExisting(paths, readVst2RegistryPath(HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY));
    addExisting(paths, readVst2RegistryPath(HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY));

    return paths;
}

} // namespace auradsp
