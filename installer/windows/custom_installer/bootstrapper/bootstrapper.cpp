// bootstrapper.cpp — AuraDSP Setup bootstrapper shell.
//
// Role (implementation design: docs/20-执行/Windows安装程序与打包脚本
// 实施设计-2026-11-06.md §2/§3): this PE is the body of the single-file
// AuraDSP-Setup-x64-v<ver>.exe. Appended after it are ZIP-W (wizard
// runtime, ZIP-STORED only) and ZIP-P (product payload, deflate),
// followed by an 80-byte footer:
//
//   magic(8) "AURASTP1" | fmtVer u32 | flags u32 |
//   offW u64 | lenW u64 | offP u64 | lenP u64 | sha256P(32)
//
// The shell verifies the payload SHA256 (BCrypt), extracts ZIP-W with
// a hand-rolled stored-only ZIP reader (zero third-party code in the
// first link of the trust chain), then launches the Flutter wizard
// with the payload location as arguments and exits. All install /
// uninstall logic lives in the wizard (Dart), not here.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <bcrypt.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <iterator>
#include <string>
#include <vector>

namespace {

constexpr char kFooterMagic[8] = {'A', 'U', 'R', 'A', 'S', 'T', 'P', '1'};
constexpr std::uint64_t kFooterSize = 80;
constexpr std::uint64_t kMaxWizardBytes = 512ull << 20;   // sanity cap
constexpr std::uint64_t kMaxPayloadBytes = 4ull << 30;    // sanity cap

int Fail(const wchar_t* msg) {
    MessageBoxW(nullptr, msg, L"AuraDSP Setup", MB_OK | MB_ICONERROR);
    return 1;
}

std::uint32_t Rd32(const std::uint8_t* p) {
    return (std::uint32_t)p[0] | ((std::uint32_t)p[1] << 8) |
           ((std::uint32_t)p[2] << 16) | ((std::uint32_t)p[3] << 24);
}
std::uint64_t Rd64(const std::uint8_t* p) {
    return (std::uint64_t)Rd32(p) | ((std::uint64_t)Rd32(p + 4) << 32);
}
std::uint16_t Rd16(const std::uint8_t* p) {
    return (std::uint16_t)(p[0] | (p[1] << 8));
}

bool ReadExact(HANDLE h, std::uint64_t off, void* buf, DWORD len) {
    LARGE_INTEGER pos;
    pos.QuadPart = (LONGLONG)off;
    if (!SetFilePointerEx(h, pos, nullptr, FILE_BEGIN)) return false;
    auto* p = (std::uint8_t*)buf;
    DWORD done = 0;
    while (done < len) {
        DWORD got = 0;
        if (!ReadFile(h, p + done, len - done, &got, nullptr) || got == 0)
            return false;
        done += got;
    }
    return true;
}

// Streaming SHA256 over a file range, via BCrypt.
bool Sha256Range(HANDLE h, std::uint64_t off, std::uint64_t len,
                 std::uint8_t out[32]) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD objLen = 0, cb = 0;
    std::vector<std::uint8_t> obj;
    bool ok = false;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    0) < 0)
        return false;
    if (BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH, (PUCHAR)&objLen,
                          sizeof(objLen), &cb, 0) >= 0) {
        obj.resize(objLen);
        if (BCryptCreateHash(alg, &hash, obj.data(), objLen, nullptr, 0,
                             0) >= 0) {
            ok = true;
            std::vector<std::uint8_t> chunk(1 << 20);
            std::uint64_t left = len;
            std::uint64_t cur = off;
            while (ok && left > 0) {
                DWORD want = (DWORD)std::min<std::uint64_t>(left, chunk.size());
                if (!ReadExact(h, cur, chunk.data(), want) ||
                    BCryptHashData(hash, chunk.data(), want, 0) < 0) {
                    ok = false;
                    break;
                }
                cur += want;
                left -= want;
            }
            if (ok && BCryptFinishHash(hash, out, 32, 0) < 0) ok = false;
        }
    }
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    return ok;
}

bool EnsureDir(const std::wstring& path) {
    if (CreateDirectoryW(path.c_str(), nullptr)) return true;
    return GetLastError() == ERROR_ALREADY_EXISTS;
}

// Create all parent directories of filePath (which itself is not created).
bool EnsureParents(const std::wstring& filePath) {
    for (size_t i = 0; i < filePath.size(); ++i) {
        if (filePath[i] == L'\\') {
            std::wstring part = filePath.substr(0, i);
            if (!part.empty() && part.back() != L':' && !EnsureDir(part))
                return false;
        }
    }
    return true;
}

void DeleteTreeBestEffort(const std::wstring& dir) {
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(fd.cFileName, L".") == 0 ||
                wcscmp(fd.cFileName, L"..") == 0)
                continue;
            std::wstring p = dir + L"\\" + fd.cFileName;
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                DeleteTreeBestEffort(p);
                RemoveDirectoryW(p.c_str());
            } else {
                SetFileAttributesW(p.c_str(), FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(p.c_str());
            }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir.c_str());
}

// Validate a zip entry name and convert to a Windows relative path.
// Rejects absolute paths, drive letters, and ".." components.
bool SanitizeEntryName(const std::string& name, std::wstring* out) {
    if (name.empty() || name.front() == '/' || name.front() == '\\')
        return false;
    std::wstring wide;
    int need = MultiByteToWideChar(CP_UTF8, 0, name.data(),
                                   (int)name.size(), nullptr, 0);
    if (need <= 0) return false;
    wide.resize(need);
    MultiByteToWideChar(CP_UTF8, 0, name.data(), (int)name.size(),
                        wide.data(), need);
    for (auto& c : wide)
        if (c == L'/') c = L'\\';
    if (wide.size() >= 2 && wide[1] == L':') return false;
    size_t start = 0;
    while (start <= wide.size()) {
        size_t slash = wide.find(L'\\', start);
        std::wstring comp = wide.substr(
            start, slash == std::wstring::npos ? slash : slash - start);
        if (comp.empty() && slash != std::wstring::npos && start != 0)
            return false;
        // 2026-11-08 审计 F3：分量加固。':' 分量是 NTFS ADS / 相对
        // 盘符，一律拒；Win32 解析会剥除分量尾随的点与空格，故
        // ".. " 之形会归一成 ".."——按剥除后的形态判定 ".."/"."。
        if (comp.find(L':') != std::wstring::npos) return false;
        std::wstring stripped = comp;
        while (!stripped.empty() &&
               (stripped.back() == L'.' || stripped.back() == L' '))
            stripped.pop_back();
        if (stripped == L".." || stripped == L".") return false;
        if (slash == std::wstring::npos) break;
        start = slash + 1;
    }
    *out = wide;
    return true;
}

// Normalize an absolute path via GetFullPathNameW (lexical).
bool NormalizePath(const std::wstring& in, std::wstring* out) {
    DWORD need = GetFullPathNameW(in.c_str(), 0, nullptr, nullptr);
    if (need == 0) return false;
    std::wstring buf(need, L'\0');
    if (GetFullPathNameW(in.c_str(), need, buf.data(), nullptr) == 0)
        return false;
    buf.resize(std::wcslen(buf.c_str()));
    *out = buf;
    return true;
}

// Extract a ZIP-STORED archive held in memory into destDir.
bool ExtractStoredZip(const std::uint8_t* zip, size_t zipLen,
                      const std::wstring& destDir) {
    // 2026-11-08 审计 F3 第二道防线：destDir 先归一，逐条目把最终
    // 路径归一后复核仍在其内（分隔符感知），不单靠条目名净化。
    std::wstring destRoot;
    if (!NormalizePath(destDir, &destRoot)) return false;
    // Locate End Of Central Directory (comment length is 0 in our zips,
    // but scan the legal window anyway).
    size_t eocd = SIZE_MAX;
    size_t scan = zipLen < 65557 ? zipLen : 65557;
    for (size_t i = zipLen - scan; i + 22 <= zipLen; ++i) {
        if (Rd32(zip + i) == 0x06054b50) eocd = i;  // keep last match
    }
    if (eocd == SIZE_MAX) return false;
    std::uint32_t count = Rd16(zip + eocd + 10);
    size_t cd = Rd32(zip + eocd + 16);
    for (std::uint32_t n = 0; n < count; ++n) {
        if (cd + 46 > zipLen || Rd32(zip + cd) != 0x02014b50) return false;
        std::uint16_t method = Rd16(zip + cd + 10);
        std::uint32_t comp = Rd32(zip + cd + 20);
        std::uint32_t uncomp = Rd32(zip + cd + 24);
        std::uint16_t nameLen = Rd16(zip + cd + 28);
        std::uint16_t extraLen = Rd16(zip + cd + 30);
        std::uint16_t commentLen = Rd16(zip + cd + 32);
        std::uint32_t localOff = Rd32(zip + cd + 42);
        if (cd + 46 + nameLen + extraLen + commentLen > zipLen) return false;
        std::string name((const char*)zip + cd + 46, nameLen);
        cd += 46 + nameLen + extraLen + commentLen;
        if (method != 0 || comp != uncomp) return false;   // stored only
        if (comp == 0xFFFFFFFFu) return false;             // no ZIP64
        bool isDir = !name.empty() && name.back() == '/';
        std::wstring rel;
        if (!SanitizeEntryName(name, &rel)) return false;
        std::wstring target;
        if (!NormalizePath(destRoot + L"\\" + rel, &target)) return false;
        if (target.compare(0, destRoot.size(), destRoot) != 0 ||
            target.size() <= destRoot.size() ||
            target[destRoot.size()] != L'\\')
            return false;
        if (isDir) {
            if (!EnsureDir(target)) return false;
            continue;
        }
        if (localOff + 30 > zipLen || Rd32(zip + localOff) != 0x04034b50)
            return false;
        std::uint16_t lName = Rd16(zip + localOff + 26);
        std::uint16_t lExtra = Rd16(zip + localOff + 28);
        size_t dataOff = (size_t)localOff + 30 + lName + lExtra;
        if (dataOff + comp > zipLen) return false;
        if (!EnsureParents(target)) return false;
        HANDLE f = CreateFileW(target.c_str(), GENERIC_WRITE, 0, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f == INVALID_HANDLE_VALUE) return false;
        bool ok = true;
        size_t written = 0;
        while (written < comp) {
            DWORD chunk = (DWORD)std::min<size_t>(comp - written, 1 << 20);
            DWORD w = 0;
            if (!WriteFile(f, zip + dataOff + written, chunk, &w, nullptr) ||
                w != chunk) {
                ok = false;
                break;
            }
            written += w;
        }
        CloseHandle(f);
        if (!ok) return false;
    }
    return true;
}

// Everything after the first token (the exe path) of the command line.
std::wstring CommandLineTail(const wchar_t* cmd) {
    if (!cmd) return L"";
    const wchar_t* p = cmd;
    if (*p == L'"') {
        ++p;
        while (*p && *p != L'"') ++p;
        if (*p == L'"') ++p;
    } else {
        while (*p && *p != L' ' && *p != L'\t') ++p;
    }
    while (*p == L' ' || *p == L'\t') ++p;
    return std::wstring(p);
}

std::wstring BaseName(const std::wstring& path) {
    size_t slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

bool IEquals(const std::wstring& a, const wchar_t* b) {
    return _wcsicmp(a.c_str(), b) == 0;
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    wchar_t selfPath[MAX_PATH * 4];
    if (!GetModuleFileNameW(nullptr, selfPath, (DWORD)std::size(selfPath)))
        return Fail(L"Cannot resolve the setup executable path.");
    std::wstring self(selfPath);

    HANDLE file = CreateFileW(self.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return Fail(L"Cannot open the setup executable.");
    LARGE_INTEGER sizeLi;
    if (!GetFileSizeEx(file, &sizeLi) || sizeLi.QuadPart < (LONGLONG)kFooterSize) {
        CloseHandle(file);
        return Fail(L"This setup file is incomplete (missing footer).");
    }
    std::uint64_t fileSize = (std::uint64_t)sizeLi.QuadPart;

    std::uint8_t footer[kFooterSize];
    if (!ReadExact(file, fileSize - kFooterSize, footer, (DWORD)kFooterSize)) {
        CloseHandle(file);
        return Fail(L"Cannot read the setup footer.");
    }
    if (memcmp(footer, kFooterMagic, 8) != 0 || Rd32(footer + 8) != 1) {
        CloseHandle(file);
        return Fail(L"This setup file is not a valid AuraDSP package.");
    }
    std::uint64_t offW = Rd64(footer + 16), lenW = Rd64(footer + 24);
    std::uint64_t offP = Rd64(footer + 32), lenP = Rd64(footer + 40);
    const std::uint8_t* wantSha = footer + 48;
    if (offW == 0 || offW + lenW != offP || offP + lenP + kFooterSize != fileSize ||
        lenW > kMaxWizardBytes || lenP > kMaxPayloadBytes) {
        CloseHandle(file);
        return Fail(L"Setup package layout is corrupted.");
    }

    // 1) Verify product payload integrity before running anything.
    std::uint8_t gotSha[32];
    if (!Sha256Range(file, offP, lenP, gotSha) ||
        memcmp(gotSha, wantSha, 32) != 0) {
        CloseHandle(file);
        return Fail(L"Payload integrity check failed (SHA256 mismatch).\n"
                    L"Please re-download the installer.");
    }
    char shaTag[9];
    static const char* kHex = "0123456789abcdef";
    for (int i = 0; i < 4; ++i) {
        shaTag[2 * i] = kHex[gotSha[i] >> 4];
        shaTag[2 * i + 1] = kHex[gotSha[i] & 15];
    }
    shaTag[8] = 0;

    // 2) Extract the wizard runtime (ZIP-W, stored entries only).
    std::vector<std::uint8_t> zipW((size_t)lenW);
    if (!ReadExact(file, offW, zipW.data(), (DWORD)lenW)) {
        CloseHandle(file);
        return Fail(L"Cannot read the wizard segment.");
    }
    CloseHandle(file);

    wchar_t tempRoot[MAX_PATH];
    if (!GetTempPathW((DWORD)std::size(tempRoot), tempRoot))
        return Fail(L"Cannot resolve the temp directory.");
    std::wstring base = std::wstring(tempRoot) + L"AuraDSP-Setup";
    EnsureDir(base);
    // Best-effort sweep of stale session dirs from earlier runs.
    {
        WIN32_FIND_DATAW fd;
        HANDLE h = FindFirstFileW((base + L"\\*").c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                    std::wstring name = fd.cFileName;
                    if (name != L"." && name != L"..")
                        DeleteTreeBestEffort(base + L"\\" + name);
                }
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
    }
    std::wstring session =
        base + L"\\" + std::wstring(shaTag, shaTag + 8) + L"-" +
        std::to_wstring(GetCurrentProcessId());
    std::wstring wizardDir = session + L"\\wizard";
    if (!EnsureDir(session) || !EnsureDir(wizardDir))
        return Fail(L"Cannot create the temp extraction directory.");
    if (!ExtractStoredZip(zipW.data(), zipW.size(), wizardDir)) {
        DeleteTreeBestEffort(session);
        return Fail(L"Failed to extract the wizard runtime.");
    }
    std::wstring wizardExe = wizardDir + L"\\auradsp_setup.exe";
    if (GetFileAttributesW(wizardExe.c_str()) == INVALID_FILE_ATTRIBUTES) {
        DeleteTreeBestEffort(session);
        return Fail(L"Wizard executable is missing from the package.");
    }

    // 3) Launch the wizard with forwarded + appended arguments.
    std::wstring tail = CommandLineTail(GetCommandLineW());
    std::wstring cmd = L"\"" + wizardExe + L"\"";
    if (!tail.empty()) cmd += L" " + tail;
    bool uninstall = IEquals(BaseName(self), L"uninstall.exe") ||
                     tail.find(L"--uninstall") != std::wstring::npos;
    if (uninstall && tail.find(L"--mode") == std::wstring::npos)
        cmd += L" --mode uninstall";
    cmd += L" --setup-exe \"" + self + L"\" --payload-off ";
    cmd += std::to_wstring(offP);
    cmd += L" --payload-len ";
    cmd += std::to_wstring(lenP);
    cmd += L" --session-dir \"" + session + L"\"";

    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(L'\0');
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(wizardExe.c_str(), cmdBuf.data(), nullptr, nullptr,
                        FALSE, 0, nullptr, wizardDir.c_str(), &si, &pi)) {
        DeleteTreeBestEffort(session);
        return Fail(L"Failed to launch the setup wizard.");
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
