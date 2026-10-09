# -*- coding: utf-8 -*-
# 诊断 rail 导航项的图标/文字像素（哪几项缺图标、字重差异）
import ctypes, ctypes.wintypes as wt, time
ctypes.windll.shcore.SetProcessDpiAwareness(2)
from PIL import ImageGrab
user32 = ctypes.windll.user32
EP = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)
hwnd = {"h": None}
def cb(h, _):
    b = ctypes.create_unicode_buffer(64); user32.GetWindowTextW(h, b, 64)
    if b.value == "AuraDSP" and user32.IsWindowVisible(h): hwnd["h"] = h; return False
    return True
user32.EnumWindows(EP(cb), 0)
h = hwnd["h"]
assert h
user32.SetWindowPos(h, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)
user32.SetForegroundWindow(h); time.sleep(1.0)
pt = wt.POINT(0, 0); user32.ClientToScreen(h, ctypes.byref(pt)); cl, ct = pt.x, pt.y
S = 1.5
img = ImageGrab.grab(); px = img.load()

# rail 项中心（实测）：104/148/192/236/279/324
NAMES = ["主页", "效果", "脚本", "插件", "处理链", "可视化"]
print("%-6s | 图标区(x 44..62) 亮像素 | 文字区(x 70..200) 亮像素 | 最强像素" % "项")
for i, name in enumerate(NAMES):
    cy = 104 + 44 * i
    # 图标区：navItem 内 padding lg=20 + 指示条3 + 12 → 图标约 x 36..56
    ico = 0; ico_max = 0
    for yl in range(cy - 10, cy + 11):
        y = ct + int(yl * S)
        for xl in range(34, 62):
            x = cl + int(xl * S)
            r, g, b = px[x, y][:3]
            lum = (r + g + b) / 3
            if lum > 70: ico += 1
            ico_max = max(ico_max, lum)
    # 文字区
    txt = 0; txt_max = 0
    for yl in range(cy - 10, cy + 11):
        y = ct + int(yl * S)
        for xl in range(66, 200):
            x = cl + int(xl * S)
            r, g, b = px[x, y][:3]
            lum = (r + g + b) / 3
            if lum > 70: txt += 1
            txt_max = max(txt_max, lum)
    print("%-6s | %5d (max %.0f) | %5d (max %.0f)" % (name, ico, ico_max, txt, txt_max))
