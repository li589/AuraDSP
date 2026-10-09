# -*- coding: utf-8 -*-
# 运行时验证：首页布局（可视化置顶）+ 左栏收起/展开 + 截图交付
import ctypes
import ctypes.wintypes as wt
import time
import os
import sys

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # per-monitor DPI aware
except Exception:
    pass
from PIL import ImageGrab

user32 = ctypes.windll.user32
ENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)

target = {"hwnd": None}


def find_auradsp():
    def cb(hwnd, _):
        buf = ctypes.create_unicode_buffer(64)
        user32.GetWindowTextW(hwnd, buf, 64)
        if buf.value == "AuraDSP" and user32.IsWindowVisible(hwnd):
            target["hwnd"] = hwnd
            return False
        return True
    user32.EnumWindows(ENUMPROC(cb), 0)
    return target["hwnd"]


def rect(hwnd):
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    return r.left, r.top, r.right, r.bottom


def client_origin(hwnd):
    """客户区 (0,0) 的屏幕物理坐标（排除标题栏/边框偏移）"""
    pt = wt.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    return pt.x, pt.y


def click(x, y):
    user32.SetCursorPos(int(x), int(y))
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)


def activate(hwnd):
    # 后台进程直接 SetForegroundWindow 会被前台锁拒绝：先 TOPMOST 提权再激活
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.4)


def main():
    hwnd = find_auradsp()
    if not hwnd:
        print("FATAL: AuraDSP window not found")
        return 1
    activate(hwnd)
    l, t, r, b = rect(hwnd)
    cl, ct = client_origin(hwnd)
    print("window rect (physical): %dx%d at (%d,%d); client origin (%d,%d)" % (
        r - l, b - t, l, t, cl, ct))

    out = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
    os.makedirs(out, exist_ok=True)
    time.sleep(1.2)  # 等入场动画结束

    # --- 1) 首页截图（可视化应置顶）---
    img = ImageGrab.grab()
    img.save(os.path.join(out, "05-home-v2.png"))

    # --- 2) 收起左栏：chevron 按钮 32×32，客户区逻辑中心 (184,44)，DPI×1.5 ---
    cx = cl + int(184 * 1.5)
    cy = ct + int(44 * 1.5)
    click(cx, cy)
    time.sleep(0.9)  # 等收起动画
    img2 = ImageGrab.grab()
    img2.save(os.path.join(out, "06-home-rail-collapsed.png"))
    px = img2.load()
    print("collapsed: color@x324,y300 =%s  color@x60,y300 =%s" % (
        str(px[324, 300][:3]), str(px[60, 300][:3])))

    # --- 3) 再展开：收起态 rail 宽 64，按钮在品牌方块下方，逻辑中心 (32,62) ---
    cx2 = cl + int(32 * 1.5)
    cy2 = ct + int(62 * 1.5)
    click(cx2, cy2)
    time.sleep(0.9)
    img3 = ImageGrab.grab()
    img3.save(os.path.join(out, "07-home-rail-expanded.png"))
    print("saved: 05-home-v2 / 06-collapsed / 07-expanded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
