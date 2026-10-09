# -*- coding: utf-8 -*-
"""顶栏/左栏 chrome 验证（分阶段，避免点击污染坐标）

阶段1 静态：rail 六项图标齐全 + 顶栏齿轮（外观右侧）
阶段2 交互：折叠按钮收起 → 收起态点 logo 展开（rail 宽度往返）
"""
import ctypes, ctypes.wintypes as wt, time, os
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
h = hwnd["h"]; assert h, "window not found"
user32.SetWindowPos(h, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)
user32.SetForegroundWindow(h); time.sleep(1.2)
pt = wt.POINT(0, 0); user32.ClientToScreen(h, ctypes.byref(pt)); cl, ct = pt.x, pt.y
S = 1.5
OUT = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
NAMES = ["主页", "效果", "脚本", "插件", "处理链", "可视化"]

def click(xl, yl):
    user32.SetCursorPos(int(cl + xl * S), int(ct + yl * S))
    user32.mouse_event(2, 0, 0, 0, 0); user32.mouse_event(4, 0, 0, 0, 0)

def shot():
    return ImageGrab.grab()

def lum(px, xl, yl):
    r, g, b = px[int(cl + xl * S), int(ct + yl * S)][:3]
    return (r + g + b) / 3

def label_visible(px, cy):
    """导航项文字是否可见（展开态才有）"""
    return sum(1 for yl in range(cy - 12, cy + 13) for xl in range(56, 90)
               if lum(px, xl, yl) > 70) > 20

ok = {}

# ---------- 阶段1：静态（不点击） ----------
px = shot().load()
icons = {n: sum(1 for yl in range(104 + 44 * i - 12, 104 + 44 * i + 13)
                for xl in range(30, 50) if lum(px, xl, yl) > 70)
         for i, n in enumerate(NAMES)}
print("1) rail 图标亮像素:", icons)
ok['icons'] = all(v >= 25 for v in icons.values())

hits = [xl for yl in range(12, 46) for xl in range(1200, 1360) if lum(px, xl, yl) > 90]
xs = sorted(set(hits))
clusters = []
for x in xs:
    if clusters and x - clusters[-1][-1] <= 3: clusters[-1].append(x)
    else: clusters.append([x])
centers = [(c[0] + c[-1]) // 2 for c in clusters]
print("2) 顶栏右侧簇中心:", centers, "(应含 状态徽标/外观/齿轮 三簇)")
ok['topbar'] = len(clusters) >= 3

# ---------- 阶段2：折叠 → 点 logo 展开 ----------
expanded_before = label_visible(px, 236)          # 插件项文字
print("3) 折叠前导航文字可见:", expanded_before)
ok['before'] = expanded_before

click(184, 44)                                     # 展开态折叠按钮
time.sleep(1.0)
px_c = shot().load()
collapsed = not label_visible(px_c, 236)
print("4) 点折叠按钮后文字消失（已收起）:", collapsed)
shot().save(os.path.join(OUT, "13-rail-collapsed-logo.png"))
ok['collapse'] = collapsed

click(32, 46)                                      # 收起态点 brand logo
time.sleep(1.0)
px_e = shot().load()
reexpanded = label_visible(px_e, 236)
print("5) 点 logo 后文字恢复（已展开）:", reexpanded)
shot().save(os.path.join(OUT, "14-rail-expanded-logo.png"))
ok['logo_expand'] = reexpanded

print("\nRESULT:", "PASS" if all(ok.values()) else "FAIL: %s" % [k for k, v in ok.items() if not v])
