#!/usr/bin/env python3
"""AuraDSP window helper: geometry, foreground, screenshot, click, scroll.

Borrows the Win32 conventions from test/ui/ui_test_kit.py but targets the
profile runner and never kills processes we did not start.
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

from PIL import ImageGrab

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass

user32 = ctypes.windll.user32
EP = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)


def find_window(title="AuraDSP"):
    found = []

    def cb(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            b = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, b, 256)
            if b.value == title:
                found.append(hwnd)
                return False
        return True

    user32.EnumWindows(EP(cb), 0)
    return found[0] if found else None


def rect(hwnd):
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    return (r.left, r.top, r.right, r.bottom)


def foreground(hwnd):
    """Force-activate the window (foreground lock workaround)."""
    kernel32 = ctypes.windll.kernel32
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    fg = user32.GetForegroundWindow()
    fg_tid = user32.GetWindowThreadProcessId(fg, None)
    cur_tid = kernel32.GetCurrentThreadId()
    if fg_tid and fg_tid != cur_tid:
        user32.AttachThreadInput(cur_tid, fg_tid, True)
    user32.BringWindowToTop(hwnd)
    user32.SetForegroundWindow(hwnd)
    user32.SetFocus(hwnd)
    if fg_tid and fg_tid != cur_tid:
        user32.AttachThreadInput(cur_tid, fg_tid, False)
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    time.sleep(0.15)
    user32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)


def capture(path, box=None):
    hwnd = find_window()
    if hwnd is None:
        raise RuntimeError("AuraDSP window not found")
    foreground(hwnd)
    r = rect(hwnd)
    if box:
        bbox = (r[0] + box[0], r[1] + box[1], r[0] + box[2], r[1] + box[3])
    else:
        bbox = r
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    img = ImageGrab.grab(bbox=bbox)
    img.save(path)
    return img


def click(rx, ry):
    hwnd = find_window()
    foreground(hwnd)
    r = rect(hwnd)
    x, y = r[0] + int(rx), r[1] + int(ry)
    user32.SetCursorPos(x, y)
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.05)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.25)


def resize(w=1400, h=900):
    hwnd = find_window()
    foreground(hwnd)
    user32.MoveWindow(hwnd, 40, 30, w, h, True)
    time.sleep(0.4)
    foreground(hwnd)


def scroll(rx, ry, notches=-3):
    hwnd = find_window()
    foreground(hwnd)
    r = rect(hwnd)
    user32.SetCursorPos(r[0] + int(rx), r[1] + int(ry))
    time.sleep(0.05)
    user32.mouse_event(0x0800, 0, 0, int(notches * 120), 0)
    time.sleep(0.4)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        print(rect(find_window()))
    elif sys.argv[1] == "capture":
        print(capture(sys.argv[2], tuple(map(int, sys.argv[3].split(","))) if len(sys.argv) > 3 else None))
    elif sys.argv[1] == "click":
        click(int(sys.argv[2]), int(sys.argv[3]))
    elif sys.argv[1] == "resize":
        resize(int(sys.argv[2]) if len(sys.argv) > 2 else 1400, int(sys.argv[3]) if len(sys.argv) > 3 else 900)
