// VmRemoteLoader.cpp — 见头文件 tier 说明。
#include "VmRemoteLoader.h"

#include <windows.h>

#include <cstdio>
#include <vector>

namespace {

std::string WideToUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string s((size_t)n - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring JoinPath(const std::wstring& dir, const wchar_t* file) {
    if (!dir.empty() && dir.back() != L'\\' && dir.back() != L'/')
        return dir + L'\\' + file;
    return dir + file;
}

bool FileExists(const std::wstring& p) {
    const DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

// Tier 1：在 Uninstall 下找 VB:Voicemeeter*，取安装目录。
bool Tier1FindDir(std::wstring& outDir) {
    static const wchar_t* kRoots[2] = {
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
        L"SOFTWARE\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
    };
    for (const wchar_t* root : kRoots) {
        HKEY hRoot = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, root, 0, KEY_READ, &hRoot) != ERROR_SUCCESS)
            continue;
        wchar_t name[256];
        for (DWORD i = 0;; ++i) {
            DWORD n = 256;
            if (RegEnumKeyExW(hRoot, i, name, &n, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS)
                break;
            std::wstring wname(name, n);
            if (wname.find(L"VB:Voicemeeter") != 0) continue;
            HKEY hApp = nullptr;
            if (RegOpenKeyExW(hRoot, wname.c_str(), 0, KEY_READ, &hApp) != ERROR_SUCCESS)
                continue;
            wchar_t val[1024];
            DWORD vlen = sizeof(val), type = 0;
            // InstallLocation 优先，其次从 UninstallString 截目录。
            bool got = false;
            if (RegQueryValueExW(hApp, L"InstallLocation", nullptr, &type, (BYTE*)val, &vlen) == ERROR_SUCCESS && vlen > 2) {
                outDir = val;
                got = true;
            } else {
                vlen = sizeof(val);
                if (RegQueryValueExW(hApp, L"UninstallString", nullptr, &type, (BYTE*)val, &vlen) == ERROR_SUCCESS && vlen > 2) {
                    std::wstring u(val);
                    if (!u.empty() && u.front() == L'"') {
                        const size_t q = u.find(L'"', 1);
                        if (q != std::wstring::npos) u = u.substr(1, q - 1);
                    }
                    const size_t s = u.find_last_of(L"\\/");
                    if (s != std::wstring::npos) {
                        outDir = u.substr(0, s);
                        got = true;
                    }
                }
            }
            RegCloseKey(hApp);
            if (got) {
                RegCloseKey(hRoot);
                return true;
            }
        }
        RegCloseKey(hRoot);
    }
    return false;
}

// 文件版本号 → "a.b.c.d"。
std::string FileVersionOf(const std::wstring& path) {
    DWORD h = 0;
    const DWORD sz = GetFileVersionInfoSizeW(path.c_str(), &h);
    if (sz == 0) return {};
    std::vector<BYTE> buf(sz);
    if (!GetFileVersionInfoW(path.c_str(), 0, sz, buf.data())) return {};
    VS_FIXEDFILEINFO* fi = nullptr;
    UINT len = 0;
    if (!VerQueryValueW(buf.data(), L"\\", (void**)&fi, &len) || !fi) return {};
    char tmp[64];
    snprintf(tmp, sizeof(tmp), "%u.%u.%u.%u", HIWORD(fi->dwFileVersionMS), LOWORD(fi->dwFileVersionMS),
             HIWORD(fi->dwFileVersionLS), LOWORD(fi->dwFileVersionLS));
    return tmp;
}

using FnLogin = long(__stdcall*)();
using FnLogout = long(__stdcall*)();
using FnGetType = long(__stdcall*)(long*);
using FnGetVersion = long(__stdcall*)(long*);

// Tier 2：Remote DLL 动态自省。返回 true = API 活、edition/version 可信。
bool Tier2Probe(const std::wstring& dir, int& edition, std::string& remoteVer) {
    const std::wstring dll =
#ifdef _WIN64
        JoinPath(dir, L"VoicemeeterRemote64.dll");
#else
        JoinPath(dir, L"VoicemeeterRemote.dll");
#endif
    HMODULE h = LoadLibraryW(dll.c_str());
    if (!h) return false;
    auto login = (FnLogin)GetProcAddress(h, "VBVMR_Login");
    auto logout = (FnLogout)GetProcAddress(h, "VBVMR_Logout");
    auto getType = (FnGetType)GetProcAddress(h, "VBVMR_GetVoicemeeterType");
    auto getVer = (FnGetVersion)GetProcAddress(h, "VBVMR_GetVoicemeeterVersion");
    bool ok = false;
    if (login && getType && getVer) {
        login();
        long t = 0, v = 0;
        if (getType(&t) == 0 && (t == 1 || t == 2 || t == 3)) {
            edition = (int)t;
            if (getVer(&v) == 0 && v != 0) {
                // VB  packed：v1.v2.v3.v4（高→低字节）。
                char tmp[64];
                snprintf(tmp, sizeof(tmp), "%ld.%ld.%ld.%ld", (v >> 24) & 0xFF, (v >> 16) & 0xFF,
                         (v >> 8) & 0xFF, v & 0xFF);
                remoteVer = tmp;
            }
            ok = true;
        }
        if (logout) logout();
    }
    if (remoteVer.empty()) remoteVer = FileVersionOf(dll);
    FreeLibrary(h);
    return ok;
}

// Tier 3：exe 存在性定版型 + 签名版本。
bool Tier3Probe(const std::wstring& dir, int& edition, std::string& appVer) {
    static const struct {
        const wchar_t* exe;
        int edition;
    } kExes[] = {
        {L"voicemeeter8.exe", 3},  {L"voicemeeter8x64.exe", 3},
        {L"voicemeeterpro.exe", 2}, {L"voicemeeterpro_x64.exe", 2},
        {L"voicemeeter.exe", 1},    {L"voicemeeter_x64.exe", 1},
    };
    for (const auto& e : kExes) {
        const std::wstring p = JoinPath(dir, e.exe);
        if (!FileExists(p)) continue;
        edition = e.edition;
        appVer = FileVersionOf(p);
        return true;
    }
    return false;
}

std::wstring DefaultDir() {
    // x64 进程优先看原生 Program Files，x86 构建看 (x86)。
    const char* env = (sizeof(void*) == 8) ? "ProgramFiles" : "ProgramFiles(x86)";
    DWORD n = GetEnvironmentVariableA(env, nullptr, 0);
    std::string base = (n > 1) ? std::string(n - 1, '\0') : std::string("C:\\Program Files (x86)");
    if (n > 1) GetEnvironmentVariableA(env, base.data(), n);
    wchar_t wbase[MAX_PATH] = {0};
    MultiByteToWideChar(CP_ACP, 0, base.c_str(), -1, wbase, MAX_PATH);
    return std::wstring(wbase) + L"\\VB\\Voicemeeter";
}

}  // namespace

const char* AuraVmEditionName(int edition) {
    switch (edition) {
        case 1: return "Standard";
        case 2: return "Banana";
        case 3: return "Potato";
        default: return "";
    }
}

AuraVmDetect AuraVmDetectRun() {
    AuraVmDetect d;
    std::wstring dir;
    const bool t1 = Tier1FindDir(dir);
    if (!t1 || !FileExists(JoinPath(dir, L"VoicemeeterRemote64.dll"))) {
        // 注册表无命中或目录下无 Remote DLL：回退默认安装路径。
        const std::wstring def = DefaultDir();
        if (FileExists(JoinPath(def,
#ifdef _WIN64
                                L"VoicemeeterRemote64.dll"
#else
                                L"VoicemeeterRemote.dll"
#endif
                                )))
            dir = def;
        else if (!t1)
            return d;  // 三级全灭：干净返回未安装
    }
    if (dir.empty()) return d;
    d.installDir = WideToUtf8(dir);
    d.found = true;
    d.tierReached = 1;
    int edition = 0;
    std::string remoteVer;
    if (Tier2Probe(dir, edition, remoteVer)) {
        d.edition = edition;
        d.editionName = AuraVmEditionName(edition);
        d.remoteVersion = remoteVer;
        d.tierReached = 2;
        // tier2 不给 app 版本：顺手用 tier3 补（不改变 tierReached）。
        int e3 = 0;
        Tier3Probe(dir, e3, d.appVersion);
        return d;
    }
    if (Tier3Probe(dir, edition, d.appVersion)) {
        d.edition = edition;
        d.editionName = AuraVmEditionName(edition);
        d.tierReached = 3;
    }
    return d;
}
