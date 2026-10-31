# -*- coding: utf-8 -*-
# 运行时验证 v2：RailToggle 可见性 / 5 项导航第 3 项(脚本) / Liveprog 页截图
import ctypes
import ctypes.wintypes as wt
import time
import os
import sys

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
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


def client_origin(hwnd):
    pt = wt.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    return pt.x, pt.y


def click(x, y):
    user32.SetCursorPos(int(x), int(y))
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)


def activate(hwnd):
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.4)


def accent_bar_y(img, x0, x1, y0, y1):
    px = img.load()
    miny, maxy = None, None
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px[x, y][:3]
            if r > 180 and g > 220 and b < 110:
                if miny is None or y < miny:
                    miny = y
                if maxy is None or y > maxy:
                    maxy = y
                break
    return miny, maxy


def main():
    hwnd = find_auradsp()
    if not hwnd:
        print("FATAL: window not found")
        return 1
    activate(hwnd)
    cl, ct = client_origin(hwnd)
    print("client origin: (%d,%d)" % (cl, ct))
    out = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
    os.makedirs(out, exist_ok=True)
    time.sleep(1.0)

    # --- 1) RailToggle 可见性：按钮 bbox (168..200, 28..60) 逻辑内亮像素数
    #       （旧版 textDim 图标在暗底上亮像素≈0；新版 p.text 箭头 + 面板底应显著 >0）
    img = ImageGrab.grab()
    px = img.load()
    bright = 0
    for y in range(ct + int(28 * 1.5), ct + int(60 * 1.5)):
        for x in range(cl + int(168 * 1.5), cl + int(200 * 1.5)):
            r, g, b = px[x, y][:3]
            if r > 150 and g > 150 and b > 150:
                bright += 1
    print("1) toggle bbox bright px = %d (expect > 15) -> visible=%s" % (bright, bright > 15))
    ok1 = bright > 15

    # --- 2) 点击第 3 项（脚本）导航 ---
    click(cl + int(108 * 1.5), ct + int(192 * 1.5))
    time.sleep(1.0)  # 页面切换 + 入场
    img2 = ImageGrab.grab()
    img2.save(os.path.join(out, "08-liveprog.png"))
    # 选中指示条应落在 item3 区带（逻辑 y 172..212 → 物理 +client）
    y0, y1 = accent_bar_y(img2, cl + int(10 * 1.5), cl + int(26 * 1.5),
                          ct + int(140 * 1.5), ct + int(320 * 1.5))
    expect0 = ct + int(172 * 1.5)
    print("2) indicator y=[%s,%s] expect band ~[%d,%d] -> ok=%s" % (
        y0, y1, expect0, expect0 + int(44 * 1.5),
        y0 is not None and abs(y0 - expect0) < 30))
    ok2 = y0 is not None and abs(y0 - expect0) < 30

    # --- 3) 收起/展开仍可用（新按钮） ---
    click(cl + int(184 * 1.5), ct + int(44 * 1.5))
    time.sleep(0.9)
    img3 = ImageGrab.grab()
    img3.save(os.path.join(out, "09-rail-collapsed-v2.png"))
    px3 = img3.load()
    collapsed = px3[cl + int(184 * 1.5), ct + int(44 * 1.5)][:3]
    ok3 = sum(collapsed) / 3 < 25  # 按钮已随 rail 消失（原位置变 rail 外背景）
    print("3) collapsed check: old btn pos now=%s -> collapsed=%s" % (str(collapsed), ok3))
    # 展开
    click(cl + int(32 * 1.5), ct + int(62 * 1.5))
    time.sleep(0.9)

    print("RESULT:", "PASS" if (ok1 and ok2 and ok3) else "CHECK NEEDED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
