#!/usr/bin/env python3
"""Windows Setup 提权完整性回归测试（无 UAC、无真实安装）。

C++ harness 直接包含并执行生产 bootstrapper.cpp，只拦截进程启动、路径
解析和消息框；签名检查由显式测试宏跳过，绝不修改证书或系统信任存储。
Dart 侧用 flutter test 执行生产参数解析与载荷摘要校验。
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "installer"
BOOTSTRAPPER_DIR = INSTALLER / "windows" / "custom_installer" / "bootstrapper"
WIZARD = INSTALLER / "windows" / "custom_installer" / "wizard"
sys.path.insert(0, str(INSTALLER))

from packkit.paths import ENV_SANITIZER  # noqa: E402
from packkit.windows import setup_image  # noqa: E402

FAILURES: list[str] = []


def check(name: str, cond: bool, extra: str = "") -> None:
    print(f"  {'PASS' if cond else 'FAIL'} {name} {extra}")
    if not cond:
        FAILURES.append(name)


def stored_zip(entries: dict[str, bytes]) -> bytes:
    import io

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return buf.getvalue()


HARNESS = r'''
#include <windows.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <shlobj.h>
#include <sddl.h>
#include <aclapi.h>
#include <iostream>
#include <map>
#include <string>

static auto RealCreateFileW = &::CreateFileW;

#define AURADSP_SETUP_TEST_HARNESS
#define wWinMain BootstrapperEntry
#define GetModuleFileNameW TestGetModuleFileNameW
#define GetCommandLineW TestGetCommandLineW
#define GetTempPathW TestGetTempPathW
#define SHGetFolderPathW TestSHGetFolderPathW
#define CreateFileW TestCreateFileW
#define CreateProcessW TestCreateProcessW
#define MessageBoxW TestMessageBoxW
#define OpenMutexW TestOpenMutexW
#define SetNamedSecurityInfoW TestSetNamedSecurityInfoW
#define GetSecurityInfo TestGetSecurityInfo
#define GetFileInformationByHandleEx TestGetFileInformationByHandleEx
#define GetFinalPathNameByHandleW TestGetFinalPathNameByHandleW
#ifdef AURADSP_SETUP_TEST_VERIFY_MOCKS
#define WinVerifyTrust TestWinVerifyTrust
#define CryptQueryObject TestCryptQueryObject
#define CryptMsgGetParam TestCryptMsgGetParam
#define CertFindCertificateInStore TestCertFindCertificateInStore
#define CryptHashCertificate TestCryptHashCertificate
#define CertFreeCertificateContext TestCertFreeCertificateContext
#define CryptMsgClose TestCryptMsgClose
#define CertCloseStore TestCertCloseStore
#endif

static std::wstring g_setup;
static std::wstring g_replacement;
static std::wstring g_temp;
static std::wstring g_program_data;
static std::wstring g_command_line;
static std::wstring g_launched_app;
static std::wstring g_launched_cmd;
static std::wstring g_root_mode = L"new";
static bool g_launched = false;
static bool g_existing_mutex = false;
static bool g_replace_after_verify = false;
static bool g_replace_attempted = false;
static bool g_replace_succeeded = false;
static bool g_verify_had_handle = false;
static bool g_verify_share_read_only = false;
static int g_security_queries = 0;
static int g_reparse_queries = 0;
static int g_final_path_queries = 0;
static std::map<HANDLE, std::wstring> g_handle_paths;
static std::map<HANDLE, DWORD> g_handle_shares;

static std::wstring ProtectedBase() {
    return g_program_data + L"\\AuraDSP-Setup-Protected";
}
static bool IsProtectedPath(const std::wstring& path) {
    std::wstring base = ProtectedBase();
    return _wcsicmp(path.c_str(), base.c_str()) == 0 ||
           (path.size() > base.size() &&
            _wcsnicmp(path.c_str(), base.c_str(), base.size()) == 0 &&
            path[base.size()] == L'\\');
}
static DWORD CopyPath(const std::wstring& src, LPWSTR dst, DWORD cap) {
    if (src.size() + 1 > cap) return 0;
    wcscpy_s(dst, cap, src.c_str());
    return static_cast<DWORD>(src.size());
}
static HANDLE TestCreateFileW(LPCWSTR path, DWORD access, DWORD share,
    LPSECURITY_ATTRIBUTES sa, DWORD disposition, DWORD flags, HANDLE tmpl) {
    HANDLE h = RealCreateFileW(path, access, share, sa, disposition, flags, tmpl);
    if (h != INVALID_HANDLE_VALUE) {
        g_handle_paths[h] = path;
        g_handle_shares[h] = share;
    }
    return h;
}
static DWORD TestGetModuleFileNameW(HMODULE, LPWSTR p, DWORD n) {
    return CopyPath(g_setup, p, n);
}
static LPWSTR TestGetCommandLineW() { return g_command_line.data(); }
static DWORD TestGetTempPathW(DWORD n, LPWSTR p) {
    return CopyPath(g_temp, p, n);
}
static HRESULT TestSHGetFolderPathW(HWND, int, HANDLE, DWORD, LPWSTR p) {
    return CopyPath(g_program_data, p, MAX_PATH) ? S_OK : E_FAIL;
}
static BOOL TestCreateProcessW(LPCWSTR app, LPWSTR cmd, LPSECURITY_ATTRIBUTES,
    LPSECURITY_ATTRIBUTES, BOOL, DWORD, LPVOID, LPCWSTR, LPSTARTUPINFOW,
    LPPROCESS_INFORMATION pi) {
    g_launched = true;
    g_launched_app = app ? app : L"";
    g_launched_cmd = cmd ? cmd : L"";
    pi->hProcess = nullptr;
    pi->hThread = nullptr;
    return TRUE;
}
static int TestMessageBoxW(HWND, LPCWSTR, LPCWSTR, UINT) { return IDOK; }
static HANDLE TestOpenMutexW(DWORD, BOOL, LPCWSTR) {
    return g_existing_mutex ? reinterpret_cast<HANDLE>(1) : nullptr;
}
static DWORD TestSetNamedSecurityInfoW(LPWSTR, SE_OBJECT_TYPE,
    SECURITY_INFORMATION, PSID, PSID, PACL, PACL) { return ERROR_SUCCESS; }
static DWORD TestGetSecurityInfo(HANDLE h, SE_OBJECT_TYPE,
    SECURITY_INFORMATION, PSID*, PSID*, PACL*, PACL*,
    PSECURITY_DESCRIPTOR* out) {
    if (!out) return ERROR_INVALID_PARAMETER;
    auto it = g_handle_paths.find(h);
    if (it == g_handle_paths.end() || !IsProtectedPath(it->second))
        return ERROR_ACCESS_DENIED;
    ++g_security_queries;
    const wchar_t* sddl =
        L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
    if (_wcsicmp(it->second.c_str(), ProtectedBase().c_str()) == 0 &&
        g_root_mode == L"existing-bad-owner") {
        sddl = L"O:S-1-5-21-1-2-3-1000D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
    } else if (_wcsicmp(it->second.c_str(), ProtectedBase().c_str()) == 0 &&
               g_root_mode == L"existing-extra-ace") {
        sddl = L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;BU)";
    }
    return ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl, SDDL_REVISION_1, out, nullptr) ? ERROR_SUCCESS : ERROR_GEN_FAILURE;
}
static BOOL TestGetFileInformationByHandleEx(HANDLE h,
    FILE_INFO_BY_HANDLE_CLASS infoClass, LPVOID out, DWORD size) {
    auto it = g_handle_paths.find(h);
    if (infoClass == FileAttributeTagInfo && out && size >= 8 &&
        it != g_handle_paths.end() && IsProtectedPath(it->second)) {
        ++g_reparse_queries;
        auto* tag = static_cast<FILE_ATTRIBUTE_TAG_INFO*>(out);
        tag->FileAttributes = FILE_ATTRIBUTE_DIRECTORY;
        tag->ReparseTag = 0;
        if ((g_root_mode == L"reparse-root" &&
             _wcsicmp(it->second.c_str(), ProtectedBase().c_str()) == 0) ||
            (g_root_mode == L"reparse-session" &&
             _wcsicmp(it->second.c_str(), ProtectedBase().c_str()) != 0)) {
            tag->FileAttributes |= FILE_ATTRIBUTE_REPARSE_POINT;
            tag->ReparseTag = IO_REPARSE_TAG_SYMLINK;
        }
        return TRUE;
    }
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
}
static DWORD TestGetFinalPathNameByHandleW(HANDLE h, LPWSTR out, DWORD cap,
    DWORD) {
    auto it = g_handle_paths.find(h);
    if (it == g_handle_paths.end() || !IsProtectedPath(it->second)) return 0;
    ++g_final_path_queries;
    return CopyPath(L"\\\\?\\" + it->second, out, cap);
}
#ifdef AURADSP_SETUP_TEST_VERIFY_MOCKS
static LONG TestWinVerifyTrust(HWND, GUID*, LPVOID data) {
    auto* trust = static_cast<WINTRUST_DATA*>(data);
    if (trust->dwStateAction == WTD_STATEACTION_CLOSE) return ERROR_SUCCESS;
    HANDLE h = trust->pFile ? trust->pFile->hFile : nullptr;
    g_verify_had_handle = h && h != INVALID_HANDLE_VALUE;
    auto share = g_handle_shares.find(h);
    g_verify_share_read_only = g_verify_had_handle &&
        share != g_handle_shares.end() && share->second == FILE_SHARE_READ;
    if (g_replace_after_verify && !g_replace_attempted) {
        g_replace_attempted = true;
        g_replace_succeeded = MoveFileExW(g_replacement.c_str(), g_setup.c_str(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
    }
    return ERROR_SUCCESS;
}
static BOOL TestCryptQueryObject(DWORD, const void*, DWORD, DWORD, DWORD,
    DWORD*, DWORD*, DWORD*, HCERTSTORE* store, HCRYPTMSG* msg, const void**) {
    if (store) *store = reinterpret_cast<HCERTSTORE>(1);
    if (msg) *msg = reinterpret_cast<HCRYPTMSG>(1);
    return TRUE;
}
static BOOL TestCryptMsgGetParam(HCRYPTMSG, DWORD param, DWORD,
    void* out, DWORD* size) {
    if (param == CMSG_SIGNER_COUNT_PARAM) {
        if (!size || *size < sizeof(DWORD)) return FALSE;
        *static_cast<DWORD*>(out) = 1;
        return TRUE;
    }
    if (param == CMSG_SIGNER_CERT_ID_PARAM) {
        if (!out) { *size = 4; return TRUE; }
        if (*size < 4) return FALSE;
        memset(out, 0x42, 4);
        *size = 4;
        return TRUE;
    }
    return FALSE;
}
static PCCERT_CONTEXT TestCertFindCertificateInStore(HCERTSTORE, DWORD, DWORD,
    DWORD, const void*, PCCERT_CONTEXT) {
    static BYTE encoded[1] = {0x30};
    static CERT_CONTEXT cert{};
    cert.pbCertEncoded = encoded;
    cert.cbCertEncoded = 1;
    return &cert;
}
static BOOL TestCryptHashCertificate(HCRYPTPROV_LEGACY, ALG_ID, DWORD,
    const BYTE*, DWORD, BYTE* out, DWORD* size) {
    static const BYTE thumb[20] = {
        0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,
        0xaa,0xbb,0xcc,0xdd,0xee,0xff,0x00,0x11,0x22,0x33};
    if (*size < sizeof(thumb)) return FALSE;
    memcpy(out, thumb, sizeof(thumb));
    *size = sizeof(thumb);
    return TRUE;
}
static BOOL TestCertFreeCertificateContext(PCCERT_CONTEXT) { return TRUE; }
static BOOL TestCryptMsgClose(HCRYPTMSG) { return TRUE; }
static BOOL TestCertCloseStore(HCERTSTORE, DWORD) { return TRUE; }
#endif

#include "bootstrapper.cpp"

static std::string Utf8(const std::wstring& value) {
    if (value.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, value.data(),
        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(),
        static_cast<int>(value.size()), out.data(), n, nullptr, nullptr);
    return out;
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 5) return 90;
    g_setup = argv[1];
    g_temp = argv[2];
    g_program_data = argv[3];
    std::wstring expected = argv[4];
    g_command_line = L"\"fixture.exe\" --elevated-resume \"" + g_temp +
        L"legacy-session\" --payload-sha256 \"" + expected +
        L"\" --auto-start";
    if (argc >= 6 && wcscmp(argv[5], L"-") != 0) {
        g_command_line += L" --protected-session \"" + std::wstring(argv[5]) + L"\"";
    }
    g_existing_mutex = argc >= 7 && wcscmp(argv[6], L"1") == 0;
    if (argc >= 8) g_root_mode = argv[7];
    if (argc >= 9) {
        g_replace_after_verify = true;
        g_replacement = argv[8];
    }
    int rc = BootstrapperEntry(nullptr, nullptr, nullptr, 0);
    std::cout << "RC=" << rc << "\nLAUNCHED=" << (g_launched ? 1 : 0)
              << "\nAPP=" << Utf8(g_launched_app)
              << "\nCMD=" << Utf8(g_launched_cmd)
              << "\nSECURITY_QUERIES=" << g_security_queries
              << "\nREPARSE_QUERIES=" << g_reparse_queries
              << "\nFINAL_PATH_QUERIES=" << g_final_path_queries
              << "\nVERIFY_HAD_HANDLE=" << (g_verify_had_handle ? 1 : 0)
              << "\nVERIFY_SHARE_READ_ONLY=" << (g_verify_share_read_only ? 1 : 0)
              << "\nREPLACE_ATTEMPTED=" << (g_replace_attempted ? 1 : 0)
              << "\nREPLACE_SUCCEEDED=" << (g_replace_succeeded ? 1 : 0)
              << std::endl;
    return rc;
}
'''


def build_harness(work: Path) -> tuple[Path, Path, Path]:
    src = work / "src"
    src.mkdir()
    (src / "harness.cpp").write_text(HARNESS, encoding="utf-8")
    (src / "trusted_publisher.h").write_text(
        "#pragma once\n#define AURADSP_TRUSTED_PUBLISHER_THUMBPRINT "
        'L"00112233445566778899AABBCCDDEEFF00112233"\n', encoding="utf-8")
    (src / "CMakeLists.txt").write_text(
        "cmake_minimum_required(VERSION 3.20)\n"
        "project(setup_elevation_integrity CXX)\n"
        "set(CMAKE_CXX_STANDARD 17)\n"
        "set(CMAKE_CXX_STANDARD_REQUIRED ON)\n"
        "add_executable(harness harness.cpp)\n"
        "add_executable(harness_signed_gate harness.cpp)\n"
        "add_executable(harness_verify_race harness.cpp)\n"
        "target_compile_definitions(harness PRIVATE AURADSP_SETUP_UNSIGNED_TEST_ONLY)\n"
        "target_compile_definitions(harness_verify_race PRIVATE AURADSP_SETUP_TEST_VERIFY_MOCKS)\n"
        f"target_include_directories(harness PRIVATE \"{src.as_posix()}\" \"{BOOTSTRAPPER_DIR.as_posix()}\")\n"
        f"target_include_directories(harness_signed_gate PRIVATE \"{src.as_posix()}\" \"{BOOTSTRAPPER_DIR.as_posix()}\")\n"
        f"target_include_directories(harness_verify_race PRIVATE \"{src.as_posix()}\" \"{BOOTSTRAPPER_DIR.as_posix()}\")\n"
        "target_link_libraries(harness PRIVATE bcrypt shell32 shlwapi wintrust crypt32 advapi32)\n"
        "target_link_libraries(harness_signed_gate PRIVATE bcrypt shell32 shlwapi wintrust crypt32 advapi32)\n"
        "target_link_libraries(harness_verify_race PRIVATE bcrypt shell32 shlwapi wintrust crypt32 advapi32)\n"
        "if(MSVC)\n"
        "  target_compile_options(harness PRIVATE /utf-8 /W4)\n"
        "  target_compile_options(harness_signed_gate PRIVATE /utf-8 /W4)\n"
        "  target_compile_options(harness_verify_race PRIVATE /utf-8 /W4)\n"
        "endif()\n",
        encoding="utf-8",
    )
    build = work / "build"
    configure = ["cmake", "-S", str(src), "-B", str(build)]
    if os.name == "nt":
        configure += ["-A", "x64"]
    for command in (configure, ["cmake", "--build", str(build), "--config", "Release"]):
        result = subprocess.run(command, capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
        if result.returncode != 0:
            raise RuntimeError((result.stdout + result.stderr).strip())
    exe = build / "Release" / "harness.exe"
    signed_gate = build / "Release" / "harness_signed_gate.exe"
    verify_race = build / "Release" / "harness_verify_race.exe"
    if not exe.is_file():
        exe = build / "harness"
        signed_gate = build / "harness_signed_gate"
        verify_race = build / "harness_verify_race"
    if not exe.is_file() or not signed_gate.is_file() or not verify_race.is_file():
        raise RuntimeError("native harness build did not produce all executables")
    return exe, signed_gate, verify_race


def make_case(root: Path) -> tuple[Path, str, int, int]:
    payload = stored_zip({"payload/auradsp_app.exe": b"MZ-original-payload"})
    payload_sha = hashlib.sha256(payload).hexdigest()
    wizard = stored_zip({
        "auradsp_setup.exe": b"MZ-harmless-fixture-wizard",
        "wizard_manifest.json": ('{"payloadSha256":"%s"}' % payload_sha).encode(),
    })
    setup = root / "setup.exe"
    setup_image.assemble(setup, b"MZ-shell" + b"\0" * 64, wizard, payload)
    footer = setup.read_bytes()[-setup_image.FOOTER_SIZE:]
    _magic, _fmt, _flags, _off_w, _len_w, off_p, len_p, _sha = struct.unpack(
        setup_image.FOOTER_FMT, footer)
    (root / "legacy-session").mkdir()
    (root / "legacy-session" / "resume_options.json").write_text(
        '{"installDir":"C:\\\\AuraDSP"}', encoding="utf-8")
    (root / "program-data").mkdir()
    return setup, payload_sha, off_p, len_p


def run_case(harness: Path, root: Path, expected: str,
             protected: Path | None = None,
             existing_mutex: bool = False,
             root_mode: str = "new",
             replacement: Path | None = None,
             setup_path: Path | None = None) -> subprocess.CompletedProcess[str]:
    cmd = [str(harness), str(setup_path or root / "setup.exe"), str(root) + os.sep,
           str(root / "program-data"), expected]
    if protected is not None:
        cmd.append(str(protected))
    elif existing_mutex:
        cmd.append("-")
    if existing_mutex:
        cmd.append("1")
    if root_mode != "new" or replacement is not None:
        while len(cmd) < 7:
            cmd.append("-")
        cmd.append(root_mode)
    if replacement is not None:
        cmd.append(str(replacement))
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=30)


def test_native_elevation(work: Path) -> None:
    print("== elevated bootstrapper：真实 wWinMain + 拦截进程启动 ==")
    harness, signed_gate, verify_race = build_harness(work)

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        _setup, sha, _off, _len = make_case(root)
        r = run_case(signed_gate, root, sha)
        check("未签名构建无显式测试宏时失败关闭",
              r.returncode != 0 and "LAUNCHED=0" in r.stdout, r.stdout.strip())

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        _setup, sha, _off, _len = make_case(root)
        r = run_case(harness, root, "0" * 64)
        check("错误摘要拒绝进入解压/启动", r.returncode != 0 and "LAUNCHED=0" in r.stdout,
              r.stdout.strip())

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        setup, original_sha, off_p, len_p = make_case(root)
        blob = bytearray(setup.read_bytes())
        blob[off_p] ^= 0xFF
        replaced_sha = hashlib.sha256(blob[off_p:off_p + len_p]).digest()
        # 保留原 footer 的布局字段，只同步替换后的载荷摘要；预期摘要仍是最初值。
        old_footer = list(struct.unpack(setup_image.FOOTER_FMT,
                                        bytes(blob[-setup_image.FOOTER_SIZE:])))
        old_footer[-1] = replaced_sha
        setup.write_bytes(bytes(blob[:-setup_image.FOOTER_SIZE]) +
                          struct.pack(setup_image.FOOTER_FMT, *old_footer))
        r = run_case(harness, root, original_sha)
        check("同 offset/len 内容替换仍被原摘要拒绝",
              r.returncode != 0 and "LAUNCHED=0" in r.stdout, r.stdout.strip())

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        setup, original_sha, _off_p, _len_p = make_case(root)
        blob = bytearray(setup.read_bytes())
        original = b"MZ-harmless-fixture-wizard"
        evil = b"MZ-evil-----fixture-wizard"
        assert len(original) == len(evil)
        at = blob.index(original)
        blob[at:at + len(original)] = evil
        replacement = root / "replacement.exe"
        replacement.write_bytes(blob)
        r = run_case(verify_race, root, original_sha, replacement=replacement)
        valid = (r.returncode == 0 and "LAUNCHED=1" in r.stdout
                 and "VERIFY_HAD_HANDLE=1" in r.stdout
                 and "VERIFY_SHARE_READ_ONLY=1" in r.stdout
                 and "REPLACE_ATTEMPTED=1" in r.stdout
                 and "REPLACE_SUCCEEDED=0" in r.stdout
                 and b"MZ-evil" not in (root / "setup.exe").read_bytes())
        check("验签后替换 Setup/ZIP-W 被持久只读共享句柄阻止", valid, r.stdout.strip())

    for mode, label in (
        ("existing-bad-owner", "既有 protected 根目录所有者伪造"),
        ("existing-extra-ace", "既有 protected 根目录含交互用户 ACE"),
        ("reparse-root", "protected 根目录 reparse point"),
        ("reparse-session", "新建 session reparse point"),
    ):
        with tempfile.TemporaryDirectory(dir=work) as td:
            root = Path(td)
            _setup, sha, _off, _len = make_case(root)
            (root / "program-data" / "AuraDSP-Setup-Protected").mkdir()
            r = run_case(harness, root, sha, root_mode=mode)
            check(f"拒绝{label}", r.returncode != 0 and "LAUNCHED=0" in r.stdout,
                  r.stdout.strip())

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        _setup, sha, _off, _len = make_case(root)
        (root / "program-data" / "AuraDSP-Setup-Protected").mkdir()
        r = run_case(harness, root, sha, root_mode="existing-good")
        valid = (r.returncode == 0 and "LAUNCHED=1" in r.stdout
                 and "SECURITY_QUERIES=2" in r.stdout
                 and "REPARSE_QUERIES=2" in r.stdout
                 and "FINAL_PATH_QUERIES=2" in r.stdout)
        check("既有根仅在真实所有者/受保护 DACL/最终路径全部可信时复用",
              valid, r.stdout.strip())

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        _setup, sha, _off, _len = make_case(root)
        r = run_case(harness, root, sha, root / "user-writable-session")
        check("外部非保护 session 参数被拒绝",
              r.returncode != 0 and "LAUNCHED=0" in r.stdout, r.stdout.strip())

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        _setup, sha, _off, _len = make_case(root)
        r = run_case(harness, root, sha, existing_mutex=True)
        valid = (r.returncode == 0 and "LAUNCHED=1" in r.stdout
                 and "--protected-session" in r.stdout
                 and f"--payload-sha256 \"{sha}\"" in r.stdout.lower()
                 and str(root / "program-data").lower() in r.stdout.lower()
                 and "SECURITY_QUERIES=2" in r.stdout
                 and "REPARSE_QUERIES=2" in r.stdout
                 and "FINAL_PATH_QUERIES=2" in r.stdout)
        check("正确摘要仅从新建保护 session 启动", valid, r.stdout.strip())

    with tempfile.TemporaryDirectory(dir=work) as td:
        root = Path(td)
        setup, sha, off_p, len_p = make_case(root)
        original_image = setup.read_bytes()
        uninstall = root / "uninstall.exe"
        setup.rename(uninstall)
        (root / "install_manifest.json").write_text(
            '{"version":"1.0.0","installDir":"C:\\\\AuraDSP"}', encoding="utf-8")
        r = run_case(harness, root, sha, setup_path=uninstall)
        protected_root = root / "program-data" / "AuraDSP-Setup-Protected"
        sessions = list(protected_root.iterdir()) if protected_root.is_dir() else []
        image = sessions[0] / "setup-image.exe" if len(sessions) == 1 else None
        image_bytes = image.read_bytes() if image is not None and image.is_file() else b""
        layout_ok = False
        if image_bytes:
            footer = struct.unpack(setup_image.FOOTER_FMT,
                                   image_bytes[-setup_image.FOOTER_SIZE:])
            layout_ok = (footer[0] == setup_image.FOOTER_MAGIC
                         and footer[5] == off_p and footer[6] == len_p
                         and footer[3] + footer[4] == off_p
                         and off_p + len_p + setup_image.FOOTER_SIZE == len(image_bytes))
        valid = (len(sessions) == 1
                 and r.returncode == 0 and "LAUNCHED=1" in r.stdout
                 and image_bytes == original_image and layout_ok
                 and f'--setup-exe "{image}"' in r.stdout
                 and "--mode uninstall" in r.stdout
                 and (sessions[0] / "install_manifest.json").is_file())
        check("卸载启动只消费 protected 完整 Setup 映像并自动进入卸载模式",
              valid, r.stdout.strip())


DART_TEST = r'''
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:auradsp_setup/src/args.dart';
import 'package:auradsp_setup/src/engine/models.dart';
import 'package:auradsp_setup/src/engine/payload.dart';
import 'package:auradsp_setup/src/engine/win32.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = r'C:\ProgramData\AuraDSP-Setup-Protected';
  const session = r'C:\ProgramData\AuraDSP-Setup-Protected\abc-123';
  const goodSddl = 'O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)';

  SetupArgs args() => SetupArgs.parse([
        '--elevated', '--session-dir', session,
        '--protected-session', session,
        '--setup-exe', '$session\\setup-image.exe',
        '--resume-options', '$session\\resume_options.json',
      ]);
  ProtectedDirectoryAttributes fixture(String path,
          {String sddl = goodSddl, bool reparse = false}) =>
      ProtectedDirectoryAttributes(
        finalPath: path,
        securityDescriptor: sddl,
        isReparsePoint: reparse,
      );
  ProtectedDirectoryAttributes goodInspector(String path) => fixture(path);

  test('提权 UI 复核根与 session 的真实安全描述符和最终路径', () {
    expect(() => args().validateProtectedSession(inspector: goodInspector),
        returnsNormally);
    expect(
      () => args().validateProtectedSession(
        inspector: (path) => fixture(path,
            sddl: path == root
                ? 'O:S-1-5-21-1-2-3-1000D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
                : goodSddl),
      ),
      throwsStateError,
    );
    expect(
      () => args().validateProtectedSession(
        inspector: (path) => fixture(path,
            sddl: '$goodSddl(A;OICI;FA;;;BU)'),
      ),
      throwsStateError,
    );
    expect(
      () => args().validateProtectedSession(
        inspector: (path) => fixture(path, reparse: path == session),
      ),
      throwsStateError,
    );
    expect(
      () => args().validateProtectedSession(
        inspector: (path) => ProtectedDirectoryAttributes(
          finalPath: path == session ? r'C:\Users\Public\setup' : path,
          securityDescriptor: goodSddl,
        ),
      ),
      throwsStateError,
    );

    final bad = SetupArgs.parse([
      '--elevated', '--session-dir', r'C:\Users\Public\setup',
      '--protected-session', session,
    ]);
    expect(() => bad.validateProtectedSession(inspector: goodInspector),
        throwsStateError);
  });

  test('同一只读共享句柄复制并摘要载荷段', () async {
    final dir = await Directory.systemTemp.createTemp('auradsp-payload-sha-');
    try {
      final file = File('${dir.path}/setup.exe');
      final zip = File('${dir.path}/payload.zip');
      final payload = List<int>.generate(4096, (i) => (i * 31) & 0xff);
      await file.writeAsBytes(
          [...List<int>.filled(19, 7), ...payload, ...List<int>.filled(9, 3)]);
      final expected = sha256.convert(payload).toString();
      await verifyAndSlicePayload(
          file.path, 19, payload.length, expected, zip.path);
      expect(sha256.convert(await zip.readAsBytes()).toString(), expected);
      await expectLater(
        verifyAndSlicePayload(file.path, 19, payload.length, '0' * 64, zip.path),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        verifyAndSlicePayload(file.path, 19, payload.length, null, zip.path),
        throwsA(isA<StateError>()),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('卸载器复制 protected 完整 Setup 映像且不信任原路径', () async {
    final dir = await Directory.systemTemp.createTemp('auradsp-uninstaller-');
    try {
      final original = File('${dir.path}/setup.exe');
      final protectedDir = await Directory('${dir.path}/protected').create();
      final protectedImage = File('${protectedDir.path}/setup-image.exe');
      final zip = File('${dir.path}/payload.zip');
      final uninstaller = File('${dir.path}/uninstall.exe');
      final bootstrapper = <int>[0x4d, 0x5a, ...List<int>.filled(61, 7)];
      final wizard = List<int>.generate(257, (i) => (i * 17) & 0xff);
      final payload = List<int>.generate(4096, (i) => (i * 31) & 0xff);
      final offW = bootstrapper.length;
      final offP = offW + wizard.length;
      final footer = ByteData(80);
      for (var i = 0; i < 8; i++) {
        footer.setUint8(i, 'AURASTP1'.codeUnitAt(i));
      }
      footer.setUint32(8, 1, Endian.little);
      footer.setUint64(16, offW, Endian.little);
      footer.setUint64(24, wizard.length, Endian.little);
      footer.setUint64(32, offP, Endian.little);
      footer.setUint64(40, payload.length, Endian.little);
      final digest = sha256.convert(payload);
      for (var i = 0; i < digest.bytes.length; i++) {
        footer.setUint8(48 + i, digest.bytes[i]);
      }
      final fullImage = <int>[
        ...bootstrapper,
        ...wizard,
        ...payload,
        ...footer.buffer.asUint8List(),
      ];
      await original.writeAsBytes(fullImage);
      await protectedImage.writeAsBytes(fullImage, flush: true);
      final setupArgs = SetupArgs.parse([
        '--setup-exe', protectedImage.path,
        '--payload-off', '$offP',
        '--payload-len', '${payload.length}',
      ]);
      await verifyAndSlicePayload(setupArgs.setupExe!, offP, payload.length,
          digest.toString(), zip.path);

      // 载荷句柄关闭后，即使原始 Setup 被替换也只能复制 protected 映像。
      await original.writeAsBytes(List<int>.filled(fullImage.length, 0xa5));
      await copyProtectedSetupUninstaller(
          setupArgs.setupExe!, uninstaller.path);

      final actual = await uninstaller.readAsBytes();
      expect(actual, orderedEquals(fullImage));
      final actualFooter = ByteData.sublistView(
          Uint8List.fromList(actual), actual.length - 80);
      expect(String.fromCharCodes(actualFooter.buffer.asUint8List(
          actualFooter.offsetInBytes, 8)), 'AURASTP1');
      expect(actualFooter.getUint64(32, Endian.little), offP);
      expect(actualFooter.getUint64(40, Endian.little), payload.length);
      expect(offP + payload.length + 80, actual.length);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('可信清单在任何目标写入前拒绝清单外/重复/摘要不一致条目', () async {
    final dir = await Directory.systemTemp.createTemp('auradsp-manifest-');
    try {
      final dest = Directory('${dir.path}/install');
      final zip = File('${dir.path}/payload.zip');
      final archive = Archive()
        ..addFile(ArchiveFile('payload/ok.txt', 2, 'ok'.codeUnits))
        ..addFile(ArchiveFile('payload/evil.txt', 4, 'evil'.codeUnits));
      await zip.writeAsBytes(ZipEncoder().encode(archive));
      final trusted = <ManifestFile>[
        ManifestFile(
            path: 'ok.txt', size: 2, sha256: sha256.convert('ok'.codeUnits).toString()),
      ];
      await expectLater(
        extractPayload(zip.path, dest.path,
            include: (_) => false, trustedFiles: trusted),
        throwsStateError,
      );
      expect(File('${dest.path}/ok.txt').existsSync(), isFalse);
      expect(File('${dest.path}/evil.txt').existsSync(), isFalse);

      final duplicate = Archive()
        ..addFile(ArchiveFile('payload/ok.txt', 2, 'ok'.codeUnits))
        ..addFile(ArchiveFile('payload/OK.txt', 2, 'ok'.codeUnits));
      await zip.writeAsBytes(ZipEncoder().encode(duplicate));
      await expectLater(
        extractPayload(zip.path, dest.path,
            include: (_) => true, trustedFiles: trusted),
        throwsStateError,
      );
      expect(File('${dest.path}/ok.txt').existsSync(), isFalse);

      final badDigest = Archive()
        ..addFile(ArchiveFile('payload/ok.txt', 2, 'OK'.codeUnits));
      await zip.writeAsBytes(ZipEncoder().encode(badDigest));
      await expectLater(
        extractPayload(zip.path, dest.path,
            include: (_) => true, trustedFiles: trusted),
        throwsStateError,
      );
      expect(File('${dest.path}/ok.txt').existsSync(), isFalse);

      final validArchive = Archive()
        ..addFile(ArchiveFile('payload/ok.txt', 2, 'ok'.codeUnits));
      await zip.writeAsBytes(ZipEncoder().encode(validArchive));
      final missing = <ManifestFile>[
        ...trusted,
        ManifestFile(path: 'missing.txt', size: 0, sha256: '0' * 64),
      ];
      await expectLater(
        extractPayload(zip.path, dest.path,
            include: (_) => true, trustedFiles: missing),
        throwsStateError,
      );
      expect(File('${dest.path}/ok.txt').existsSync(), isFalse);

      final badSize = <ManifestFile>[
        ManifestFile(
            path: 'ok.txt', size: 3, sha256: trusted.single.sha256),
      ];
      await expectLater(
        extractPayload(zip.path, dest.path,
            include: (_) => true, trustedFiles: badSize),
        throwsStateError,
      );
      expect(File('${dest.path}/ok.txt').existsSync(), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
'''


def test_dart_integrity() -> None:
    print("== wizard：原摘要参数、保护 session、切片前复核 ==")
    engine = (WIZARD / "lib" / "src" / "engine" / "install_engine.dart").read_text(
        encoding="utf-8")
    check("安装引擎卸载器只复制 protected Setup 映像",
          "await copyProtectedSetupUninstaller(" in engine
          and "copyRunningWizardUninstaller" not in engine
          and "File(args.setupExe!).copy" not in engine)
    probe = WIZARD / "test" / "_task3_elevation_integrity_test.dart"
    probe.write_text(DART_TEST, encoding="utf-8")
    try:
        r = subprocess.run(
            [sys.executable, str(ENV_SANITIZER), "flutter", "test", str(probe)],
            cwd=WIZARD, capture_output=True, text=True, encoding="utf-8",
            errors="replace", timeout=240)
        check("Dart 提权完整性行为测试", r.returncode == 0,
              (r.stdout + r.stderr).strip())
    finally:
        probe.unlink(missing_ok=True)


def main() -> int:
    if os.name != "nt":
        print("FAIL: 本测试需要 Windows/MSVC；不执行真实提权或安装。")
        return 1
    if not shutil.which("cmake") or not shutil.which("flutter"):
        print("FAIL: 需要 cmake 与 flutter。")
        return 1
    with tempfile.TemporaryDirectory(prefix="auradsp-elevation-test-") as td:
        work = Path(td)
        try:
            test_native_elevation(work)
        except (subprocess.CalledProcessError, RuntimeError) as exc:
            check("native harness 构建/运行", False, str(exc))
    test_dart_integrity()
    print("ALL PASS" if not FAILURES else "FAILURES: " + ", ".join(FAILURES))
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    raise SystemExit(main())
