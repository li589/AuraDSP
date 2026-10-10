"""ui_test_kit.py — AuraDSP UI 自动化测试核心统一基建库

经验沉淀与设计规范：
1. DPI 缩放强制感知：启动前调用 SetProcessDpiAwareness(2)，彻底规避 125%/150% 物理坐标漂移；
2. 桌面会话隔离保护：主动切入 WinSta0\\Default 桌面，确保 CI/沙箱/后台执行时 Windows API 正常派发；
3. 孤儿进程清理与单例安全：启动前强制终止残留僵尸进程，退出时确保生命周期与会话文件落盘收敛；
4. 几何归一化标准：统一固定画布为 1400x900 像素，坐标系稳定可预测；
5. 语义化导航协议：支持 navigate_to("effects"|"chain"|"plugins"|"liveprog"|"settings")，屏蔽硬编码物理坐标；
6. 控件交互安全：提供 click, double_click, drag, scroll 以及带双重截屏比对的 assert_images_differ；
7. 上下文管理器支持：支持 `with AuraAppSession(...) as app:` 模式，实现 3 行极简编写新 UI 测试。
"""

import ctypes
import ctypes.wintypes as wt
import os
import subprocess
import time
from PIL import ImageChops, ImageGrab

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
gdi32 = ctypes.windll.gdi32
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
        self.refresh()

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


def kill_existing_instances():
    """强制清理可能残留的旧实例，确保会话与端口独占"""
    subprocess.run(["taskkill", "/F", "/IM", "auradsp_app.exe"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    time.sleep(0.3)


def find_auradsp():
    h_desk = switch_to_default_desktop()
    target = {"hwnd": None}

    def cb(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            b = ctypes.create_unicode_buffer(128)
            user32.GetWindowTextW(hwnd, b, 128)
            if b.value == "AuraDSP":
                target["hwnd"] = hwnd
                return False
        return True

    user32.EnumDesktopWindows(h_desk, EP(cb), 0)
    return target["hwnd"]


def ensure_foreground(hwnd):
    switch_to_default_desktop()
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.06)
    user32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    time.sleep(0.06)


class AuraAppSession:
    """AuraDSP 自动化测试统一上下文管理器"""
    def __init__(self, width=1400, height=900, clean_start=True, title="AuraDSP Test"):
        self.width = width
        self.height = height
        self.clean_start = clean_start
        self.title = title
        self.hwnd = None
        self.geom = None
        self.pi = None

    def __enter__(self):
        if self.clean_start:
            kill_existing_instances()

        hwnd = find_auradsp()
        if not hwnd:
            print(f"[{self.title}] 正在启动 AuraDSP: {APP_EXE}")
            si = STARTUPINFO()
            si.cb = ctypes.sizeof(STARTUPINFO)
            si.lpDesktop = "WinSta0\\Default"
            self.pi = PROCESS_INFORMATION()
            ok = kernel32.CreateProcessW(
                APP_EXE, None, None, None, False, 0, None, APP_DIR,
                ctypes.byref(si), ctypes.byref(self.pi)
            )
            if not ok:
                raise RuntimeError(f"CreateProcessW 失败，错误码: {kernel32.GetLastError()}")

            # 轮询等待窗口出现与渲染（最多等待 12 秒）
            for _ in range(40):
                time.sleep(0.3)
                hwnd = find_auradsp()
                if hwnd:
                    break

        if not hwnd:
            raise RuntimeError("未能启动或定位 AuraDSP 窗口！")

        self.hwnd = hwnd
        self.geom = WindowGeometry(hwnd)

        # 归一化窗口到标准物理尺寸与屏幕左上 (80, 50)
        ensure_foreground(self.hwnd)
        user32.MoveWindow(self.hwnd, 80, 50, self.width, self.height, True)
        time.sleep(0.5)
        ensure_foreground(self.hwnd)
        self.geom.refresh()
        print(f"[{self.title}] 窗口就绪: HWND=0x{self.hwnd:X}, 尺寸={self.geom.width}x{self.geom.height}")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.clean_start and self.hwnd:
            print(f"[{self.title}] 测试结束，优雅关闭应用...")
            user32.PostMessageW(self.hwnd, 0x0010, 0, 0)  # WM_CLOSE
            time.sleep(0.5)
            # 若仍未退出则兜底清理
            kill_existing_instances()
        return False

    def navigate_to(self, page_name: str, delay=0.5):
        """语义化导航到指定页面"""
        # 1400x900 画布标准下的导航条相对坐标
        nav_coords = {
            "home": (90, 201),
            "effects": (90, 267),
            "liveprog": (90, 332),
            "plugins": (90, 399),
            "chain": (90, 465),
            "visualizer": (90, 531),
            "settings": (1360, 28),  # 顶栏右上角设置齿轮
        }
        name_lower = page_name.lower()
        if name_lower not in nav_coords:
            raise ValueError(f"未知的导航目标: {page_name}，支持: {list(nav_coords.keys())}")
        rx, ry = nav_coords[name_lower]
        self.click(rx, ry, delay=delay)

    def click(self, rel_x: int, rel_y: int, delay=0.25):
        """点击窗口相对坐标 (rel_x, rel_y)"""
        ensure_foreground(self.hwnd)
        self.geom.refresh()
        abs_x = self.geom.left + int(rel_x)
        abs_y = self.geom.top + int(rel_y)
        user32.SetCursorPos(abs_x, abs_y)
        time.sleep(0.05)
        user32.mouse_event(0x0002, 0, 0, 0, 0)  # LEFTDOWN
        time.sleep(0.05)
        user32.mouse_event(0x0004, 0, 0, 0, 0)  # LEFTUP
        time.sleep(delay)

    def double_click(self, rel_x: int, rel_y: int, delay=0.3):
        """双击窗口相对坐标"""
        ensure_foreground(self.hwnd)
        self.geom.refresh()
        abs_x = self.geom.left + int(rel_x)
        abs_y = self.geom.top + int(rel_y)
        user32.SetCursorPos(abs_x, abs_y)
        time.sleep(0.05)
        user32.mouse_event(0x0002, 0, 0, 0, 0)
        user32.mouse_event(0x0004, 0, 0, 0, 0)
        time.sleep(0.05)
        user32.mouse_event(0x0002, 0, 0, 0, 0)
        user32.mouse_event(0x0004, 0, 0, 0, 0)
        time.sleep(delay)

    def drag(self, rel_x0: int, rel_x1: int, rel_y: int, steps=20, delay=0.3):
        """平滑横向拖拽"""
        ensure_foreground(self.hwnd)
        self.geom.refresh()
        y = self.geom.top + int(rel_y)
        x0 = self.geom.left + int(rel_x0)
        x1 = self.geom.left + int(rel_x1)
        user32.SetCursorPos(x0, y)
        time.sleep(0.08)
        user32.mouse_event(0x0002, 0, 0, 0, 0)
        time.sleep(0.05)
        for i in range(1, steps + 1):
            cur_x = x0 + (x1 - x0) * (i / steps)
            user32.SetCursorPos(int(cur_x), y)
            time.sleep(0.015)
        time.sleep(0.05)
        user32.mouse_event(0x0004, 0, 0, 0, 0)
        time.sleep(delay)

    def scroll(self, rel_x: int, rel_y: int, clicks: int = -5, delay=0.3):
        """鼠标滚轮滚动 (clicks < 0 向下滚动，clicks > 0 向上滚动)"""
        ensure_foreground(self.hwnd)
        self.geom.refresh()
        abs_x = self.geom.left + int(rel_x)
        abs_y = self.geom.top + int(rel_y)
        user32.SetCursorPos(abs_x, abs_y)
        time.sleep(0.05)
        user32.mouse_event(0x0800, 0, 0, int(clicks * 120), 0)
        time.sleep(delay)

    def capture(self, save_path: str, local_box=None):
        """高清截屏归档，自动建立父目录"""
        ensure_foreground(self.hwnd)
        self.geom.refresh()
        out_dir = os.path.dirname(os.path.abspath(save_path))
        os.makedirs(out_dir, exist_ok=True)

        if local_box is None:
            bbox = (self.geom.left, self.geom.top, self.geom.right, self.geom.bottom)
        else:
            bx0, by0, bx1, by1 = local_box
            bbox = (self.geom.left + bx0, self.geom.top + by0, self.geom.left + bx1, self.geom.top + by1)

        img = ImageGrab.grab(bbox=bbox)
        img.save(save_path)
        print(f"  [截图保存] -> {save_path} ({img.size[0]}x{img.size[1]})")
        return img

    def assert_images_differ(self, img_before, img_after, min_diff_pixels=20, label=""):
        """视觉差异严格断言"""
        diff = ImageChops.difference(img_before, img_after)
        stat = diff.convert("L").getdata()
        diff_count = sum(1 for p in stat if p > 15)
        if diff_count < min_diff_pixels:
            raise AssertionError(
                f"[{label}] 预期画面发生视觉更新，但实际差异像素仅 {diff_count} < {min_diff_pixels}！控件未生效或处于禁用态！"
            )
        return diff_count
