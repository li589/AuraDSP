#include "win32_util.h"

#include <windows.h>
#include <winver.h>
#pragma comment(lib, "version.lib")
#include <shlobj.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <vector>

namespace auradsp {
namespace {

/// 扩展名大小写不敏感比较（lowerExt 必须已是小写）。
static bool extensionEqualsCI(const fs::path& p, const char* lowerExt) {
    std::string ext = p.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return ext == lowerExt;
}

/// 读取 PE 头的 IMAGE_FILE_MACHINE。无法解析（非 PE / 读失败）返回 0。
static WORD peMachineType(const std::wstring& binaryPath) {
    std::ifstream f(binaryPath, std::ios::binary);
    if (!f) return 0;
    IMAGE_DOS_HEADER dos{};
    f.read(reinterpret_cast<char*>(&dos), sizeof(dos));
    if (!f || dos.e_magic != IMAGE_DOS_SIGNATURE) return 0;
    if (dos.e_lfanew <= 0) return 0;
    f.seekg(static_cast<std::streamoff>(dos.e_lfanew));
    DWORD signature = 0;
    f.read(reinterpret_cast<char*>(&signature), sizeof(signature));
    if (!f || signature != IMAGE_NT_SIGNATURE) return 0;
    WORD machine = 0;
    f.read(reinterpret_cast<char*>(&machine), sizeof(machine));
    if (!f) return 0;
    return machine;
}

} // namespace

std::string extractVendorFromPath(const std::string& filePath) {
    try {
        fs::path p(filePath);
        while (p.has_filename() && (extensionEqualsCI(p, ".vst3") || extensionEqualsCI(p, ".clap") ||
               p.filename() == "Contents" || p.filename() == "x86_64-win" ||
               p.filename() == "x86-win" || p.filename() == "Resources")) {
            p = p.parent_path();
        }

        while (p.has_filename()) {
            std::string folderName = p.filename().string();
            std::string lowerName = folderName;
            std::transform(lowerName.begin(), lowerName.end(), lowerName.begin(), ::tolower);

            if (lowerName != "vst3" && lowerName != "clap" && lowerName != "common files" &&
                lowerName != "plugins" && lowerName != "vstplugins" && lowerName != "program files" &&
                lowerName != "program files (x86)" && lowerName != "steinberg" && !lowerName.empty() &&
                folderName.back() != ':') {
                return folderName;
            }
            p = p.parent_path();
        }
    } catch (...) {
    }
    return "";
}

/// 由 PE 头判定是否为 64 位二进制。解析失败时按 64 位处理
/// （本进程是 x64；历史行为即默认 true，缺失 PE 信息不应把插件误判为不兼容）。
bool peIs64Bit(const std::wstring& binaryPath) {
    const WORD m = peMachineType(binaryPath);
    if (m == IMAGE_FILE_MACHINE_I386) return false;
    if (m == IMAGE_FILE_MACHINE_AMD64 || m == IMAGE_FILE_MACHINE_ARM64) return true;
    return true;
}

std::string extractCompanyFromVersionInfo(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        struct LANGANDCODEPAGE {
            WORD wLanguage;
            WORD wCodePage;
        } *lpTranslate = nullptr;
        UINT cbTranslate = 0;
        if (VerQueryValueW(buffer.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<LPVOID*>(&lpTranslate), &cbTranslate) &&
            cbTranslate >= sizeof(LANGANDCODEPAGE) && lpTranslate != nullptr) {
            for (unsigned int i = 0; i < (cbTranslate / sizeof(LANGANDCODEPAGE)); i++) {
                wchar_t subBlock[64];
                swprintf_s(subBlock, L"\\StringFileInfo\\%04x%04x\\CompanyName", lpTranslate[i].wLanguage, lpTranslate[i].wCodePage);
                LPWSTR companyName = nullptr;
                UINT companyLen = 0;
                if (VerQueryValueW(buffer.data(), subBlock, reinterpret_cast<LPVOID*>(&companyName), &companyLen) &&
                    companyLen > 0 && companyName && companyName[0] != L'\0') {
                    std::string comp = wideToUtf8(companyName);
                    if (!comp.empty()) return comp;
                }
            }
        }

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\CompanyName",
            L"\\StringFileInfo\\040904E4\\CompanyName",
            L"\\StringFileInfo\\000004b0\\CompanyName",
            L"\\StringFileInfo\\04090000\\CompanyName"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR companyName = nullptr;
            UINT companyLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&companyName), &companyLen) &&
                companyLen > 0 && companyName && companyName[0] != L'\0') {
                std::string comp = wideToUtf8(companyName);
                if (!comp.empty()) return comp;
            }
        }
    } catch (...) {
    }
    return "";
}

std::string extractProductVersionFromVersionInfo(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\ProductVersion",
            L"\\StringFileInfo\\040904E4\\ProductVersion",
            L"\\StringFileInfo\\000004b0\\ProductVersion",
            L"\\StringFileInfo\\040904b0\\FileVersion"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR ver = nullptr;
            UINT verLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&ver), &verLen) &&
                verLen > 0 && ver && ver[0] != L'\0') {
                std::string v = wideToUtf8(ver);
                if (!v.empty()) return v;
            }
        }
    } catch (...) {
    }
    return "";
}

std::string extractVendorFromLegalCopyright(const std::wstring& binaryPath) {
    try {
        DWORD dummy = 0;
        DWORD size = GetFileVersionInfoSizeW(binaryPath.c_str(), &dummy);
        if (size == 0) return "";
        std::vector<BYTE> buffer(size);
        if (!GetFileVersionInfoW(binaryPath.c_str(), 0, size, buffer.data())) return "";

        static const wchar_t* const defaultSubBlocks[] = {
            L"\\StringFileInfo\\040904b0\\LegalCopyright",
            L"\\StringFileInfo\\040904E4\\LegalCopyright",
            L"\\StringFileInfo\\000004b0\\LegalCopyright",
            L"\\StringFileInfo\\04090000\\LegalCopyright"
        };
        for (const auto* sb : defaultSubBlocks) {
            LPWSTR copyText = nullptr;
            UINT copyLen = 0;
            if (VerQueryValueW(buffer.data(), sb, reinterpret_cast<LPVOID*>(&copyText), &copyLen) &&
                copyLen > 0 && copyText && copyText[0] != L'\0') {
                std::string comp = wideToUtf8(copyText);
                if (!comp.empty()) {
                    std::string clean = comp;
                    const char* prefixes[] = {"Copyright (C) ", "Copyright (c) ", "Copyright ", "\xc2\xa9 "};
                    for (const char* pfx : prefixes) {
                        size_t pos = clean.find(pfx);
                        if (pos != std::string::npos) {
                            clean = clean.substr(pos + std::strlen(pfx));
                            break;
                        }
                    }
                    while (clean.size() >= 5 && isdigit((unsigned char)clean[0]) && isdigit((unsigned char)clean[1]) &&
                           isdigit((unsigned char)clean[2]) && isdigit((unsigned char)clean[3]) && (clean[4] == ' ' || clean[4] == '-')) {
                        clean = clean.substr(5);
                    }
                    if (!clean.empty()) return clean;
                    return comp;
                }
            }
        }
    } catch (...) {}
    return "";
}

/* F1（2026-10-24）：插件依赖 DLL 搜索目录的通用化实现。
 *
 * 原实现只服务 iZotope：`if (path 含 izotope|ozone) { 6 条 C:\Program Files\
 * iZotope\Ozone 12\... 字面量目录 }`。四个脆点：版本钉死（升 13 即失效）、
 * 盘符钉死（装 D 盘/Program Files (x86) 无效）、子串误判（C:\Users\ozone\…
 * 也命中）、**cookie 丢弃 + 每次 showEditor 再调一次** → 进程搜索路径单调
 * 增长，后续插件解析同名 DLL 可能绑到别人的私有副本（ABI 不匹配 → 崩溃）。
 *
 * 现在：① 插件目录 + 父目录 + 常见子目录（win64/Cores/bin/x64/lib/lib64）
 * ② 环境变量 AURADSP_PLUGIN_DLL_DIRS（分号分隔，客服/用户可配）
 * ③ cookie 记账 + 引用计数，插件卸载时 RemoveDllDirectory 回收。
 * iZotope（及其它把依赖放安装根而非 bundle 内的厂商）由 ① 自然覆盖，代码
 * 不再认识任何厂商名。 */
namespace {

struct DllDirEntry {
    DLL_DIRECTORY_COOKIE cookie = nullptr;
    int refs = 0;      // 引用计数：同一目录可能被多个插件共用
    bool permanent = false;  // 环境变量目录：进程级，不随插件卸载回收
};

struct DllDirState {
    std::mutex mutex;
    bool defaultsSet = false;
    bool envParsed = false;
    std::map<std::string, DllDirEntry> dirs;                 // 小写路径 → cookie/引用数
    std::map<std::string, std::vector<std::string>> byPlugin;  // 插件键 → 其申请的目录
};

DllDirState& dllDirState() {
    static DllDirState s;  // 有意泄漏：进程退出阶段 Win32 目录已无意义，避免静态析构序问题
    return s;
}

std::string lowerKey(const std::wstring& w) {
    std::string key = wideToUtf8(w);
    std::transform(key.begin(), key.end(), key.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return key;
}

std::string trimAscii(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '"')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '"')) --e;
    return s.substr(b, e - b);
}

/// 登记一个目录（已登记则只加引用）。调用方必须持锁。
void addDirLocked(DllDirState& st, const std::wstring& wdir, const std::string& pluginKey,
                  bool permanent) {
    std::error_code ec;
    if (!fs::is_directory(fs::path(wdir), ec) || ec) return;
    const std::string key = lowerKey(wdir);
    auto it = st.dirs.find(key);
    if (it != st.dirs.end()) {
        it->second.refs++;
        if (!permanent) st.byPlugin[pluginKey].push_back(key);
        return;
    }
    DLL_DIRECTORY_COOKIE cookie = AddDllDirectory(wdir.c_str());
    if (!cookie) return;
    st.dirs[key] = DllDirEntry{cookie, 1, permanent};
    if (!permanent) st.byPlugin[pluginKey].push_back(key);
}

/// 环境变量 AURADSP_PLUGIN_DLL_DIRS（分号分隔）——进程级永久目录。持锁调用。
void parseEnvDirsLocked(DllDirState& st) {
    if (st.envParsed) return;
    st.envParsed = true;
    wchar_t buf[4096] = {};
    const DWORD n = GetEnvironmentVariableW(L"AURADSP_PLUGIN_DLL_DIRS", buf,
                                           (DWORD)(sizeof(buf) / sizeof(buf[0])));
    if (n == 0 || n >= sizeof(buf) / sizeof(buf[0])) return;
    std::wstring all(buf, n);
    size_t start = 0;
    while (start <= all.size()) {
        size_t sep = all.find(L';', start);
        std::wstring one = all.substr(start, sep == std::wstring::npos ? std::wstring::npos : sep - start);
        if (!one.empty()) addDirLocked(st, one, "__env__", true);
        if (sep == std::wstring::npos) break;
        start = sep + 1;
    }
}

}  // namespace

void setupPluginDllDirectories(const std::string& pluginPath) {
    try {
        DllDirState& st = dllDirState();
        std::lock_guard<std::mutex> lock(st.mutex);
        if (!st.defaultsSet) {
            SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_USER_DIRS);
            st.defaultsSet = true;
        }
        parseEnvDirsLocked(st);

        const std::wstring wpath = utf8ToWide(pluginPath);
        if (wpath.empty()) return;
        const std::string pluginKey = lowerKey(wpath);
        if (st.byPlugin.find(pluginKey) != st.byPlugin.end()) return;  // 幂等：showEditor 反复调用不增长

        fs::path p(wpath);
        std::error_code ec;
        fs::path dir = (fs::is_directory(p, ec) && !ec) ? p : p.parent_path();
        if (dir.empty()) return;
        fs::path parent = dir.parent_path();

        // ① 插件目录 + 父目录（iZotope/Ozone 这类把依赖放安装根的厂商由此覆盖）
        addDirLocked(st, dir.wstring(), pluginKey, false);
        if (!parent.empty()) addDirLocked(st, parent.wstring(), pluginKey, false);
        // ② 常见依赖子目录（相对插件目录与安装根各扫一遍，只加真实存在的）
        static const wchar_t* const kSubDirs[] = {L"win64", L"Cores", L"bin",
                                                  L"x64", L"lib", L"lib64"};
        for (const auto* sub : kSubDirs) {
            addDirLocked(st, (dir / sub).wstring(), pluginKey, false);
            if (!parent.empty()) {
                addDirLocked(st, (parent / sub).wstring(), pluginKey, false);
            }
        }
        // 占位：即使一个目录都没加上，也记住该插件已处理过（保证幂等）
        st.byPlugin.emplace(pluginKey, std::vector<std::string>{});
    } catch (...) {
    }
}

void releasePluginDllDirectories(const std::string& pluginPath) {
    try {
        if (pluginPath.empty()) return;
        DllDirState& st = dllDirState();
        std::lock_guard<std::mutex> lock(st.mutex);
        const std::string pluginKey = lowerKey(utf8ToWide(pluginPath));
        auto it = st.byPlugin.find(pluginKey);
        if (it == st.byPlugin.end()) return;
        for (const auto& dirKey : it->second) {
            auto d = st.dirs.find(dirKey);
            if (d == st.dirs.end()) continue;
            if (d->second.permanent) continue;   // 环境变量目录不回收
            if (--d->second.refs <= 0) {
                if (d->second.cookie) RemoveDllDirectory(d->second.cookie);
                st.dirs.erase(d);
            }
        }
        st.byPlugin.erase(it);
    } catch (...) {
    }
}

size_t pluginDllDirectoryCount() {
    DllDirState& st = dllDirState();
    std::lock_guard<std::mutex> lock(st.mutex);
    return st.dirs.size();
}

std::vector<std::string> pluginDllDirectoryList() {
    DllDirState& st = dllDirState();
    std::lock_guard<std::mutex> lock(st.mutex);
    std::vector<std::string> out;
    out.reserve(st.dirs.size());
    for (const auto& kv : st.dirs) out.push_back(kv.first);
    return out;
}

size_t pluginDllDirectoryRefs() {
    DllDirState& st = dllDirState();
    std::lock_guard<std::mutex> lock(st.mutex);
    size_t total = 0;
    for (const auto& kv : st.dirs) total += (size_t)kv.second.refs;
    return total;
}

}  // namespace auradsp
