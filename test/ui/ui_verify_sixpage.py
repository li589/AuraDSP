# -*- coding: utf-8 -*-
# 六页导航 + 处理链页运行时验证（截图 + 像素断言）
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
h = hwnd["h"]
assert h, "window not found"
user32.SetWindowPos(h, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)
user32.SetForegroundWindow(h); time.sleep(0.6)
pt = wt.POINT(0, 0); user32.ClientToScreen(h, ctypes.byref(pt)); cl, ct = pt.x, pt.y
print("client origin (%d,%d)" % (cl, ct))
OUT = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
os.makedirs(OUT, exist_ok=True)

def click(x, y):
    user32.SetCursorPos(int(x), int(y))
    user32.mouse_event(2, 0, 0, 0, 0); user32.mouse_event(4, 0, 0, 0, 0)

S = 1.5  # 150% DPI

def indicator_y(img):
    px = img.load()
    ys = [y for y in range(ct + int(90 * S), ct + int(420 * S))
          if any((lambda c: c[0] > 180 and c[1] > 220 and c[2] < 110)(px[x, y][:3])
                 for x in range(cl + int(10 * S), cl + int(26 * S)))]
    return (ys[0], ys[-1]) if ys else (None, None)

# 六项导航：带中心 y = 150 + 44*i（先探测首项位置）
NAMES = ["主页", "效果", "脚本", "插件", "处理链", "可视化"]
ok = True
seen = []
for i, name in enumerate(NAMES):
    y = 104 + 44 * i            # 实测带中心（像素探测：104/148/192/236/279/324）
    click(cl + int(108 * S), ct + int(y * S))
    time.sleep(0.9)
    img = ImageGrab.grab()
    lo, hi = indicator_y(img)
    seen.append((lo, hi))
    print("nav[%d] %-4s click_y=%d indicator=%s" % (i, name, y, lo))
    if name == "处理链":
        img.save(os.path.join(OUT, "12-chain-page.png"))
        print("  saved 12-chain-page.png")
# 断言：指示条严格单调递增且步长≈44（证明 6 项各自可选中）
los = [s[0] for s in seen]
mono = all(los[i+1] > los[i] for i in range(len(los)-1))
steps = [round((los[i+1]-los[i])/S) for i in range(len(los)-1)]
ok = mono and all(40 <= st <= 48 for st in steps)
print("indicator y =", los, "steps(logical) =", steps, "monotonic+deltas:", ok)

# 导航 rail 收起往返仍正常
click(cl + int(184 * S), ct + int(44 * S)); time.sleep(0.8)
img = ImageGrab.grab(); px = img.load()
collapsed_bg = px[cl + int(184 * S), ct + int(44 * S)][:3]
ok2 = sum(collapsed_bg) / 3 < 25
print("rail collapse: %s" % ("OK" if ok2 else "FAIL"))
click(cl + int(32 * S), ct + int(62 * S)); time.sleep(0.8)
print("RESULT:", "PASS" if (ok and ok2) else "CHECK NEEDED")
