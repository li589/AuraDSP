#include "win32_util.h"

#include <windows.h>
#include <winver.h>
#pragma comment(lib, "version.lib")
#include <shlobj.h>

#include <algorithm>
#include <cstring>
#include <fstream>
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

void setupPluginDllDirectories(const std::string& pluginPath) {
    try {
        SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS | LOAD_LIBRARY_SEARCH_USER_DIRS);
        fs::path p(pluginPath);
        fs::path dir = fs::is_directory(p) ? p : p.parent_path();
        AddDllDirectory(dir.wstring().c_str());

        std::string pLow = pluginPath;
        std::transform(pLow.begin(), pLow.end(), pLow.begin(), ::tolower);
        if (pLow.find("izotope") != std::string::npos || pLow.find("ozone") != std::string::npos) {
            const wchar_t* izDirs[] = {
                L"C:\\Program Files\\iZotope\\Ozone 12\\Cores",
                L"C:\\Program Files\\iZotope\\Ozone 12\\win64",
                L"C:\\Program Files\\iZotope\\Ozone 12",
                L"C:\\Program Files\\iZotope\\Ozone 12 Equalizer\\Crash Reporter",
                L"C:\\Program Files\\iZotope\\RX 12 Audio Editor\\Cores",
                L"C:\\Program Files\\iZotope\\RX 12 Audio Editor\\win64"
            };
            for (const auto* d : izDirs) {
                if (fs::exists(d)) {
                    AddDllDirectory(d);
                }
            }
        }
    } catch (...) {}
}

} // namespace auradsp
