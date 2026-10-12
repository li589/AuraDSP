#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_editor_topology.py — B3-② 回归：插件子窗口线程 ID == 宿主容器窗口线程 ID

背景（MEMORY.md 高频坑）：插件 GUI 的线程契约 = 宿主父窗口、插件子窗口、
消息泵必须在同一线程。只建父窗口在本线程、set_parent 在别的线程 → 子窗口
收不到 WM_PAINT（白框）+ 拖动无响应。用"子窗口线程 ID == 父窗口线程 ID"
直接断言。

架构现状（B3 重构后，CLAP/VST3 同构）：每实例专用 plugin main 线程承载
插件对象创建/初始化、全部 main-thread 任务与容器窗口消息泵；容器窗口类：
CLAP = AuraDSP_CLAP_Host_Window，VST3 = AuraDSP_VST3_Host_Window。

断言（每个可用插件）：
  1. slot_load 返回 1
  2. show_editor 返回 1
  3. 本进程内找得到容器窗口
  4. 容器下**有**子孙窗口（插件 GUI 已挂载）
  5. 全部子孙窗口的 owning thread == 容器 owning thread

插件缺失时判 [SKIP]（smoke 必须在没有这些插件的机器上也能过）。
"""
import ctypes
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")
if not os.path.exists(DLL):
    DLL = (r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release"
           r"\auradsp_engine.dll")

VST3_DIR = os.path.join(os.environ.get("CommonProgramFiles",
                                       r"C:\Program Files\Common Files"),
                        "VST3")
CLAP_DIR = os.path.join(os.environ.get("CommonProgramFiles",
                                       r"C:\Program Files\Common Files"),
                        "CLAP")

CASES = [
    # (名称, 容器窗口类名, bundle 路径, 插件 id 或 None)
    ("KV-Element-FX.clap（白框投诉主角，CLAP）",
     "AuraDSP_CLAP_Host_Window",
     os.path.join(CLAP_DIR, "KV-Element-FX.clap"),
     b"net.kushview.ElementFX"),
    ("Auto-Tune EFX+.vst3（B3 点名插件，VST3）",
     "AuraDSP_VST3_Host_Window",
     os.path.join(VST3_DIR, "Antares", "Auto-Tune EFX+.vst3"),
     None),
    ("FabFilter Pro-Q 3.vst3（对照组，VST3）",
     "AuraDSP_VST3_Host_Window",
     os.path.join(VST3_DIR, "FabFilter", "FabFilter Pro-Q 3.vst3"),
     None),
]

fails = []
skips = []


def check(cond, msg):
    print(f"  [{'PASS' if cond else 'FAIL'}] {msg}")
    if not cond:
        fails.append(msg)


def skip(msg):
    print(f"  [SKIP] {msg}")
    skips.append(msg)


def tid_of(hwnd):
    """GetWindowThreadProcessId：返回值是线程 ID，out 参数是进程 ID（勿搞反）。"""
    pid = ctypes.c_ulong(0)
    t = user32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd), ctypes.byref(pid))
    return t


def class_of(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(ctypes.c_void_p(hwnd), buf, 256)
    return buf.value


def descendants(hwnd, depth=0, max_depth=4):
    """递归枚举子孙窗口，返回 [(hwnd, class, tid, depth)]。"""
    out = []
    if depth > max_depth:
        return out
    kids = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_long)
    def cb(h, lp):
        kids.append(h)
        return True

    user32.EnumChildWindows(ctypes.c_void_p(hwnd), cb, 0)
    for k in kids:
        out.append((k, class_of(k), tid_of(k), depth))
        out.extend(descendants(k, depth + 1, max_depth))
    return out


def find_own_container(container_class, my_pid, timeout_s=2.0):
    """在本进程内找容器窗口。

    FindWindowW 是全桌面搜索，可能撞上用户正开着的 app 实例的同类窗口，
    故按 PID 过滤 + FindWindowExW 链式枚举。
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        cand = user32.FindWindowW(container_class, None)
        while cand:
            pid = ctypes.c_ulong(0)
            user32.GetWindowThreadProcessId(ctypes.c_void_p(cand), ctypes.byref(pid))
            if pid.value == my_pid:
                return cand
            cand = user32.FindWindowExW(
                ctypes.c_void_p(0), ctypes.c_void_p(cand), container_class, None)
        time.sleep(0.1)
    return None


lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_plugin_slot_load.restype = ctypes.c_int
lib.auradsp_plugin_slot_load.argtypes = [
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p]
lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int
lib.auradsp_plugin_slot_show_editor.argtypes = [
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int
lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p, ctypes.c_int]
lib.auradsp_plugin_slot_unload.restype = ctypes.c_int
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int]

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetWindowThreadProcessId.argtypes = [
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
user32.GetWindowThreadProcessId.restype = ctypes.c_ulong
user32.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
user32.GetClassNameW.restype = ctypes.c_int
user32.EnumChildWindows.argtypes = [
    ctypes.c_void_p,
    ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_long),
    ctypes.c_long]
user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.FindWindowW.restype = ctypes.c_void_p
user32.FindWindowExW.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.FindWindowExW.restype = ctypes.c_void_p

h = lib.auradsp_create(48000.0, 1024)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
MY_PID = k32.GetCurrentProcessId()
try:
    for name, container_class, path, plugin_id in CASES:
        print(f"\n=== {name} ===")
        if not os.path.exists(path):
            skip(f"{name}: 插件不存在（{path}）")
            continue

        rc = lib.auradsp_plugin_slot_load(h, 0, path.encode("utf-8"), plugin_id)
        print(f"  load rc={rc}")
        check(rc == 1, f"{name}: slot_load 返回 1")
        if rc != 1:
            continue

        rc = lib.auradsp_plugin_slot_show_editor(
            h, 0, "topology test - AuraDSP Host".encode("utf-8"))
        print(f"  showEditor rc={rc}")
        check(rc == 1, f"{name}: show_editor 返回 1")
        time.sleep(1.0)  # 等插件窗口建完

        container = find_own_container(container_class, MY_PID)
        if not container:
            check(False,
                  f"{name}: 本进程内找不到容器窗口（class={container_class}）")
        else:
            ct = tid_of(container)
            print(f"  容器 hwnd={container:#x} tid={ct} class={class_of(container)}")
            kids = descendants(container)
            print(f"  子孙窗口 {len(kids)} 个:")
            for hwnd, cls, t, d in kids:
                print(f"    {'  ' * d}hwnd={hwnd:#x} tid={t} class={cls!r}"
                      f" {'★同线程' if t == ct else '✗不同线程!'}")
            check(len(kids) > 0, f"{name}: 容器下有子孙窗口（插件 GUI 已挂载）")
            bad = [(hwnd, cls, t) for hwnd, cls, t, d in kids if t != ct]
            check(not bad,
                  f"{name}: 全部子孙窗口线程 ID == 容器线程 ID {ct}"
                  f"（不符 {len(bad)} 个）")
            caller_tid = k32.GetCurrentThreadId()
            print(f"  [INFO] caller 线程 tid={caller_tid}；容器 tid={ct}")

        lib.auradsp_plugin_slot_close_editor(h, 0)
        time.sleep(0.3)
        lib.auradsp_plugin_slot_unload(h, 0)
        time.sleep(0.3)
finally:
    lib.auradsp_destroy(h)

print()
if fails:
    print(f"TOPOLOGY TEST FAILED（{len(fails)} 项，{len(skips)} 项跳过）")
    sys.exit(1)
print(f"TOPOLOGY TEST PASSED（{len(skips)} 项跳过）")
sys.exit(0)
