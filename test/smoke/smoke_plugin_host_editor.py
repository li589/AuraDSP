# -*- coding: utf-8 -*-
"""smoke_plugin_host_editor.py — Phase 4 out-of-process editor hosting.

Pro-Q 4's editor must open, live in auradsp_plugin_host.exe (not the app
process), keep all child windows on the container thread, resize with the
container, and close cleanly without killing the engine.
"""
import ctypes
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
PLUGIN_PATH = r"C:\Program Files\Common Files\VST3\FabFilter\FabFilter Pro-Q 4.vst3"
CONTAINER_CLASS = "AuraDSP_VST3_Host_Window"
TOL = 4

os.environ["AURA_PLUGIN_HOST_MODE"] = "process"

dll = ctypes.CDLL(DLL_PATH)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_plugin_slot_load.restype = ctypes.c_int
dll.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p]
dll.auradsp_plugin_slot_unload.restype = ctypes.c_int
dll.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int]
dll.auradsp_plugin_slot_show_editor.restype = ctypes.c_int
dll.auradsp_plugin_slot_show_editor.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
dll.auradsp_plugin_slot_close_editor.restype = ctypes.c_int
dll.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p, ctypes.c_int]
dll.auradsp_plugin_slot_is_editor_open.restype = ctypes.c_int
dll.auradsp_plugin_slot_is_editor_open.argtypes = [ctypes.c_void_p, ctypes.c_int]
dll.auradsp_plugin_get_status.restype = ctypes.c_int
dll.auradsp_plugin_get_status.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
user32.GetWindowThreadProcessId.restype = ctypes.c_ulong
user32.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
user32.GetClassNameW.restype = ctypes.c_int
user32.EnumChildWindows.argtypes = [
    ctypes.c_void_p, ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_long), ctypes.c_long]
user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.FindWindowW.restype = ctypes.c_void_p
user32.FindWindowExW.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.FindWindowExW.restype = ctypes.c_void_p
user32.GetClientRect.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_long * 4)]
user32.GetClientRect.restype = ctypes.c_bool
user32.SetWindowPos.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_int, ctypes.c_uint]
user32.SetWindowPos.restype = ctypes.c_bool
k32 = ctypes.WinDLL("kernel32", use_last_error=True)

SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010


def hosts_for_parent(parent_pid):
    script = ("Get-CimInstance Win32_Process -Filter \"Name='auradsp_plugin_host.exe'\" | "
              "Select-Object ProcessId,ParentProcessId | ConvertTo-Json -Compress")
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                            capture_output=True, text=True, timeout=20)
    text = result.stdout.strip()
    if not text:
        return []
    data = json.loads(text)
    if isinstance(data, dict):
        data = [data]
    return [int(x["ProcessId"]) for x in data if int(x.get("ParentProcessId", 0)) == parent_pid]


def wait_host(timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        hosts = hosts_for_parent(os.getpid())
        if hosts:
            return hosts[0]
        time.sleep(0.1)
    return None


def tid_of(hwnd):
    pid = ctypes.c_ulong(0)
    return user32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd), ctypes.byref(pid))


def pid_of(hwnd):
    pid = ctypes.c_ulong(0)
    user32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd), ctypes.byref(pid))
    return pid.value


def class_of(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(ctypes.c_void_p(hwnd), buf, 256)
    return buf.value


def descendants(hwnd):
    kids = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_long)
    def cb(h, _):
        kids.append(h)
        return True

    user32.EnumChildWindows(ctypes.c_void_p(hwnd), cb, 0)
    out = []
    for k in kids:
        out.append(k)
        out.extend(descendants(k))
    return out


def find_window_for_pid(container_class, wanted_pid, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        cand = user32.FindWindowW(container_class, None)
        while cand:
            if pid_of(cand) == wanted_pid:
                return cand
            cand = user32.FindWindowExW(ctypes.c_void_p(0), ctypes.c_void_p(cand), container_class, None)
        time.sleep(0.1)
    return None


def client_size(hwnd):
    rc = (ctypes.c_long * 4)()
    user32.GetClientRect(ctypes.c_void_p(hwnd), ctypes.byref(rc))
    return rc[2] - rc[0], rc[3] - rc[1]


def largest_child(hwnd):
    best = (0, None)
    for child in descendants(hwnd):
        w, h = client_size(child)
        if w * h > best[0]:
            best = (w * h, child)
    return best[1]


def get_status(handle):
    buf = ctypes.create_string_buffer(8192)
    dll.auradsp_plugin_get_status(handle, buf, len(buf))
    return json.loads(buf.value.decode("utf-8"))


def wait_editor_state(handle, expected, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if bool(dll.auradsp_plugin_slot_is_editor_open(handle, 0)) == expected:
            return True
        time.sleep(0.05)
    return False


if not os.path.exists(PLUGIN_PATH):
    print(f"[SKIP] Pro-Q 4 not installed: {PLUGIN_PATH}")
    sys.exit(0)

print("=== [1] create engine + load Pro-Q 4 in process mode ===")
h = dll.auradsp_create(48000.0, 1024)
assert h, "auradsp_create failed"
try:
    rc = dll.auradsp_plugin_slot_load(h, 0, PLUGIN_PATH.encode("utf-8"), b"")
    assert rc == 1, f"slot_load rc={rc}"
    status = get_status(h)
    assert status.get("remoteMode") is True, f"not remote: {status}"
    assert status.get("plugin") is not None, "plugin metadata missing"

    print("=== [2] open editor; it must live in the host process ===")
    rc = dll.auradsp_plugin_slot_show_editor(h, 0, b"Phase4 editor test - AuraDSP Host")
    assert rc == 1, f"show_editor rc={rc}"
    assert wait_editor_state(h, True), "editor never reported open"

    host_pid = wait_host()
    assert host_pid, "auradsp_plugin_host.exe child not found"
    container = find_window_for_pid(CONTAINER_CLASS, host_pid)
    assert container, f"container {CONTAINER_CLASS} not found in host pid {host_pid}"
    assert pid_of(container) == host_pid, "container is not owned by the host process"
    print(f"host pid={host_pid}, container hwnd={container:#x}")

    print("=== [3] plugin GUI is mounted on the host container thread ===")
    kids = descendants(container)
    assert kids, "container has no plugin child windows"
    ctid = tid_of(container)
    bad = [k for k in kids if tid_of(k) != ctid]
    print(f"container tid={ctid}, descendants={len(kids)}, wrong-thread={len(bad)}")
    assert not bad, "plugin child windows are not on the container thread"

    print("=== [4] container resize reaches the plugin child ===")
    cw, ch = client_size(container)
    assert cw >= 100 and ch >= 80, f"container too small: {cw}x{ch}"
    child = largest_child(container)
    assert child is not None, "no plugin child for resize check"
    sw, sh = client_size(child)
    assert abs(sw - cw) <= TOL and abs(sh - ch) <= TOL, \
        f"initial size mismatch container={cw}x{ch} child={sw}x{sh}"

    target_w = min(max(cw + 200, cw * 5 // 4), 1800)
    target_h = min(max(ch + 150, ch * 5 // 4), 1000)
    assert user32.SetWindowPos(ctypes.c_void_p(container), None, 120, 120,
                               target_w, target_h, SWP_NOZORDER | SWP_NOACTIVATE)
    time.sleep(0.6)
    cw2, ch2 = client_size(container)
    assert (cw2, ch2) != (cw, ch), f"container did not resize: {cw}x{ch}"
    child = largest_child(container)
    sw2, sh2 = client_size(child) if child else (0, 0)
    print(f"resized container {cw}x{ch} -> {cw2}x{ch2}; child -> {sw2}x{sh2}")
    assert abs(sw2 - cw2) <= TOL and abs(sh2 - ch2) <= TOL, \
        f"child did not follow container: child={sw2}x{sh2} container={cw2}x{ch2}"

    print("=== [5] close editor and unload without killing the host ===")
    dll.auradsp_plugin_slot_close_editor(h, 0)
    assert wait_editor_state(h, False), "editor did not close"
    assert dll.auradsp_plugin_slot_unload(h, 0) == 1
    status = get_status(h)
    assert status.get("remoteMode") is True and status.get("hasActive") is False
    assert hosts_for_parent(os.getpid()), "host died during editor close/unload"
finally:
    dll.auradsp_destroy(h)
    time.sleep(1.0)

assert not hosts_for_parent(os.getpid()), "host survived engine destroy"
print("ALL TESTS PASSED: out-of-process editor hosting OK")
