# -*- coding: utf-8 -*-
"""只读复现 app 的 AuraVAIO 驱动检测。

1) 直接调用随包 auravaio_bridge.dll 的 vaio_detect —— 与 app 的
   AuraVaioBridge.detect() / core.detectJson(8192) 同一个导出；
2) 单独测试控制设备 \\.\AuraVaioControl 的 CreateFileW 可打开性，
   区分「设备不存在」与「权限不足」；
3) 报告进程提权状态，用于对比 app 是否以管理员运行。
"""
import ctypes
import json
import os
import sys
from ctypes import wintypes

APP_DIR = r"C:\Users\li\AppData\Local\Programs\AuraDSP"
DLL = os.path.join(APP_DIR, "auravaio_bridge.dll")
DEV = r"\\.\AuraVaioControl"

_is_admin = False
try:
    _is_admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
except Exception:
    pass
# runas /trustlevel 启动的进程无控制台可回传，故按权限级别自写结果文件。
_tag = next((a[6:] for a in sys.argv[1:] if a.startswith("--tag=")), None)
_out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "probe-%s.out" % (_tag or ("admin" if _is_admin else "nonadmin")))
_orig_stdout = sys.stdout
sys.stdout = open(_out, "w", encoding="utf-8")


def token_elevation(pid):
    """返回 (elevated, elevationType, err)；用于判断 app 是否为受限令牌。"""
    try:
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        a = ctypes.WinDLL("advapi32", use_last_error=True)
        k.OpenProcess.restype = wintypes.HANDLE
        k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        a.OpenProcessToken.restype = wintypes.BOOL
        a.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                       ctypes.POINTER(wintypes.HANDLE)]
        a.GetTokenInformation.restype = wintypes.BOOL
        a.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                          wintypes.LPVOID, wintypes.DWORD,
                                          ctypes.POINTER(wintypes.DWORD)]
        h = k.OpenProcess(0x0400, False, pid)  # PROCESS_QUERY_INFORMATION
        if not h:
            return None, None, ctypes.get_last_error()
        tok = wintypes.HANDLE()
        if not a.OpenProcessToken(h, 0x0008, ctypes.byref(tok)):
            err = ctypes.get_last_error()
            k.CloseHandle(h)
            return None, None, err
        val = wintypes.DWORD()
        typ = wintypes.DWORD()
        ln = wintypes.DWORD()
        ok = a.GetTokenInformation(tok, 20, ctypes.byref(val), 4,
                                   ctypes.byref(ln))  # TokenElevation
        a.GetTokenInformation(tok, 18, ctypes.byref(typ), 4,
                              ctypes.byref(ln))      # TokenElevationType
        err = ctypes.get_last_error()
        a.CloseHandle(tok)
        k.CloseHandle(h)
        return (bool(val.value) if ok else None), typ.value, err
    except Exception as e:
        return None, None, repr(e)


def impersonate_pid(pid):
    """借用目标进程（如 explorer.exe）的未提升交互令牌，等价 asInvoker app。"""
    try:
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        a = ctypes.WinDLL("advapi32", use_last_error=True)
        k.OpenProcess.restype = wintypes.HANDLE
        k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        a.OpenProcessToken.restype = wintypes.BOOL
        a.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                       ctypes.POINTER(wintypes.HANDLE)]
        a.DuplicateToken.restype = wintypes.BOOL
        a.DuplicateToken.argtypes = [wintypes.HANDLE, ctypes.c_int,
                                     ctypes.POINTER(wintypes.HANDLE)]
        a.ImpersonateLoggedOnUser.restype = wintypes.BOOL
        a.ImpersonateLoggedOnUser.argtypes = [wintypes.HANDLE]
        h = k.OpenProcess(0x0400, False, pid)
        if not h:
            return False, "OpenProcess err=%s" % ctypes.get_last_error()
        tok = wintypes.HANDLE()
        if not a.OpenProcessToken(h, 0x0002 | 0x0004 | 0x0008,
                                  ctypes.byref(tok)):
            return False, "OpenProcessToken err=%s" % ctypes.get_last_error()
        imp = wintypes.HANDLE()
        if not a.DuplicateToken(tok, 2, ctypes.byref(imp)):
            return False, "DuplicateToken err=%s" % ctypes.get_last_error()
        ok = a.ImpersonateLoggedOnUser(imp)
        return bool(ok), "err=%s" % ctypes.get_last_error()
    except Exception as e:
        return False, repr(e)


print("PY=", sys.version.split()[0])
for _arg in sys.argv[1:]:
    if _arg.startswith("--impersonate="):
        _ok, _msg = impersonate_pid(int(_arg[14:]))
        print("IMPERSONATE|ok=%s|%s" % (_ok, _msg))
        try:
            print("IS_ADMIN_AFTER=", bool(ctypes.windll.shell32.IsUserAnAdmin()))
        except Exception as _e:
            print("IS_ADMIN_AFTER_ERR=", _e)
for _arg in sys.argv[1:]:
    if _arg.startswith("--pids="):
        for _p in _arg[7:].split(","):
            if not _p.strip():
                continue
            _e, _t, _err = token_elevation(int(_p))
            _tn = {1: "default", 2: "full", 3: "limited"}.get(_t, str(_t))
            print("APP_TOKEN|pid=%s|elevated=%s|type=%s|err=%s" % (_p, _e, _tn, _err))
print("APP_DIR=", APP_DIR)
print("DLL_EXISTS=", os.path.isfile(DLL))
try:
    print("IS_ADMIN=", bool(ctypes.windll.shell32.IsUserAnAdmin()))
except Exception as e:
    print("IS_ADMIN_ERR=", e)


def createfile(access):
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.CreateFileW.restype = wintypes.HANDLE
    k.CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    h = k.CreateFileW(DEV, access, 3, None, 3, 0, None)
    err = ctypes.get_last_error()
    ok = h not in (0, -1, 0xFFFFFFFFFFFFFFFF)
    if ok:
        k.CloseHandle(h)
    return ok, err, h


for label, acc in (("RW", 0xC0000000), ("RO", 0x80000000), ("NONE", 0)):
    ok, err, h = createfile(acc)
    print("CREATEFILE|%s|ok=%s|err=%s|handle=%s" % (label, ok, err, h))

if os.path.isfile(DLL):
    try:
        os.chdir(APP_DIR)
        if hasattr(os, "add_dll_directory"):
            os.add_dll_directory(APP_DIR)
        d = ctypes.CDLL(DLL)
        # 公共导出面已收敛为 ab_*（2026-10-30），app 的 AudioBridgeCore 也查 ab_detect。
        d.ab_detect.restype = ctypes.c_int
        d.ab_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
        buf = ctypes.create_string_buffer(8192)
        rc = d.ab_detect(buf, 8192)
        out = buf.value.decode("utf-8", "replace")
        print("VAIO_DETECT_RC=", rc)
        print("VAIO_DETECT_OUT=", out)
        try:
            j = json.loads(out)
            print("FOUND=", j.get("found"), "NOTE=", j.get("note"),
                  "TRACK=", j.get("track"), "VERSION=", j.get("driverVersion"))
        except Exception as e:
            print("JSON_PARSE_ERR=", e)
    except Exception as e:
        print("DLL_LOAD_ERR=", type(e).__name__, e)

sys.stdout.flush()
sys.stdout.close()
sys.stdout = _orig_stdout
print("WROTE=", _out)
