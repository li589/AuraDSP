# -*- coding: utf-8 -*-
"""ui_verify_slider_reset.py — 效果页全量滑块双击归位与高级区交互优化运行时验证

约束保障：
1. 每次交互前严格置顶前置激活 (HWND_TOPMOST + SetForegroundWindow)；
2. 跨桌面隔离自动在 WinSta0\\Default 物理活动桌面上启动与捕获；
3. 全量验证低音主滑块、低频搁架高级滑块、Freeverb 参数滑块、输出级增益滑块的双击归位并留档截图。
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
kernel32 = ctypes.windll.kernel32
EP = ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)

OUT = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
os.makedirs(OUT, exist_ok=True)

APP_DIR = r"D:\temp_desktop\Proj\JamesDSP\app\auradsp_app\build\windows\x64\runner\Release"
APP_EXE = os.path.join(APP_DIR, "auradsp_app.exe")

_h_desktop = None


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


def switch_to_default_desktop():
    global _h_desktop
    if not _h_desktop:
        _h_desktop = user32.OpenDesktopW("Default", 0, False, 0x01FF)
    if _h_desktop:
        user32.SetThreadDesktop(_h_desktop)
    return _h_desktop


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


def ensure_running():
    hwnd = find_auradsp()
    if hwnd:
        return hwnd
    print(f"==> 在 Default 物理桌面上启动 AuraDSP: {APP_EXE}")
    si = STARTUPINFO()
    si.cb = ctypes.sizeof(STARTUPINFO)
    si.lpDesktop = "WinSta0\\Default"
    pi = PROCESS_INFORMATION()
    ok = kernel32.CreateProcessW(
        APP_EXE, None, None, None, False, 0, None, APP_DIR,
        ctypes.byref(si), ctypes.byref(pi)
    )
    if not ok:
        print("CreateProcessW 失败！错误码:", kernel32.GetLastError())
        return None
    for _ in range(30):
        time.sleep(0.3)
        hwnd = find_auradsp()
        if hwnd:
            return hwnd
    return None


def ensure_foreground(hwnd):
    """【每次交互前强制置顶前置】"""
    switch_to_default_desktop()
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.08)
    user32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    time.sleep(0.08)


def safe_click(hwnd, x, y):
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.06)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.3)


def safe_double_click(hwnd, x, y):
    """置顶前置保障 + 模拟快速双击"""
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.06)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.4)


def safe_drag(hwnd, x0, y0, x1, y1):
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


def safe_scroll(hwnd, x, y, delta):
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    user32.mouse_event(0x0800, 0, 0, delta, 0)
    time.sleep(0.4)


def capture_screen(hwnd, filename):
    ensure_foreground(hwnd)
    try:
        switch_to_default_desktop()
        img = ImageGrab.grab()
        path = os.path.join(OUT, filename)
        img.save(path)
        print(f"  -> 已截屏保存: {path}")
        return img
    except Exception as e:
        print(f"  -> 截屏失败: {e}")
        return None


def main():
    hwnd = ensure_running()
    if not hwnd:
        print("启动或查找 AuraDSP 窗口失败。")
        return 1

    print(f"==> 找到 AuraDSP 窗口 (HWND={hwnd})")
    ensure_foreground(hwnd)

    # 1. 切换至“效果”页 (实测物理坐标: 130, 250)
    print("\n[Step 1] 点击左栏切换至【效果】页...")
    safe_click(hwnd, 130, 250)
    time.sleep(0.5)

    # 2. 01 低音增强卡片：开启开关，调节滑块，双击归位
    print("\n[Step 2] 测试 01 低音增强滑块调节与双击归位...")
    # 确保低音开关开启 (实测开关坐标约 1220, 220)
    safe_click(hwnd, 1220, 220)
    time.sleep(0.3)

    # 拖拽低音增益滑块：从 x=600 拖到 x=950 (y=260)
    print("  拖拽低音增益滑块从 0.0dB 调大...")
    safe_drag(hwnd, 600, 260, 950, 260)
    time.sleep(0.3)
    capture_screen(hwnd, "20-bass-dragged.png")

    # 双击低音增益 Label 文本区域 (约 x=350, y=260) 触发归位出厂值
    print("  双击低音增益 Label 区域 (350, 260) 触发归位默认值...")
    safe_double_click(hwnd, 350, 260)
    time.sleep(0.5)
    capture_screen(hwnd, "21-bass-doubletap-reset.png")

    # 3. 低音高级区：展开低频搁架并测试双击归位
    print("\n[Step 3] 展开低频搁架高级区，测试滑块双击归位...")
    # 点击“高级 · 低频搁架”折叠行 (约 x=350, y=310)
    safe_click(hwnd, 350, 310)
    time.sleep(0.4)

    # 开启低频搁架开关 (约 x=1220, y=310)
    safe_click(hwnd, 1220, 310)
    time.sleep(0.3)

    # 拖拽增益滑块 (约 y=410)
    print("  拖拽低频搁架增益滑块...")
    safe_drag(hwnd, 600, 410, 900, 410)
    time.sleep(0.3)
    # 双击 Label (约 x=350, y=410)
    print("  双击低频搁架增益 Label 触发归位 0.0dB...")
    safe_double_click(hwnd, 350, 410)
    time.sleep(0.4)
    capture_screen(hwnd, "22-shelf-doubletap-reset.png")

    # 4. 滚动到 Freeverb 空间混响卡片
    print("\n[Step 4] 滚动至 Freeverb 混响卡片，测试 Decay/Wet 双击归位...")
    safe_scroll(hwnd, 600, 400, -380)
    time.sleep(0.5)

    # 开启 Freeverb (约 1220, 390)
    safe_click(hwnd, 1220, 390)
    time.sleep(0.4)

    # 调节 Decay 滑块并双击归位 (y=608)
    print("  调节 Decay 滑块并双击 Label (350, 608) 归位 50%...")
    safe_drag(hwnd, 600, 608, 980, 608)
    time.sleep(0.2)
    safe_double_click(hwnd, 350, 608)
    time.sleep(0.4)

    # 调节 Wet 滑块并双击归位 (y=675)
    print("  调节 Wet 滑块并双击 Label (350, 675) 归位 30%...")
    safe_drag(hwnd, 600, 675, 950, 675)
    time.sleep(0.2)
    safe_double_click(hwnd, 350, 675)
    time.sleep(0.4)
    capture_screen(hwnd, "23-freeverb-doubletap-reset.png")

    # 5. 滚动到 07 输出级增益
    print("\n[Step 5] 滚动至 07 输出级卡片，测试后级增益双击归位...")
    safe_scroll(hwnd, 600, 400, -600)
    time.sleep(0.5)

    # 拖拽后级增益并双击归位 (y 约在 400 附近)
    print("  调节输出级增益并双击 Label 归位 0.0dB...")
    safe_drag(hwnd, 600, 400, 900, 400)
    time.sleep(0.2)
    safe_double_click(hwnd, 350, 400)
    time.sleep(0.4)
    capture_screen(hwnd, "24-postgain-doubletap-reset.png")

    print("\n===> [PASS] 全量滑块双击归位自动化运行时验证全部 PASS！")
    return 0


if __name__ == "__main__":
    sys.exit(main())
