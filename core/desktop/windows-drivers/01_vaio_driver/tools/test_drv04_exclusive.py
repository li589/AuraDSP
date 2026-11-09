#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_drv04_exclusive.py — DRV-04 独占持有者反劫持验证（Windows 真机）

验证 AuraVAIO 控制设备（\\\\.\\AuraVaioControl）在 a81d56b 之后的
独占映射语义（common/AuraVaioIpc.h + 01_vaio_driver/src/ControlDevice.cpp）：

  1. 持有者进程 A MAP 成功并保持映射；
  2. 第二个进程 B 尝试 MAP        → 必须失败，Win32 错误 170 (ERROR_BUSY，
     内核 STATUS_DEVICE_BUSY = 0x80000011)；
  3. B 尝试 UNMAP A 的地址        → 必须失败，Win32 错误 5
     (ERROR_ACCESS_DENIED，内核 STATUS_ACCESS_DENIED = 0xC0000022)；
  4. A 自己 UNMAP                  → 必须成功（持有者释放顺畅）；
  5. A 释放后 B 再 MAP / UNMAP     → 必须成功（独占不残留）。

可选 --with-debug-log（要求驱动已含 GET_DEBUG_LOG 持有者校验的版本）：
  6. A 持有期间 B 调 GET_DEBUG_LOG → 必须失败，错误 5（读后清的破坏性
     读不得被非持有者触发）。

来源说明：a81d56b 真机验证时用的同名脚本为本机临时文件、未入库；
本文件 2026-11-05 应用户要求按 AuraVaioIpc.h 的 IOCTL/结构定义与
a81d56b 的实测结论（170 / 5）重建入库，断言口径与原验证一致。

真机验证记录：2026-11-09 于 vm-win10（192.168.204.129，Python 3.12.9，
驱动 .sys SHA256 前 16 位 2C64E03ACE123583）首次以 --with-debug-log 运行，
exit=0 / 7/7 ALL PASS；第 6 项 B 读 GET_DEBUG_LOG 被拒 winerror=5。
原始输出与结论见 test/date/2026-11-09/vaio-driver-e2e/outputs/。

运行环境：Windows 10/11 x64，驱动已安装且在运行，64 位 Python 3。
运行前请退出 AuraDSP 主程序/桥（映射被真实桥持有时本脚本会拒绝
开局，不抢占生产映射）。

用法：
  python test_drv04_exclusive.py [--with-debug-log]
退出码：0 = 全部断言通过；1 = 有断言失败；2 = 前置条件不满足。
"""

import ctypes
import json
import os
import subprocess
import sys
import tempfile
import time
from ctypes import wintypes

# ---------------------------------------------------------------------------
# IPC 契约（与 common/AuraVaioIpc.h 同步；CTL_CODE 现算，不抄魔数）
# ---------------------------------------------------------------------------
FILE_DEVICE_UNKNOWN = 0x22
METHOD_BUFFERED = 0
FILE_ANY_ACCESS = 0

def _ctl(fn):
    return (FILE_DEVICE_UNKNOWN << 16) | (FILE_ANY_ACCESS << 14) | (fn << 2) | METHOD_BUFFERED

IOCTL_GET_VERSION = _ctl(0x800)
IOCTL_MAP_SHARED_RING = _ctl(0x802)
IOCTL_UNMAP_SHARED_RING = _ctl(0x803)
IOCTL_GET_DEBUG_LOG = _ctl(0x804)

DEVICE_PATH = r"\\.\AuraVaioControl"
ERROR_BUSY = 170
ERROR_ACCESS_DENIED = 5

GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_READ = 0x1
FILE_SHARE_WRITE = 0x2
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


class MapRequest(ctypes.Structure):
    _fields_ = [("RequestedSize", wintypes.DWORD), ("Flags", wintypes.DWORD)]


class MapResponse(ctypes.Structure):
    _fields_ = [("UserAddress", ctypes.c_void_p)] + [
        (name, wintypes.DWORD)
        for name in (
            "TotalMappedSizeBytes", "HeaderSizeBytes", "DataSizeBytes",
            "SampleRate", "Channels", "BitsPerSample", "BlockAlign",
        )
    ]


class UnmapRequest(ctypes.Structure):
    _fields_ = [("UserAddress", ctypes.c_void_p)]


# AURA_DEBUG_LOG = Count(4B) + WriteIndex(4B) + 32 * ENTRY(136B) = 4360B
# （2026-11-08 审计低7 起 ENTRY 含 Timestamp100ns、头部加 WriteIndex；
# 缓冲取 8192 留余量——驱动先验长度后验持有者，缓冲不足会先报
# ERROR_INSUFFICIENT_BUFFER，掩盖本脚本要验的错误 5）
DEBUG_LOG_BUF = 8192

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateFileW.restype = wintypes.HANDLE
kernel32.CreateFileW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
    wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
]
kernel32.DeviceIoControl.restype = wintypes.BOOL
kernel32.DeviceIoControl.argtypes = [
    wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
    ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
    ctypes.c_void_p,
]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def open_device():
    h = kernel32.CreateFileW(
        DEVICE_PATH, GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, None, OPEN_EXISTING, 0, None)
    if h == INVALID_HANDLE_VALUE:
        raise ctypes.WinError(ctypes.get_last_error())
    return h


def ioctl(handle, code, in_obj=None, out_obj=None, out_size=0):
    """成功返回 bytesReturned；失败抛 OSError（.winerror 为 Win32 码）。"""
    in_buf = ctypes.byref(in_obj) if in_obj is not None else None
    in_size = ctypes.sizeof(in_obj) if in_obj is not None else 0
    out_buf = ctypes.byref(out_obj) if out_obj is not None else None
    if out_obj is None and out_size:
        out_buf = ctypes.create_string_buffer(out_size)
    returned = wintypes.DWORD(0)
    ok = kernel32.DeviceIoControl(
        handle, code, in_buf, in_size, out_buf,
        out_size if out_obj is None else ctypes.sizeof(out_obj),
        ctypes.byref(returned), None)
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())
    return returned.value


def try_map(handle):
    resp = MapResponse()
    ioctl(handle, IOCTL_MAP_SHARED_RING, MapRequest(0, 0), resp)
    return resp.UserAddress


def try_unmap(handle, address):
    ioctl(handle, IOCTL_UNMAP_SHARED_RING, UnmapRequest(address))


# ---------------------------------------------------------------------------
# 持有者子进程：MAP 后写 ready，等 release 文件出现后 UNMAP 自己并写 done
# ---------------------------------------------------------------------------
def hold_mode(workdir):
    ready = os.path.join(workdir, "ready.json")
    done = os.path.join(workdir, "done.json")
    release = os.path.join(workdir, "release")
    try:
        h = open_device()
    except OSError as e:
        with open(done, "w") as f:
            json.dump({"stage": "open", "error": e.winerror}, f)
        return 2
    try:
        addr = try_map(h)
    except OSError as e:
        with open(done, "w") as f:
            json.dump({"stage": "map", "error": e.winerror}, f)
        kernel32.CloseHandle(h)
        return 2
    with open(ready, "w") as f:
        json.dump({"address": addr, "pid": os.getpid()}, f)
    deadline = time.time() + 180
    while not os.path.exists(release):
        if time.time() > deadline:
            break
        time.sleep(0.1)
    unmap_error = None
    try:
        try_unmap(h, addr)
    except OSError as e:
        unmap_error = e.winerror
    kernel32.CloseHandle(h)
    with open(done, "w") as f:
        json.dump({"stage": "unmap", "error": unmap_error}, f)
    return 0 if unmap_error is None else 1


# ---------------------------------------------------------------------------
# 主流程：本进程扮演入侵者 B
# ---------------------------------------------------------------------------
class Checker:
    def __init__(self):
        self.failures = 0

    def check(self, name, cond, detail=""):
        print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail else ""))
        if not cond:
            self.failures += 1


def wait_for(path, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.1)
    return False


def main():
    with_debug_log = "--with-debug-log" in sys.argv
    ck = Checker()
    workdir = tempfile.mkdtemp(prefix="drv04_")
    ready = os.path.join(workdir, "ready.json")
    done = os.path.join(workdir, "done.json")
    release = os.path.join(workdir, "release")

    h_b = open_device()

    # 前置：不得有别的持有者（真实桥在跑就停下，别抢生产映射）
    try:
        probe_addr = try_map(h_b)
        try_unmap(h_b, probe_addr)
    except OSError as e:
        if e.winerror == ERROR_BUSY:
            print("前置失败：映射已被其他进程持有（AuraDSP 桥在运行？），"
                  "请先退出主程序再跑本脚本。")
            return 2
        raise

    holder = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "--hold", workdir])
    try:
        if not wait_for(ready):
            detail = ""
            if os.path.exists(done):
                detail = open(done).read()
            ck.check("持有者 A 完成 MAP", False, detail or "ready 超时")
            return 1
        holder_addr = json.load(open(ready))["address"]
        ck.check("持有者 A 完成 MAP", True, f"addr=0x{holder_addr:x}")

        # 2. B 抢 MAP → 170
        try:
            try_map(h_b)
            ck.check("B 抢 MAP 被拒 (ERROR_BUSY=170)", False, "竟然成功了")
        except OSError as e:
            ck.check("B 抢 MAP 被拒 (ERROR_BUSY=170)",
                     e.winerror == ERROR_BUSY, f"winerror={e.winerror}")

        # 3. B 抢 UNMAP → 5
        try:
            try_unmap(h_b, holder_addr)
            ck.check("B 抢 UNMAP 被拒 (ERROR_ACCESS_DENIED=5)", False, "竟然成功了")
        except OSError as e:
            ck.check("B 抢 UNMAP 被拒 (ERROR_ACCESS_DENIED=5)",
                     e.winerror == ERROR_ACCESS_DENIED, f"winerror={e.winerror}")

        # 6.（可选）B 读调试日志 → 5（驱动须含 GET_DEBUG_LOG 持有者校验）
        if with_debug_log:
            try:
                ioctl(h_b, IOCTL_GET_DEBUG_LOG, None, None, DEBUG_LOG_BUF)
                ck.check("B 读 GET_DEBUG_LOG 被拒 (ERROR_ACCESS_DENIED=5)",
                         False, "竟然成功了")
            except OSError as e:
                ck.check("B 读 GET_DEBUG_LOG 被拒 (ERROR_ACCESS_DENIED=5)",
                         e.winerror == ERROR_ACCESS_DENIED,
                         f"winerror={e.winerror}")

        # 4. 通知 A 释放；A 自行 UNMAP 必须成功
        open(release, "w").close()
        holder.wait(timeout=60)
        result = json.load(open(done)) if os.path.exists(done) else {}
        ck.check("持有者 A 自行 UNMAP 成功",
                 holder.returncode == 0 and result.get("error") is None,
                 f"rc={holder.returncode} result={result}")
    finally:
        if holder.poll() is None:
            holder.kill()

    # 5. 释放后 B 可正常 MAP / UNMAP
    try:
        addr = try_map(h_b)
        ck.check("释放后 B MAP 成功", True, f"addr=0x{addr:x}")
        try_unmap(h_b, addr)
        ck.check("释放后 B UNMAP 成功", True)
    except OSError as e:
        ck.check("释放后 B MAP/UNMAP 成功", False, f"winerror={e.winerror}")

    kernel32.CloseHandle(h_b)
    print("ALL PASS" if ck.failures == 0 else f"{ck.failures} FAIL")
    return 0 if ck.failures == 0 else 1


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--hold":
        sys.exit(hold_mode(sys.argv[2]))
    if os.name != "nt":
        print("本脚本只能在 Windows 真机运行（驱动控制设备验证）。")
        sys.exit(2)
    sys.exit(main())
