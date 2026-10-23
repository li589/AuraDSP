# -*- coding: utf-8 -*-
"""smoke_plugin_host_priority.py — F-4 门禁：宿主进程降级不得外溢到 RT 音频线程。

背景（代码审查报告-2026-10-22-增量 §4 / 未决清单 F-4）：
`plugin_host_client.cpp` 把宿主进程整体设为 BELOW_NORMAL（意图降插件分析
线程），静态审查担心它会把宿主音频线程一并降级、与 E6 的 MMCSS「Pro
Audio」+ TIME_CRITICAL 策略相反。

实测裁定（2026-10-23，本脚本）：进程类确实是 BELOW_NORMAL，但音频线程
实际优先级 = **15 (TIME_CRITICAL)**——MMCSS 注册会覆盖进程类，E6 的
TIME_CRITICAL 兜底在 BELOW_NORMAL 下同样映射到 15。降级只影响非 RT
线程（实测其余线程 NORMAL/HIGHEST），故 F-4 **无需修改**。

判据（防回归）：
1. 宿主进程类 == BELOW_NORMAL（降级仍在）；
2. 宿主线程中存在 ≥15 的优先级（MMCSS/兜底生效）；
3. 存在 < 0 或 base 更低的工作线程（降级确实作用到了非 RT 线程）——
   以「有线程相对优先级 <= 0」表达（BELOW_NORMAL 基类下 NORMAL=0）。

用法：python test/smoke/smoke_plugin_host_priority.py
"""
import ctypes
import json
import os
import sys
import time
from ctypes import wintypes

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                        "auradsp_engine.dll")
PLUGIN_NAME = "Convology"

PC = {0x40: "IDLE", 0x4000: "BELOW_NORMAL", 0x20: "NORMAL",
      0x8000: "ABOVE_NORMAL", 0x80: "HIGH", 0x100: "REALTIME"}
TP = {-15: "IDLE", -2: "LOWEST", -1: "BELOW_NORMAL", 0: "NORMAL",
      1: "ABOVE_NORMAL", 2: "HIGHEST", 15: "TIME_CRITICAL"}

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


class PE32(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_void_p),
                ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG), ("dwFlags", wintypes.DWORD),
                ("szExeFile", ctypes.c_char * 260)]


class TE32(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                ("th32ThreadID", wintypes.DWORD),
                ("th32OwnerProcessID", wintypes.DWORD),
                ("tpBasePri", wintypes.LONG), ("tpDeltaPri", wintypes.LONG),
                ("dwFlags", wintypes.DWORD)]


def main():
    os.environ["AURA_PLUGIN_HOST_MODE"] = "process"
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)

    d = ctypes.CDLL(DLL_PATH)
    d.auradsp_create.restype = ctypes.c_void_p
    d.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    d.auradsp_destroy.argtypes = [ctypes.c_void_p]
    d.auradsp_process.argtypes = [ctypes.c_void_p,
                                  ctypes.POINTER(ctypes.c_float),
                                  ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    d.auradsp_plugin_scan.restype = ctypes.c_int
    d.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_int]
    d.auradsp_plugin_get_item.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                          ctypes.c_char_p, ctypes.c_int]
    d.auradsp_plugin_slot_load.restype = ctypes.c_int
    d.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                           ctypes.c_char_p, ctypes.c_char_p]

    h = d.auradsp_create(48000.0, 1024)
    n = d.auradsp_plugin_scan(h, b"", 0)
    buf = ctypes.create_string_buffer(4096)
    target = None
    for i in range(n):
        d.auradsp_plugin_get_item(h, i, buf, len(buf))
        it = json.loads(buf.value.decode("utf-8", "replace"))
        if PLUGIN_NAME in it.get("name", ""):
            target = it
            break
    if not target:
        print(f"[SKIP] {PLUGIN_NAME} 未安装")
        d.auradsp_destroy(h)
        return 0
    if d.auradsp_plugin_slot_load(h, 0, target["path"].encode("utf-8"), b"") != 1:
        print("[SKIP] 插件加载失败（宿主不可用）")
        d.auradsp_destroy(h)
        return 0

    # 触发宿主懒启动 + 音频线程就绪
    B = 128
    ia = (ctypes.c_float * (B * 2))(*([0.05] * (B * 2)))
    oa = (ctypes.c_float * (B * 2))()
    for _ in range(30):
        d.auradsp_process(h, ia, oa, B)
    time.sleep(1.2)

    # 找宿主进程
    snap = k32.CreateToolhelp32Snapshot(0x2, 0)
    pe = PE32()
    pe.dwSize = ctypes.sizeof(PE32)
    pid = None
    if k32.Process32First(snap, ctypes.byref(pe)):
        while True:
            nm = pe.szExeFile.decode("mbcs", "replace").lower()
            if "auradsp_plugin_host" in nm:
                pid = pe.th32ProcessID
                break
            if not k32.Process32Next(snap, ctypes.byref(pe)):
                break
    k32.CloseHandle(snap)
    check("host 进程存在（进程外模式懒启动）", pid is not None, f"pid={pid}")
    if not pid:
        d.auradsp_destroy(h)
        return 1

    ph = k32.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
    cls = k32.GetPriorityClass(ph)
    k32.CloseHandle(ph)
    check("宿主进程类 == BELOW_NORMAL（降级仍在）", cls == 0x4000,
          PC.get(cls, hex(cls)))

    tsnap = k32.CreateToolhelp32Snapshot(0x4, 0)  # TH32CS_SNAPTHREAD
    te = TE32()
    te.dwSize = ctypes.sizeof(TE32)
    prios = []
    if k32.Thread32First(tsnap, ctypes.byref(te)):
        while True:
            if te.th32OwnerProcessID == pid:
                th = k32.OpenThread(0x0040, False, te.th32ThreadID)
                if th:
                    prios.append(k32.GetThreadPriority(th))
                    k32.CloseHandle(th)
            if not k32.Thread32Next(tsnap, ctypes.byref(te)):
                break
    k32.CloseHandle(tsnap)

    check("音频线程优先级 >= 15（MMCSS/兜底未被进程降级拖低）",
          prios and max(prios) >= 15, f"max={max(prios) if prios else None} "
          f"{TP.get(max(prios), '') if prios else ''}")
    check("工作线程确实被降（存在相对优先级 <= 0 的线程）",
          any(p <= 0 for p in prios), f"prios={sorted(prios)}")

    d.auradsp_destroy(h)
    time.sleep(0.3)
    print(f"[info] host threads: {sorted(prios)} → "
          f"{[TP.get(p, p) for p in sorted(prios)]}")
    print("HOST PRIORITY FAILURES:", fails if fails else "none")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
