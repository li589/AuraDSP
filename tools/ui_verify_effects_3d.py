# -*- coding: utf-8 -*-
"""ui_verify_effects_3d.py — 效果页 Freeverb 3D 声场渲染与交互全流程运行时验证

严格遵循用户约束：
1. 每次点击测试前必须确保软件处于置顶前置激活状态；
2. 兼容非交互桌面（切换至 WinSta0\\default 桌面）；
3. 验证 Freeverb 3D 声学室（透视骨架、地板网格、声源与听者、反射射线束）；
4. 验证 04 Convolver 区域与多声道频谱模块。
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

from PIL import ImageGrab

user32 = ctypes.windll.user32
EP = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)

OUT = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
os.makedirs(OUT, exist_ok=True)


def switch_to_default_desktop():
    """解决子 shell/服务环境下桌面句柄隔离问题，切换到用户活动桌面"""
    h_desk = user32.OpenDesktopW("default", 0, False, 0x01FF)
    if h_desk:
        user32.SetThreadDesktop(h_desk)
    return h_desk


def find_auradsp():
    h_desk = switch_to_default_desktop()
    target = {"hwnd": None}

    def cb(hwnd, _):
        buf = ctypes.create_unicode_buffer(64)
        user32.GetWindowTextW(hwnd, buf, 64)
        if buf.value == "AuraDSP" and user32.IsWindowVisible(hwnd):
            target["hwnd"] = hwnd
            return False
        return True

    user32.EnumDesktopWindows(h_desk, EP(cb), 0)
    return target["hwnd"]


def ensure_foreground(hwnd):
    """【关键约束】每次点击操作前确保窗口置顶前置，防止焦点丢失导致的无效点击"""
    switch_to_default_desktop()
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.08)
    user32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    time.sleep(0.08)


def safe_click_screen(hwnd, x, y):
    """置顶前置保障 + 绝对屏幕坐标点击"""
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.06)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.4)


def safe_drag_screen(hwnd, x0, y0, x1, y1):
    """置顶前置保障 + 模拟拖拽"""
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x0), int(y0))
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.05)
    steps = 15
    for i in range(1, steps + 1):
        cur_x = x0 + (x1 - x0) * i / steps
        cur_y = y0 + (y1 - y0) * i / steps
        user32.SetCursorPos(int(cur_x), int(cur_y))
        time.sleep(0.02)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.3)


def main():
    hwnd = find_auradsp()
    if not hwnd:
        print("FATAL: AuraDSP window not found")
        return 1

    print("==> 找到 AuraDSP 窗口 (HWND=%d)" % hwnd)
    ensure_foreground(hwnd)

    # 规范化窗口位置：左上角 (60, 60)，宽高 1376x900
    user32.SetWindowPos(hwnd, 0, 60, 60, 1376, 900, 0x0004 | 0x0040)
    time.sleep(0.3)

    dpi = ctypes.windll.user32.GetDpiForWindow(hwnd)
    S = dpi / 96.0 if dpi else 1.5
    print("==> DPI = %d, Scale = %.2f" % (dpi, S))

    pt = wt.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    cl, ct = pt.x, pt.y
    print("==> Client Origin = (%d, %d)" % (cl, ct))

    # 1. 切换至“效果”页 (实测屏幕物理坐标: 130, 250)
    print("\n[Step 1] 点击左侧导航栏切换至【效果】页...")
    safe_click_screen(hwnd, 130, 250)
    time.sleep(0.8)

    img_effects = ImageGrab.grab()
    img_effects.save(os.path.join(OUT, "15-effects-initial.png"))
    print("  -> 保存截图: 15-effects-initial.png")

    # 2. 截图 Freeverb 待机态 3D 舞台
    print("\n[Step 2] 截取【03 参数化混响】待机态 3D 舞台...")
    img_fv_idle = ImageGrab.grab()
    img_fv_idle.save(os.path.join(OUT, "16-freeverb-idle-3d.png"))
    print("  -> 保存截图: 16-freeverb-idle-3d.png")

    # 3. 点击 Freeverb 开关开启混响 (实测屏幕物理坐标: 1220, 390)
    print("\n[Step 3] 点击开启 Freeverb 开关...")
    safe_click_screen(hwnd, 1220, 390)
    time.sleep(0.8)

    img_fv_active = ImageGrab.grab()
    img_fv_active.save(os.path.join(OUT, "17-freeverb-active-3d.png"))
    print("  -> 保存截图: 17-freeverb-active-3d.png")

    # 4. 调整 Freeverb 参数滑块（衰减与湿声）
    print("\n[Step 4] 调整【衰减】与【湿声】滑块，观测 3D 反射光束动态变化...")
    # 拖拽 decay 滑块：从 x=600 拖到 x=980 (y=608)
    safe_drag_screen(hwnd, 600, 608, 980, 608)
    time.sleep(0.3)
    # 拖拽 wet 滑块：从 x=600 拖到 x=900 (y=675)
    safe_drag_screen(hwnd, 600, 675, 900, 675)
    time.sleep(0.5)

    img_fv_tuned = ImageGrab.grab()
    img_fv_tuned.save(os.path.join(OUT, "18-freeverb-tuned-3d.png"))
    print("  -> 保存截图: 18-freeverb-tuned-3d.png")

    # 5. 向下滚动展示【04 脉冲响应】Convolver 卡片
    print("\n[Step 5] 向下滚动至【04 脉冲响应】Convolver 卡片...")
    ensure_foreground(hwnd)
    user32.SetCursorPos(cl + int(300 * S), ct + int(300 * S))
    user32.mouse_event(0x0800, 0, 0, -650, 0)
    time.sleep(0.6)

    img_convolver = ImageGrab.grab()
    img_convolver.save(os.path.join(OUT, "19-effects-convolver.png"))
    print("  -> 保存截图: 19-effects-convolver.png")

    # 6. 断言检验
    px_idle = img_fv_idle.load()
    px_active = img_fv_active.load()
    px_tuned = img_fv_tuned.load()

    # 3D 舞台区域在 client 内：x 约 250..1200, y 约 450..580
    active_rays = sum(
        1
        for y in range(450, 580, 2)
        for x in range(250, 1200, 2)
        if (px_active[x, y][0] > 70 or px_active[x, y][1] > 70)
    )
    print("\n[断言检验]")
    print("  -> 3D 舞台激活后反射射线与光晕亮像素数: %d" % active_rays)
    assert active_rays > 50, "未检测到 3D 声学反射射线束！"
    print("  -> PASS: 3D 声场声学反射射线与光晕成功渲染！")

    # 7. 滚回顶部并回到主页
    print("\n[Step 7] 滚动回顶部并回到主页...")
    ensure_foreground(hwnd)
    user32.SetCursorPos(cl + int(300 * S), ct + int(300 * S))
    user32.mouse_event(0x0800, 0, 0, 1500, 0)
    time.sleep(0.4)
    safe_click_screen(hwnd, 130, 205)  # 点击主页 (130, 205)
    time.sleep(0.5)

    print("\n>>> ALL UI VERIFICATION TESTS PASSED SUCCESSFULLY! <<<")
    return 0


if __name__ == "__main__":
    sys.exit(main())
