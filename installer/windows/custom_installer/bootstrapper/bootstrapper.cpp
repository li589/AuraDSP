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
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <shlobj.h>
#include <sddl.h>
#include <aclapi.h>

#include <trusted_publisher.h>

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

int HexValue(wchar_t c) {
    if (c >= L'0' && c <= L'9') return c - L'0';
    if (c >= L'a' && c <= L'f') return c - L'a' + 10;
    if (c >= L'A' && c <= L'F') return c - L'A' + 10;
    return -1;
}

bool ParseSha256(const std::wstring& text, std::uint8_t out[32]) {
    if (text.size() != 64) return false;
    for (int i = 0; i < 32; ++i) {
        int hi = HexValue(text[2 * i]), lo = HexValue(text[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (std::uint8_t)((hi << 4) | lo);
    }
    return true;
}

std::wstring Sha256Hex(const std::uint8_t sha[32]) {
    static const wchar_t* kHex = L"0123456789abcdef";
    std::wstring out(64, L'0');
    for (int i = 0; i < 32; ++i) {
        out[2 * i] = kHex[sha[i] >> 4];
        out[2 * i + 1] = kHex[sha[i] & 15];
    }
    return out;
}

struct ElevationArgs {
    bool resume = false;
    bool externalSession = false;
    std::wstring resumeSession;
    std::wstring expectedSha;
    std::wstring forwarded;
};

// Parse only the elevated-resume channel. The normal path retains its legacy
// forwarding behavior; the elevated path forwards a small allowlist and never
// trusts caller-supplied setup/session/payload locations.
bool ParseElevationArgs(ElevationArgs* out) {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return false;
    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        auto value = [&](std::wstring* dst) {
            if (i + 1 >= argc) return false;
            *dst = argv[++i];
            return true;
        };
        if (a == L"--elevated-resume") {
            out->resume = true;
            value(&out->resumeSession);
        } else if (a == L"--payload-sha256") {
            value(&out->expectedSha);
        } else if (a == L"--protected-session" || a == L"--session-dir") {
            out->externalSession = true;
            if (i + 1 < argc) ++i;
        } else if (a == L"--auto-start" || a == L"--auto-uninstall" ||
                   a == L"--keep-data" || a == L"--no-keep-data" ||
                   a == L"--silent" || a == L"/silent" || a == L"/S" ||
                   a == L"--uninstall") {
            out->forwarded += L" " + a;
        } else if (a == L"--mode" && i + 1 < argc &&
                   std::wstring(argv[i + 1]) == L"uninstall") {
            out->forwarded += L" --mode uninstall";
            ++i;
        }
    }
    LocalFree(argv);
    return !out->resume || !out->resumeSession.empty();
}

bool IsProcessElevated() {
#ifdef AURADSP_SETUP_TEST_HARNESS
    return true;
#else
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
    TOKEN_ELEVATION elevation{};
    DWORD size = 0;
    bool ok = GetTokenInformation(token, TokenElevation, &elevation,
                                  sizeof(elevation), &size) &&
              elevation.TokenIsElevated != 0;
    CloseHandle(token);
    return ok;
#endif
}

bool VerifyTrustedPublisher(const std::wstring& path, HANDLE file) {
#ifdef AURADSP_SETUP_UNSIGNED_TEST_ONLY
    (void)path;
    (void)file;
    return true;
#else
    WINTRUST_FILE_INFO fileInfo{};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = path.c_str();
    fileInfo.hFile = file;
    WINTRUST_DATA trust{};
    trust.cbStruct = sizeof(trust);
    trust.dwUIChoice = WTD_UI_NONE;
    trust.fdwRevocationChecks = WTD_REVOKE_NONE;
    trust.dwUnionChoice = WTD_CHOICE_FILE;
    trust.pFile = &fileInfo;
    trust.dwStateAction = WTD_STATEACTION_VERIFY;
    trust.dwProvFlags = WTD_REVOCATION_CHECK_NONE;
    GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    LONG status = WinVerifyTrust(nullptr, &policy, &trust);
    trust.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(nullptr, &policy, &trust);
    if (status != ERROR_SUCCESS) return false;

    HCERTSTORE store = nullptr;
    HCRYPTMSG message = nullptr;
    bool ok = CryptQueryObject(CERT_QUERY_OBJECT_FILE, path.c_str(),
        CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED, CERT_QUERY_FORMAT_FLAG_BINARY,
        0, nullptr, nullptr, nullptr, &store, &message, nullptr) != 0;
    PCCERT_CONTEXT signer = nullptr;
    DWORD signerCount = 0;
    DWORD signerCountSize = sizeof(signerCount);
    std::vector<std::uint8_t> certIdBytes;
    if (ok && (!CryptMsgGetParam(message, CMSG_SIGNER_COUNT_PARAM, 0,
                                 &signerCount, &signerCountSize) ||
               signerCount != 1)) {
        ok = false;
    }
    if (ok) {
        DWORD certIdSize = 0;
        if (!CryptMsgGetParam(message, CMSG_SIGNER_CERT_ID_PARAM, 0,
                              nullptr, &certIdSize)) {
            ok = false;
        } else {
            certIdBytes.resize(certIdSize);
            if (!CryptMsgGetParam(message, CMSG_SIGNER_CERT_ID_PARAM, 0,
                                  certIdBytes.data(), &certIdSize)) {
                ok = false;
            } else {
                signer = CertFindCertificateInStore(store,
                    X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, 0,
                    CERT_FIND_CERT_ID, certIdBytes.data(), nullptr);
            }
        }
    }
    std::uint8_t thumb[20];
    DWORD thumbLen = sizeof(thumb);
    if (signer && !CryptHashCertificate(0, CALG_SHA1, 0,
            signer->pbCertEncoded, signer->cbCertEncoded, thumb, &thumbLen))
        ok = false;
    if (ok && signer) {
        std::uint8_t expected[20];
        std::wstring pin = AURADSP_TRUSTED_PUBLISHER_THUMBPRINT;
        if (pin.size() != 40) {
            ok = false;
        } else {
            for (int i = 0; i < 20; ++i) {
                int hi = HexValue(pin[2 * i]), lo = HexValue(pin[2 * i + 1]);
                if (hi < 0 || lo < 0) {
                    ok = false;
                    break;
                }
                expected[i] = (std::uint8_t)((hi << 4) | lo);
            }
            if (ok && memcmp(thumb, expected, 20) != 0) ok = false;
        }
    } else {
        ok = false;
    }
    if (signer) CertFreeCertificateContext(signer);
    if (message) CryptMsgClose(message);
    if (store) CertCloseStore(store, 0);
    return ok;
#endif
}

bool EnsureDir(const std::wstring& path);
bool NormalizePath(const std::wstring& in, std::wstring* out);

// Inspect the final object behind a directory handle, not just its path. The
// SDDL comparison intentionally accepts exactly the owner/DACL emitted below:
// no inheritance, no extra interactive-user ACE, and no reparse redirection.
bool ValidateProtectedDirectory(const std::wstring& path, std::wstring* finalPath) {
    HANDLE dir = CreateFileW(path.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        nullptr);
    if (dir == INVALID_HANDLE_VALUE) return false;
    bool ok = false;
    PSECURITY_DESCRIPTOR sd = nullptr;
    LPWSTR sddl = nullptr;
    do {
        FILE_ATTRIBUTE_TAG_INFO tag{};
        if (!GetFileInformationByHandleEx(dir, FileAttributeTagInfo, &tag,
                                          sizeof(tag)) ||
            !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
            (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT))
            break;
        if (GetSecurityInfo(dir, SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                nullptr, nullptr, nullptr, nullptr, &sd) != ERROR_SUCCESS)
            break;
        if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(sd,
                SDDL_REVISION_1,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                &sddl, nullptr))
            break;
        const wchar_t* kSystem =
            L"O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
        const wchar_t* kAdmins =
            L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
        if (wcscmp(sddl, kSystem) != 0 && wcscmp(sddl, kAdmins) != 0)
            break;
        std::wstring final(32768, L'\0');
        DWORD len = GetFinalPathNameByHandleW(dir, final.data(),
                                               (DWORD)final.size(), 0);
        if (len == 0 || len >= final.size()) break;
        final.resize(len);
        if (final.compare(0, 4, L"\\\\?\\") != 0) break;
        final.erase(0, 4);
        std::wstring normalized;
        if (!NormalizePath(path, &normalized) ||
            _wcsicmp(final.c_str(), normalized.c_str()) != 0)
            break;
        if (finalPath) *finalPath = final;
        ok = true;
    } while (false);
    if (sddl) LocalFree(sddl);
    if (sd) LocalFree(sd);
    CloseHandle(dir);
    return ok;
}

bool ApplyProtectedDacl(const std::wstring& path) {
    PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1,
            &sd, nullptr))
        return false;
    PACL dacl = nullptr;
    BOOL present = FALSE, defaulted = FALSE;
    bool ok = GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted) &&
              present && dacl &&
              SetNamedSecurityInfoW((LPWSTR)path.c_str(), SE_FILE_OBJECT,
                  DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                  nullptr, nullptr, dacl, nullptr) == ERROR_SUCCESS;
    LocalFree(sd);
    return ok;
}

bool CreateProtectedSession(const std::wstring& tag, std::wstring* out) {
    wchar_t programData[MAX_PATH];
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, 0,
                                programData)))
        return false;
    std::wstring base = std::wstring(programData) + L"\\AuraDSP-Setup-Protected";
    if (CreateDirectoryW(base.c_str(), nullptr)) {
        if (!ApplyProtectedDacl(base)) return false;
    } else {
        if (GetLastError() != ERROR_ALREADY_EXISTS) return false;
        // Never repair and then reuse an attacker-supplied root: its existing
        // owner, DACL, final path and reparse state must already be trusted.
    }
    if (!ValidateProtectedDirectory(base, nullptr)) return false;
    std::wstring session = base + L"\\" + tag + L"-" +
                           std::to_wstring(GetCurrentProcessId());
    if (!CreateDirectoryW(session.c_str(), nullptr) ||
        !ApplyProtectedDacl(session))
        return false;
    std::wstring finalSession;
    if (!ValidateProtectedDirectory(session, &finalSession)) return false;
    *out = finalSession;
    return true;
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

// Copy the already verified Setup through its original read-only handle. The
// destination is a new fixed-name file inside the protected session; never
// reopen the replaceable source path for this handoff.
bool CopySetupImage(HANDLE source, std::uint64_t size,
                    const std::wstring& dest) {
    HANDLE out = CreateFileW(dest.c_str(), GENERIC_WRITE, 0, nullptr,
                             CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (out == INVALID_HANDLE_VALUE) return false;
    std::vector<std::uint8_t> chunk(1 << 20);
    std::uint64_t done = 0;
    bool ok = true;
    while (done < size) {
        DWORD want = (DWORD)std::min<std::uint64_t>(size - done, chunk.size());
        if (!ReadExact(source, done, chunk.data(), want)) {
            ok = false;
            break;
        }
        DWORD written = 0;
        if (!WriteFile(out, chunk.data(), want, &written, nullptr) ||
            written != want) {
            ok = false;
            break;
        }
        done += written;
    }
    CloseHandle(out);
    if (!ok) DeleteFileW(dest.c_str());
    return ok;
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    wchar_t selfPath[MAX_PATH * 4];
    if (!GetModuleFileNameW(nullptr, selfPath, (DWORD)std::size(selfPath)))
        return Fail(L"Cannot resolve the setup executable path.");
    std::wstring self(selfPath);

    ElevationArgs elevation;
    if (!ParseElevationArgs(&elevation))
        return Fail(L"Invalid elevated setup resume arguments.");
    std::uint8_t expectedSha[32];
    HANDLE file = INVALID_HANDLE_VALUE;
    if (elevation.resume) {
        if (elevation.externalSession)
            return Fail(L"Elevated setup does not accept external session paths.");
        if (!IsProcessElevated())
            return Fail(L"Elevated setup resume requires an elevated process.");
        if (!ParseSha256(elevation.expectedSha, expectedSha))
            return Fail(L"Missing or invalid trusted payload SHA256.");
        // Open before verification and deny write/delete sharing until footer,
        // payload and ZIP-W have all been consumed. Path-based CMSG inspection
        // is then pinned to this same non-replaceable filesystem object.
        file = CreateFileW(self.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, 0, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            return Fail(L"Cannot open the setup executable.");
        if (!VerifyTrustedPublisher(self, file)) {
            CloseHandle(file);
            return Fail(L"Setup Authenticode or publisher verification failed.");
        }
    }

    // Fast single-instance pre-check: the wizard holds this mutex
    // for its whole lifetime (see the wizard runner). Advisory
    // only -- two shells can both pass before either wizard starts,
    // so the wizard re-checks authoritatively. Skips the expensive
    // payload hash + extraction when an instance is already up. Elevated
    // resume skips this pre-check: the wizard's authoritative --resume-options
    // path waits for the unelevated owner to exit and release the mutex.
    if (!elevation.resume) {
        HANDLE existing =
            OpenMutexW(SYNCHRONIZE, FALSE, L"AuraDSP-Setup-Instance");
        if (existing) {
            CloseHandle(existing);
            std::wstring tail0 = CommandLineTail(GetCommandLineW());
            bool silent =
                tail0.find(L"/silent") != std::wstring::npos ||
                tail0.find(L"--silent") != std::wstring::npos ||
                tail0.find(L"/S") != std::wstring::npos;
            if (!silent) {
                MessageBoxW(
                    nullptr,
                    L"AuraDSP 安装程序已在运行，请切换到已打开的安装窗口继续。\n\n"
                    L"Another AuraDSP Setup is already running. "
                    L"Switch to the open Setup window to continue.",
                    L"AuraDSP Setup", MB_OK | MB_ICONINFORMATION);
            }
            return 1;
        }
    }

    if (file == INVALID_HANDLE_VALUE) {
        file = CreateFileW(self.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, 0, nullptr);
        if (file == INVALID_HANDLE_VALUE)
            return Fail(L"Cannot open the setup executable.");
    }
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
        memcmp(gotSha, wantSha, 32) != 0 ||
        (elevation.resume && memcmp(gotSha, expectedSha, 32) != 0)) {
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

    std::wstring session;
    if (elevation.resume) {
        if (!CreateProtectedSession(std::wstring(shaTag, shaTag + 8), &session)) {
            CloseHandle(file);
            return Fail(L"Cannot create the protected elevated session.");
        }
    } else {
        CloseHandle(file);
        file = INVALID_HANDLE_VALUE;
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
        session = base + L"\\" + std::wstring(shaTag, shaTag + 8) + L"-" +
                  std::to_wstring(GetCurrentProcessId());
        if (!EnsureDir(session))
            return Fail(L"Cannot create the temp extraction directory.");
    }
    std::wstring setupImage = self;
    if (elevation.resume) {
        setupImage = session + L"\\setup-image.exe";
        if (!CopySetupImage(file, fileSize, setupImage)) {
            CloseHandle(file);
            DeleteTreeBestEffort(session);
            return Fail(L"Cannot protect the complete setup image.");
        }
        CloseHandle(file);
        file = INVALID_HANDLE_VALUE;
    }
    std::wstring wizardDir = session + L"\\wizard";
    if (!EnsureDir(wizardDir)) {
        DeleteTreeBestEffort(session);
        return Fail(L"Cannot create the wizard extraction directory.");
    }
    if (!ExtractStoredZip(zipW.data(), zipW.size(), wizardDir)) {
        DeleteTreeBestEffort(session);
        return Fail(L"Failed to extract the wizard runtime.");
    }
    std::wstring wizardExe = wizardDir + L"\\auradsp_setup.exe";
    if (GetFileAttributesW(wizardExe.c_str()) == INVALID_FILE_ATTRIBUTES) {
        DeleteTreeBestEffort(session);
        return Fail(L"Wizard executable is missing from the package.");
    }

    // 3) Launch the wizard. Elevated resume uses only allowlisted UI state;
    // all executable, payload and session locations are rebuilt locally.
    std::wstring tail = elevation.resume ? elevation.forwarded
                                         : CommandLineTail(GetCommandLineW());
    std::wstring cmd = L"\"" + wizardExe + L"\"";
    if (!tail.empty()) cmd += L" " + tail;
    bool uninstall = IEquals(BaseName(self), L"uninstall.exe") ||
                     tail.find(L"--uninstall") != std::wstring::npos;
    if (uninstall && tail.find(L"--mode") == std::wstring::npos)
        cmd += L" --mode uninstall";
    if (elevation.resume && uninstall) {
        size_t slash = self.find_last_of(L"\\/");
        std::wstring oldManifest =
            self.substr(0, slash == std::wstring::npos ? 0 : slash + 1) +
            L"install_manifest.json";
        std::wstring newManifest = session + L"\\install_manifest.json";
        if (!CopyFileW(oldManifest.c_str(), newManifest.c_str(), FALSE)) {
            DeleteTreeBestEffort(session);
            return Fail(L"Cannot protect the elevated uninstall manifest.");
        }
    }
    if (elevation.resume) {
        std::wstring oldState = elevation.resumeSession + L"\\resume_options.json";
        std::wstring newState = session + L"\\resume_options.json";
        if (GetFileAttributesW(oldState.c_str()) != INVALID_FILE_ATTRIBUTES) {
            if (!CopyFileW(oldState.c_str(), newState.c_str(), FALSE)) {
                DeleteTreeBestEffort(session);
                return Fail(L"Cannot protect the elevated resume state.");
            }
            cmd += L" --resume-options \"" + newState + L"\"";
        }
        cmd += L" --elevated --protected-session \"" + session + L"\"";
    }
    cmd += L" --setup-exe \"" + setupImage + L"\" --payload-off ";
    cmd += std::to_wstring(offP);
    cmd += L" --payload-len ";
    cmd += std::to_wstring(lenP);
    cmd += L" --payload-sha256 \"" + Sha256Hex(gotSha) + L"\"";
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
