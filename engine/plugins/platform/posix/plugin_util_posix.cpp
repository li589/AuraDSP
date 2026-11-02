// plugin_util_posix.cpp —— win32_util.h 的 POSIX 实现（二期阶段一）。
// 与 platform/win32/win32_util.cpp 对位；语义差异见 win32_util.h 头注。
#include "win32_util.h"

#include <cstdlib>
#include <cstring>

namespace auradsp {

std::vector<std::string> defaultPluginSearchPaths() {
    std::vector<std::string> paths;
    if (const char* home = std::getenv("HOME")) {
        paths.push_back(std::string(home) + "/.vst3");
        paths.push_back(std::string(home) + "/.clap");
    }
    paths.push_back("/usr/lib/vst3");
    paths.push_back("/usr/local/lib/vst3");
    paths.push_back("/usr/lib/clap");
    paths.push_back("/usr/local/lib/clap");
    return paths;
}

std::string extractVendorFromPath(const std::string& filePath) {
    // 与 Win32 版同策略：父目录的父级名作厂商候选（粗略启发；
    // 元数据的正式来源是插件工厂信息，本函数只是回退）。
    std::error_code ec;
    fs::path parent = fs::path(filePath).parent_path().parent_path();
    if (parent.empty()) return std::string();
    return parent.filename().string();
}

bool peIs64Bit(const std::wstring& binaryPath) {
    // Linux 对应物：判 ELF class（ELFCLASS64=2）。非 ELF/不可读
    // 返回 false（与 PE 判定失败同口径：不进入加载尝试）。
    const std::string path = wideToUtf8(binaryPath);
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    unsigned char ident[5] = {0};
    const size_t n = std::fread(ident, 1, 5, f);
    std::fclose(f);
    if (n < 5) return false;
    if (ident[0] != 0x7F || ident[1] != 'E' || ident[2] != 'L' ||
        ident[3] != 'F') {
        return false;
    }
    return ident[4] == 2; // ELFCLASS64
}

// ELF 无 PE 版本资源对应物：返回空，元数据走工厂信息/路径回退。
std::string extractCompanyFromVersionInfo(const std::wstring&) {
    return std::string();
}
std::string extractProductVersionFromVersionInfo(const std::wstring&) {
    return std::string();
}
std::string extractVendorFromLegalCopyright(const std::wstring&) {
    return std::string();
}

// dlopen 的依赖解析走 DT_NEEDED/RPATH/LD_LIBRARY_PATH，无
// AddDllDirectory 对应物：空操作（插件依赖目录问题在 Linux 由
// 插件自身 rpath/打包解决，属打包议题而非宿主 API）。
void setupPluginDllDirectories(const std::string&) {}
void releasePluginDllDirectories(const std::string&) {}
size_t pluginDllDirectoryCount() { return 0; }
std::vector<std::string> pluginDllDirectoryList() { return {}; }
size_t pluginDllDirectoryRefs() { return 0; }

// 编辑器窗口辅助：Linux 编辑器本体为后续阶段（X11 嵌入），
// 本阶段为空操作；编辑器入口由 instance 的 showEditor 在非
// Windows 显式返回不可用（阶段三收口），不依赖这里的假成功。
void ResizeDirectChildren(HWND) {}
void FlashEditorToFront(HWND) {}
void EnsureClapWindowClassRegistered() {}
void EnsureVst3WindowClassRegistered() {}

} // namespace auradsp
