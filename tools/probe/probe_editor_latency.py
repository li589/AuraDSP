"""probe_editor_latency.py — 量化插件编辑器（共享 pump 线程）的消息延迟。

背景：VB 多总线（vbPluginGroupMask=0x7）下同一个 Ozone 12 会实例化 3 份，
分别挂在 3 个 engine handle 上。同一 DLL 的所有实例共享一条
ModulePumpThread（JUCE MessageManager 约束），因此编辑器窗口、GUI 消息
与生命周期任务都排在同一条线程上。本探针复现该结构并测量：

  1) 打开 1 / 2 / 3 个编辑器时，pump 线程对 WM_NULL 的响应延迟；
  2) 3 个 handle 并发处理音频（模拟 Z17 worker）时上述延迟；
  3) 各阶段进程 CPU 占用。

判定：延迟随编辑器数量线性上升 => 单泵线程被多个 GUI 瓜分（H1）；
延迟仅在并发处理时上升 => 插件模块级锁与 GUI 争用（H2）。

用法：
  python tools/probe/probe_editor_latency.py
  python tools/probe/probe_editor_latency.py --frames 2048 --hold 5

注意：会真实加载 3 个 Ozone（约数 GB 内存）并弹出 3 个编辑器窗口；
      测完自动关闭。不要与运行中的 App 同时挂载大量实例。
"""

import argparse
import ctypes
import json
import os
import statistics
import sys
import threading
import time
from ctypes import wintypes

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                        "auradsp_engine.dll")
OZONE_PATH = r"C:\Program Files\Common Files\VST3\iZotope\Ozone 12.vst3"
OZONE_ID = "5a5453564f424f5a7a6f6e6500000000"  # "VSTZOzone" little-endian tag

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

user32.EnumWindows.argtypes = [EnumWindowsProc, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND,
                                           ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetClassNameW.restype = ctypes.c_int
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.restype = ctypes.c_int
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.SendMessageTimeoutW.argtypes = [
    wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM,
    wintypes.UINT, wintypes.UINT, ctypes.POINTER(ctypes.c_size_t)
]
user32.SendMessageTimeoutW.restype = ctypes.c_size_t
user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.GetWindowLongW.restype = wintypes.LONG
user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
user32.GetWindow.restype = wintypes.HWND
user32.GetParent.argtypes = [wintypes.HWND]
user32.GetParent.restype = wintypes.HWND
user32.InvalidateRect.argtypes = [wintypes.HWND, ctypes.c_void_p, wintypes.BOOL]
user32.InvalidateRect.restype = wintypes.BOOL
user32.UpdateWindow.argtypes = [wintypes.HWND]
user32.UpdateWindow.restype = wintypes.BOOL
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetClientRect.restype = wintypes.BOOL
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetWindowRect.restype = wintypes.BOOL
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.SetForegroundWindow.restype = wintypes.BOOL
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.ShowWindow.restype = wintypes.BOOL
user32.SetWindowPos.argtypes = [
    wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
    ctypes.c_int, ctypes.c_int, wintypes.UINT,
]
user32.SetWindowPos.restype = wintypes.BOOL
user32.DefWindowProcW.argtypes = [wintypes.HWND, wintypes.UINT,
                                  wintypes.WPARAM, wintypes.LPARAM]
user32.DefWindowProcW.restype = ctypes.c_ssize_t

SW_SHOW = 5
HWND_TOPMOST = wintypes.HWND(-1)
HWND_NOTOPMOST = wintypes.HWND(-2)
SWP_SHOWWINDOW = 0x0040
SWP_NOACTIVATE = 0x0010

THREAD_QUERY_INFORMATION = 0x0040
kernel32.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenThread.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.GetThreadTimes.argtypes = [
    wintypes.HANDLE,
    ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME),
    ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME),
]
kernel32.GetThreadTimes.restype = wintypes.BOOL
kernel32.GetCurrentProcess.restype = wintypes.HANDLE
kernel32.GetProcessTimes.argtypes = [
    wintypes.HANDLE,
    ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME),
    ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME),
]
kernel32.GetProcessTimes.restype = wintypes.BOOL

GWL_STYLE = -16
WS_CLIPCHILDREN = 0x02000000
SWP_FRAMECHANGED = 0x0020
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001
SWP_NOZORDER = 0x0004
WM_NULL = 0x0000
SMTO_ABORTIFHUNG = 0x0002
SMTO_BLOCK = 0x0001
GW_CHILD = 5


def load_engine():
    lib = ctypes.CDLL(DLL_PATH)
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int,
    ]
    lib.auradsp_plugin_slot_load.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p
    ]
    lib.auradsp_plugin_slot_load.restype = ctypes.c_int
    lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.auradsp_plugin_slot_unload.restype = ctypes.c_int
    lib.auradsp_plugin_slot_show_editor.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p
    ]
    lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int
    lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p,
                                                    ctypes.c_int]
    lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int
    lib.auradsp_plugin_slot_is_editor_open.argtypes = [ctypes.c_void_p,
                                                      ctypes.c_int]
    lib.auradsp_plugin_slot_is_editor_open.restype = ctypes.c_int
    lib.auradsp_plugin_slot_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int
    ]
    lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int
    return lib


def slot_status(lib, h, slot=0):
    buf = ctypes.create_string_buffer(2048)
    n = lib.auradsp_plugin_slot_get_status(h, slot, buf, len(buf))
    if n <= 0:
        return {}
    try:
        return json.loads(buf.value.decode())
    except Exception:
        return {}


def print_status(lib, handles, tag):
    rows = []
    for i, h in enumerate(handles):
        st = slot_status(lib, h)
        rows.append(
            f"h[{i}] active={st.get('hasActive')} "
            f"bypass={st.get('bypassed')} calls={st.get('processCalls')} "
            f"inRms={st.get('inRms')} outRms={st.get('outRms')} "
            f"stage={st.get('insertStage')} ch={st.get('channels')}"
        )
    print(f"  status[{tag}]: " + " | ".join(rows))


def list_editor_windows(pid):
    out = []

    def cb(hwnd, _):
        pid_out = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid_out))
        if pid_out.value != pid:
            return True
        cls = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, cls, 256)
        if cls.value.startswith("AuraDSP_VST3_Host_Window") or \
           cls.value.startswith("AuraDSP_CLAP_Host_Window"):
            title = ctypes.create_unicode_buffer(512)
            user32.GetWindowTextW(hwnd, title, 512)
            out.append({
                "hwnd": hwnd,
                "class": cls.value,
                "title": title.value,
                "visible": bool(user32.IsWindowVisible(hwnd)),
                "style": user32.GetWindowLongW(hwnd, GWL_STYLE) & 0xFFFFFFFF,
            })
        return True

    user32.EnumWindows(EnumWindowsProc(cb), 0)
    return out


def child_windows(hwnd):
    out = []
    child = user32.GetWindow(hwnd, GW_CHILD)
    while child:
        cls = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(child, cls, 256)
        out.append({"hwnd": child, "class": cls.value,
                    "style": user32.GetWindowLongW(child, GWL_STYLE) & 0xFFFFFFFF})
        child = user32.GetWindow(child, 2)  # GW_HWNDNEXT = 2
    return out


def send_null_latency(hwnd, timeout_ms=2000):
    res = ctypes.c_size_t(0)
    t0 = time.perf_counter()
    ok = user32.SendMessageTimeoutW(hwnd, WM_NULL, 0, 0,
                                    SMTO_ABORTIFHUNG | SMTO_BLOCK,
                                    timeout_ms, ctypes.byref(res))
    dt = (time.perf_counter() - t0) * 1000.0
    return dt if ok else float("nan")


def proc_cpu_seconds():
    creation = wintypes.FILETIME(); exit_ = wintypes.FILETIME()
    kernel = wintypes.FILETIME(); user = wintypes.FILETIME()
    if not kernel32.GetProcessTimes(kernel32.GetCurrentProcess(),
                                    ctypes.byref(creation), ctypes.byref(exit_),
                                    ctypes.byref(kernel), ctypes.byref(user)):
        return 0.0
    k = (kernel.dwHighDateTime << 32) | kernel.dwLowDateTime
    u = (user.dwHighDateTime << 32) | user.dwLowDateTime
    return (k + u) / 1e7


def thread_cpu_seconds(tid):
    h = kernel32.OpenThread(THREAD_QUERY_INFORMATION, False, tid)
    if not h:
        return None
    try:
        creation = wintypes.FILETIME(); exit_ = wintypes.FILETIME()
        kernel = wintypes.FILETIME(); user = wintypes.FILETIME()
        if not kernel32.GetThreadTimes(h, ctypes.byref(creation),
                                       ctypes.byref(exit_),
                                       ctypes.byref(kernel), ctypes.byref(user)):
            return None
        k = (kernel.dwHighDateTime << 32) | kernel.dwLowDateTime
        u = (user.dwHighDateTime << 32) | user.dwLowDateTime
        return (k + u) / 1e7
    finally:
        kernel32.CloseHandle(h)


def window_thread_id(hwnd):
    tid = user32.GetWindowThreadProcessId(hwnd, None)
    return tid


def free_mb():
    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [("dwLength", wintypes.DWORD),
                    ("dwMemoryLoad", wintypes.DWORD),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
    st = MEMORYSTATUSEX(); st.dwLength = ctypes.sizeof(st)
    kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
    return st.ullAvailPhys / (1024 * 1024)


class Sampler:
    def __init__(self, hwnds, interval_ms=5.0):
        self.hwnds = list(hwnds)
        self.interval = interval_ms / 1000.0
        self.samples = []          # (elapsed_s, latency_ms)
        self._stop = threading.Event()
        self._thr = None
        self._t0 = 0.0

    def start(self):
        self._t0 = time.perf_counter()
        self._thr = threading.Thread(target=self._run, daemon=True)
        self._thr.start()

    def _run(self):
        while not self._stop.is_set():
            now = time.perf_counter() - self._t0
            for h in self.hwnds:
                dt = send_null_latency(h)
                if dt == dt:
                    self.samples.append((now, dt))
            self._stop.wait(self.interval)

    def stop(self):
        self._stop.set()
        if self._thr:
            self._thr.join(timeout=3)
        return [d for _, d in self.samples]


def stats(samples):
    if not samples:
        return "n=0"
    s = sorted(samples)
    def pct(p):
        return s[min(len(s) - 1, int(len(s) * p))]
    return (f"n={len(s)} p50={statistics.median(s):6.2f}ms "
            f"p95={pct(0.95):6.2f}ms p99={pct(0.99):6.2f}ms "
            f"max={max(s):7.2f}ms")


class AudioRunner:
    def __init__(self, lib, handles, frames, workers=0, sr=48000.0):
        self.lib = lib
        self.handles = handles
        self.frames = frames
        self.period = frames / sr
        self.workers = workers if workers > 0 else len(handles)
        self._stop = threading.Event()
        self._threads = []
        n = frames * 2
        self.src = (ctypes.c_float * n)()
        for i in range(n):
            self.src[i] = 0.15 * (((i * 17) % 101) / 50.0 - 1.0)
        self.dsts = [(ctypes.c_float * n)() for _ in handles]

    def start(self):
        groups = [[] for _ in range(self.workers)]
        for idx in range(len(self.handles)):
            groups[idx % self.workers].append(idx)
        for group in groups:
            t = threading.Thread(target=self._run_one, args=(group,), daemon=True)
            t.start()
            self._threads.append(t)

    def _run_one(self, group):
        srcp = ctypes.cast(self.src, ctypes.POINTER(ctypes.c_float))
        next_t = time.perf_counter()
        while not self._stop.is_set():
            for idx in group:
                dstp = ctypes.cast(self.dsts[idx], ctypes.POINTER(ctypes.c_float))
                self.lib.auradsp_process(self.handles[idx], srcp, dstp, self.frames)
            next_t += self.period
            delay = next_t - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            else:
                next_t = time.perf_counter()

    def stop(self):
        self._stop.set()
        for t in self._threads:
            t.join(timeout=3)


def phase(label, sampler, cpu0, t_start, hold, pump_tid=None, pump_cpu0=None):
    time.sleep(hold)
    samples = sampler.stop()
    cpu = proc_cpu_seconds() - cpu0
    wall = time.perf_counter() - t_start
    pump = ""
    if pump_tid and pump_cpu0 is not None:
        c1 = thread_cpu_seconds(pump_tid)
        if c1 is not None:
            pump = f" pump_cpu={(c1 - pump_cpu0) / wall * 100:5.1f}%"
    print(f"  {label:<34} {stats(samples)}  proc_cpu={cpu / wall * 100:5.1f}%"
          f"{pump}  free={free_mb():.0f}MB")
    # 按秒切片，暴露「稳态持续尖峰」而不是只看全局 max
    if sampler.samples and hold >= 2:
        buckets = {}
        for t, d in sampler.samples:
            buckets.setdefault(int(t), []).append(d)
        for sec in sorted(buckets):
            bs = buckets[sec]
            print(f"      t+{sec}s n={len(bs):4d} p50={statistics.median(bs):6.2f} "
                  f"p95={sorted(bs)[int(len(bs) * 0.95)]:6.2f} max={max(bs):7.2f} ms")
    return samples


WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
MK_LBUTTON = 0x0001


def make_lparam(x, y):
    return (int(y) << 16) | (int(x) & 0xFFFF)


def drag_bench(child_hwnds, steps=240, step_px=2):
    """向插件子窗口注入拖拽消息，测每次消息处理墙钟。

    这不是完整的输入栈（不经过鼠标驱动/RAW INPUT），但走的是插件自己的
    WndProc + GUI 处理路径；每次 SendMessageTimeout 的往返即该事件在
    pump 线程上的处理时间。
    """
    for h in child_hwnds:
        rc = wintypes.RECT()
        if not user32.GetClientRect(h, ctypes.byref(rc)):
            continue
        w = rc.right - rc.left
        hgt = rc.bottom - rc.top
        x0, y0 = w // 2, hgt // 2
        res = ctypes.c_size_t(0)
        user32.SetForegroundWindow(h)
        t0 = time.perf_counter()
        user32.SendMessageTimeoutW(h, WM_LBUTTONDOWN, MK_LBUTTON,
                                   make_lparam(x0, y0),
                                   SMTO_ABORTIFHUNG | SMTO_BLOCK, 5000,
                                   ctypes.byref(res))
        down_ms = (time.perf_counter() - t0) * 1000.0
        times = []
        for i in range(steps):
            x = x0 + (i % 60) * step_px - 60
            y = y0 + (i // 60) * step_px - 2
            t0 = time.perf_counter()
            ok = user32.SendMessageTimeoutW(h, WM_MOUSEMOVE, MK_LBUTTON,
                                            make_lparam(x, y),
                                            SMTO_ABORTIFHUNG | SMTO_BLOCK, 5000,
                                            ctypes.byref(res))
            dt = (time.perf_counter() - t0) * 1000.0
            if ok:
                times.append(dt)
        t0 = time.perf_counter()
        user32.SendMessageTimeoutW(h, WM_LBUTTONUP, 0, make_lparam(x0, y0),
                                   SMTO_ABORTIFHUNG | SMTO_BLOCK, 5000,
                                   ctypes.byref(res))
        up_ms = (time.perf_counter() - t0) * 1000.0
        times.sort()
        print(f"    drag hwnd={hex(h)} area={w}x{hgt} down={down_ms:6.2f} "
              f"up={up_ms:6.2f} move n={len(times)} "
              f"p50={statistics.median(times):6.2f} "
              f"p95={times[int(len(times) * 0.95)]:6.2f} "
              f"max={max(times):7.2f} ms")


def foreground_windows(hwnds, base_x=120, base_y=90):
    """把编辑器容器窗口真正放到最前（topmost 闪现），确保插件在绘制。"""
    for i, h in enumerate(hwnds):
        rc = wintypes.RECT()
        user32.GetClientRect(h, ctypes.byref(rc))
        w = rc.right - rc.left or 1100
        hgt = rc.bottom - rc.top or 700
        user32.ShowWindow(h, SW_SHOW)
        user32.SetWindowPos(h, HWND_TOPMOST, base_x + i * 40, base_y + i * 40,
                            w + 16, hgt + 39, SWP_SHOWWINDOW)
        user32.SetForegroundWindow(h)
    for h in hwnds:
        user32.SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0,
                            SWP_NOACTIVATE | 0x0001)  # SWP_NOSIZE, keep pos


def set_clipchildren(hwnds, enable=True):
    """运行时切换 WS_CLIPCHILDREN（不重建窗口），用于对比闪烁/擦除成本。"""
    for h in hwnds:
        style = user32.GetWindowLongW(h, GWL_STYLE) & 0xFFFFFFFF
        new_style = (style | WS_CLIPCHILDREN) if enable else (style & ~WS_CLIPCHILDREN)
        if new_style == style:
            continue
        user32.SetWindowLongW(h, GWL_STYLE, new_style)
        user32.SetWindowPos(h, None, 0, 0, 0, 0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                            SWP_FRAMECHANGED)


def resize_bench(hwnds, steps=12, step_px=24):
    """模拟用户拖拽窗口边框：SetWindowPos 改容器尺寸，测墙钟。"""
    for h in hwnds:
        rc = wintypes.RECT()
        user32.GetWindowRect(h, ctypes.byref(rc))
        w0 = rc.right - rc.left
        h0 = rc.bottom - rc.top
        times = []
        for i in range(steps):
            dw = i * step_px
            t0 = time.perf_counter()
            user32.SetWindowPos(h, None, rc.left, rc.top, w0 + dw, h0 + dw // 2,
                                SWP_NOACTIVATE | 0x0002 | 0x0004)  # NOMOVE|NOZORDER
            times.append((time.perf_counter() - t0) * 1000.0)
        times.sort()
        print(f"    resize hwnd={hex(h)} from={w0}x{h0} n={len(times)} "
              f"p50={statistics.median(times):6.2f} "
              f"p95={times[int(len(times) * 0.95)]:6.2f} "
              f"max={max(times):7.2f} ms")
        user32.SetWindowPos(h, None, rc.left, rc.top, w0, h0,
                            SWP_NOACTIVATE | 0x0002 | 0x0004)


def paint_bench(child_hwnds, iters=30):
    """强制插件子窗口同步重绘，测单次 WM_PAINT 墙钟。"""
    for h in child_hwnds:
        times = []
        for _ in range(iters):
            user32.InvalidateRect(h, None, True)
            t0 = time.perf_counter()
            user32.UpdateWindow(h)
            times.append((time.perf_counter() - t0) * 1000.0)
        times.sort()
        print(f"    paint hwnd={hex(h)} p50={statistics.median(times):6.2f} "
              f"p95={times[int(len(times) * 0.95)]:6.2f} max={max(times):7.2f} ms")


def open_editor(lib, h, slot, title):
    t0 = time.time()
    rc = lib.auradsp_plugin_slot_show_editor(h, slot, title.encode())
    dt = time.time() - t0
    is_open = lib.auradsp_plugin_slot_is_editor_open(h, slot)
    print(f"    show_editor(slot={slot}) rc={rc} open={is_open} {dt * 1000:.0f}ms")
    return rc == 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=2048)
    ap.add_argument("--hold", type=float, default=4.0)
    ap.add_argument("--instances", type=int, default=3)
    ap.add_argument("--editors", type=int, default=3)
    ap.add_argument("--proc-threads", type=int, default=0,
                    help="0 = one processing thread per handle")
    ap.add_argument("--paint", action="store_true",
                    help="synchronously repaint plugin child windows and time it")
    ap.add_argument("--drag", action="store_true",
                    help="inject synthetic mouse drags into plugin child windows")
    ap.add_argument("--drag-steps", type=int, default=240)
    ap.add_argument("--foreground", action="store_true",
                    help="bring editor windows to front before measuring")
    ap.add_argument("--resize", action="store_true",
                    help="resize editor containers and time it")
    ap.add_argument("--clipchildren", action="store_true",
                    help="compare resize cost with WS_CLIPCHILDREN added at runtime")
    ap.add_argument("--plugin", default=OZONE_PATH)
    ap.add_argument("--id", default=OZONE_ID)
    args = ap.parse_args()

    if not os.path.exists(DLL_PATH):
        print(f"engine not found: {DLL_PATH}")
        return 1
    if not os.path.exists(args.plugin):
        print(f"plugin not found: {args.plugin}")
        return 1

    lib = load_engine()
    handles = []
    print(f"engine={DLL_PATH}")
    print(f"plugin={args.plugin} frames={args.frames} instances={args.instances}")
    try:
        for i in range(args.instances):
            h = lib.auradsp_create(ctypes.c_float(48000.0), args.frames)
            if not h:
                print(f"create handle {i} failed")
                return 1
            t0 = time.time()
            rc = lib.auradsp_plugin_slot_load(h, 0, args.plugin.encode(),
                                              args.id.encode())
            dt = time.time() - t0
            print(f"  handle[{i}] load rc={rc} {dt:.2f}s")
            if rc != 1:
                return 1
            handles.append(h)

        # 打印容器/子窗口样式，验证 WS_CLIPCHILDREN 等缺失是否属实
        opened = []
        for i, h in enumerate(handles[:max(0, args.editors)]):
            if not open_editor(lib, h, 0, f"Ozone probe {i + 1}"):
                break
            opened.append(h)
            wins = list_editor_windows(os.getpid())
            for w in wins:
                print(f"    container hwnd={w['hwnd']} style=0x{w['style']:08X} "
                      f"visible={w['visible']} title={w['title']!r}")
                for c in child_windows(w["hwnd"]):
                    print(f"      child hwnd={c['hwnd']} class={c['class']!r} "
                          f"style=0x{c['style']:08X}")
            time.sleep(0.4)

        wins = [w["hwnd"] for w in list_editor_windows(os.getpid())]
        tids = sorted({window_thread_id(w) for w in wins})
        print(f"\n  editors_open={len(wins)} hwnds={[hex(w) for w in wins]} "
              f"pump_tids={tids}")
        if not wins:
            print("  no editor window; abort latency phases")
            return 1
        pump_tid = tids[0]

        if args.foreground:
            foreground_windows(wins)
            time.sleep(0.8)
            print(f"  foregrounded {len(wins)} editor window(s)")

        def run_phase(label, workers, sampler_hwnds=None):
            hw = sampler_hwnds or wins
            p0 = thread_cpu_seconds(pump_tid)
            cpu0 = proc_cpu_seconds()
            t_start = time.perf_counter()
            runner = None
            if workers > 0:
                runner = AudioRunner(lib, handles, args.frames, workers)
                runner.start()
            sampler = Sampler(hw)
            sampler.start()
            try:
                phase(label, sampler, cpu0, t_start, args.hold,
                      pump_tid, p0)
            finally:
                if runner:
                    runner.stop()

        run_phase(f"idle ({len(wins)} editor(s))", 0)
        print_status(lib, handles, "idle-before-audio")

        if args.paint:
            children = []
            for w in list_editor_windows(os.getpid()):
                children += [c["hwnd"] for c in child_windows(w["hwnd"])]
            print(f"  paint bench idle ({len(children)} child hwnds)")
            paint_bench(children)

        if args.resize:
            print("  resize bench idle (all editors, baseline)")
            resize_bench(wins)
            if args.clipchildren:
                set_clipchildren(wins, True)
                print("  resize bench idle (all editors, WS_CLIPCHILDREN)")
                resize_bench(wins)

        run_phase(f"audio {args.proc_threads or len(handles)} thread(s) "
                  f"({len(wins)} editor(s))", args.proc_threads)
        print_status(lib, handles, "after-audio")

        if args.drag or args.resize:
            children = []
            for w in list_editor_windows(os.getpid()):
                children += [c["hwnd"] for c in child_windows(w["hwnd"])]
            runner = AudioRunner(lib, handles, args.frames,
                                 args.proc_threads or len(handles))
            runner.start()
            sampler = Sampler(wins)
            sampler.start()
            t0 = time.perf_counter()
            try:
                if args.drag:
                    print(f"  drag bench ({len(children)} child hwnds, "
                          f"{args.drag_steps} steps, audio on)")
                    drag_bench(children, steps=args.drag_steps)
                if args.resize:
                    print("  resize bench (all editors, audio on)")
                    resize_bench(wins)
                    if args.clipchildren:
                        set_clipchildren(wins, True)
                        print("  resize bench (all editors, audio on, CLIPCHILDREN)")
                        resize_bench(wins)
            finally:
                samples = sampler.stop()
                runner.stop()
            wall = time.perf_counter() - t0
            print(f"  interaction phase wall={wall:.2f}s "
                  f"pump_latency {stats(samples)}")

        # 仅保留 1 个编辑器
        for h in opened[1:]:
            lib.auradsp_plugin_slot_close_editor(h, 0)
            time.sleep(0.3)
        wins = [w["hwnd"] for w in list_editor_windows(os.getpid())]
        print(f"  editors_open={len(wins)} after closing extras")

        if wins:
            run_phase(f"audio {args.proc_threads or len(handles)} thread(s) "
                      f"(1 editor)", args.proc_threads, wins)
            run_phase("idle (1 editor)", 0, wins)
            print_status(lib, handles, "after-close-extras")
            if args.drag or args.resize:
                children = []
                for w in list_editor_windows(os.getpid()):
                    children += [c["hwnd"] for c in child_windows(w["hwnd"])]
                runner = AudioRunner(lib, handles, args.frames,
                                     args.proc_threads or len(handles))
                runner.start()
                sampler = Sampler(wins)
                sampler.start()
                try:
                    if args.drag:
                        print(f"  drag bench 1 editor ({len(children)} child hwnds, "
                              f"{args.drag_steps} steps, audio on)")
                        drag_bench(children, steps=args.drag_steps)
                    if args.resize:
                        print("  resize bench (1 editor, audio on)")
                        resize_bench(wins)
                finally:
                    samples = sampler.stop()
                    runner.stop()
                print(f"  interaction phase (1 editor) pump_latency {stats(samples)}")
            if args.paint:
                children = []
                for w in list_editor_windows(os.getpid()):
                    children += [c["hwnd"] for c in child_windows(w["hwnd"])]
                print(f"  paint bench idle after close ({len(children)} child hwnds)")
                paint_bench(children)

        for h in handles:
            lib.auradsp_plugin_slot_close_editor(h, 0)
        time.sleep(0.5)
        for h in handles:
            lib.auradsp_plugin_slot_unload(h, 0)
        return 0
    finally:
        for h in handles:
            try:
                lib.auradsp_plugin_slot_close_editor(h, 0)
            except Exception:
                pass
        for h in handles:
            try:
                lib.auradsp_plugin_slot_unload(h, 0)
            except Exception:
                pass
            try:
                lib.auradsp_destroy(h)
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
