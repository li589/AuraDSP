# -*- coding: utf-8 -*-
"""ui_test_kit.py — AuraDSP UI 自动化测试核心工具库

提供：
1. 窗口探测、前置置顶、几何归一化 (HWND_TOPMOST + SetWindowPos)；
2. 相对窗口与相对组件的精准坐标换算；
3. 开关状态检测与主动开启保障 (避免 disabled 状态下滑块无法拖动)；
4. 滑块轨道与 Thumb 抓手精准命中计算；
5. 区域像素差分与断言 (真实判定拖拽与双击归位是否发生)。
"""

import ctypes
import ctypes.wintypes as wt
import time
import os
import sys

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass

from PIL import Image, ImageGrab, ImageChops

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
EP = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)

APP_DIR = r"D:\temp_desktop\Proj\JamesDSP\app\auradsp_app\build\windows\x64\runner\Release"
APP_EXE = os.path.join(APP_DIR, "auradsp_app.exe")


class STARTUPINFO(ctypes.Structure):
    _fields_ = [
        ('cb', wt.DWORD), ('lpReserved', wt.LPWSTR), ('lpDesktop', wt.LPWSTR),
        ('lpTitle', wt.LPWSTR), ('dwX', wt.DWORD), ('dwY', wt.DWORD),
        ('dwXSize', wt.DWORD), ('dwYSize', wt.DWORD), ('dwXCountChars', wt.DWORD),
        ('dwYCountChars', wt.DWORD), ('dwFillAttribute', wt.DWORD),
        ('dwFlags', wt.DWORD), ('wShowWindow', wt.WORD), ('cbReserved2', wt.WORD),
        ('lpReserved2', ctypes.c_void_p), ('hStdInput', wt.HANDLE),
        ('hStdOutput', wt.HANDLE), ('hStdError', wt.HANDLE)
    ]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [
        ('hProcess', wt.HANDLE), ('hThread', wt.HANDLE),
        ('dwProcessId', wt.DWORD), ('dwThreadId', wt.DWORD)
    ]


class WindowGeometry:
    def __init__(self, hwnd):
        self.hwnd = hwnd
        self.rect = wt.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(self.rect))
        self.left = self.rect.left
        self.top = self.rect.top
        self.right = self.rect.right
        self.bottom = self.rect.bottom
        self.width = self.right - self.left
        self.height = self.bottom - self.top

    def refresh(self):
        user32.GetWindowRect(self.hwnd, ctypes.byref(self.rect))
        self.left = self.rect.left
        self.top = self.rect.top
        self.right = self.rect.right
        self.bottom = self.rect.bottom
        self.width = self.right - self.left
        self.height = self.bottom - self.top


def switch_to_default_desktop():
    h_desk = user32.OpenDesktopW("Default", 0, False, 0x01FF)
    if h_desk:
        user32.SetThreadDesktop(h_desk)
    return h_desk


def find_auradsp():
    h_desk = switch_to_default_desktop()
    target = {"hwnd": None}

    def cb(hwnd, _):
        b = ctypes.create_unicode_buffer(128)
        user32.GetWindowTextW(hwnd, b, 128)
        if b.value == "AuraDSP" and user32.IsWindowVisible(hwnd):
            target["hwnd"] = hwnd
            return False
        return True

    user32.EnumDesktopWindows(h_desk, EP(cb), 0)
    return target["hwnd"]


def ensure_running_and_ready(desired_width=1400, desired_height=900):
    """启动或查找 AuraDSP 窗口，并归一化到指定尺寸与活动桌面"""
    hwnd = find_auradsp()
    if not hwnd:
        print(f"==> 启动 AuraDSP: {APP_EXE}")
        si = STARTUPINFO()
        si.cb = ctypes.sizeof(STARTUPINFO)
        si.lpDesktop = "WinSta0\\Default"
        pi = PROCESS_INFORMATION()
        ok = kernel32.CreateProcessW(
            APP_EXE, None, None, None, False, 0, None, APP_DIR,
            ctypes.byref(si), ctypes.byref(pi)
        )
        if not ok:
            raise RuntimeError(f"CreateProcessW 失败，错误码: {kernel32.GetLastError()}")
        for _ in range(40):
            time.sleep(0.3)
            hwnd = find_auradsp()
            if hwnd:
                break
    if not hwnd:
        raise RuntimeError("未能启动或定位 AuraDSP 窗口！")

    ensure_foreground(hwnd)
    # 归一化窗口尺寸与位置到 (100, 80)，确保几何可预测
    user32.MoveWindow(hwnd, 100, 80, desired_width, desired_height, True)
    time.sleep(0.4)
    ensure_foreground(hwnd)
    return hwnd, WindowGeometry(hwnd)


def ensure_foreground(hwnd):
    """【每次交互前强制置顶前置】"""
    switch_to_default_desktop()
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.06)
    user32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    time.sleep(0.06)


def click_point(hwnd, x, y, delay=0.25):
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(delay)


def double_click_point(hwnd, x, y, delay=0.3):
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(delay)


def drag_horizontal(hwnd, x0, x1, y, steps=20, delay=0.3):
    """精准横向拖拽"""
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x0), int(y))
    time.sleep(0.08)
    user32.mouse_event(0x0002, 0, 0, 0, 0)  # 按下
    time.sleep(0.05)
    for i in range(1, steps + 1):
        cur_x = x0 + (x1 - x0) * (i / steps)
        user32.SetCursorPos(int(cur_x), int(y))
        time.sleep(0.015)
    time.sleep(0.05)
    user32.mouse_event(0x0004, 0, 0, 0, 0)  # 松开
    time.sleep(delay)


def scroll_wheel(hwnd, x, y, delta, delay=0.3):
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    user32.mouse_event(0x0800, 0, 0, int(delta), 0)
    time.sleep(delay)


def capture_window_box(geom, local_box=None):
    """捕获窗口或窗口内部局部的截图"""
    ensure_foreground(geom.hwnd)
    switch_to_default_desktop()
    geom.refresh()
    if local_box is None:
        bbox = (geom.left, geom.top, geom.right, geom.bottom)
    else:
        bx0, by0, bx1, by1 = local_box
        bbox = (geom.left + bx0, geom.top + by0, geom.left + bx1, geom.top + by1)
    return ImageGrab.grab(bbox=bbox)


def assert_images_differ(img_before, img_after, min_diff_pixels=20, label=""):
    """断言两张图存在视觉差异（验证拖动或点击真正生效）"""
    diff = ImageChops.difference(img_before, img_after)
    stat = diff.convert("L").getdata()
    diff_count = sum(1 for p in stat if p > 15)
    if diff_count < min_diff_pixels:
        raise AssertionError(
            f"[{label}] 预期画面发生变化，但实际差异像素仅 {diff_count} < {min_diff_pixels}！说明未真正点中或控件处于禁用状态！"
        )
    return diff_count
