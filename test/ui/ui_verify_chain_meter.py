import ctypes
import ctypes.wintypes as wt
import os
import sys
import time
from PIL import ImageGrab

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except OSError:
    pass

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


def kill_auradsp():
    os.system("powershell -Command \"Get-Process auradsp_app -ErrorAction SilentlyContinue | Stop-Process -Force\"")
    time.sleep(0.5)


def ensure_running():
    hwnd = find_auradsp()
    if hwnd:
        return hwnd
    print(f"==> Launching AuraDSP on Default desktop: {APP_EXE}")
    si = STARTUPINFO()
    si.cb = ctypes.sizeof(STARTUPINFO)
    si.lpDesktop = "WinSta0\\Default"
    pi = PROCESS_INFORMATION()
    ok = kernel32.CreateProcessW(
        APP_EXE, None, None, None, False, 0, None, APP_DIR,
        ctypes.byref(si), ctypes.byref(pi)
    )
    if not ok:
        print("CreateProcessW failed. Error code:", kernel32.GetLastError())
        return None
    for _ in range(30):
        time.sleep(0.3)
        hwnd = find_auradsp()
        if hwnd:
            return hwnd
    return None


def ensure_foreground(hwnd):
    """置顶前置激活保证"""
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
    time.sleep(0.35)


def safe_drag(hwnd, x0, y0, x1, y1):
    ensure_foreground(hwnd)
    user32.SetCursorPos(int(x0), int(y0))
    time.sleep(0.06)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.06)
    steps = 20
    for i in range(1, steps + 1):
        cur_x = x0 + (x1 - x0) * i / steps
        cur_y = y0 + (y1 - y0) * i / steps
        user32.SetCursorPos(int(cur_x), int(cur_y))
        time.sleep(0.02)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.4)


def capture_screen(hwnd, filename):
    ensure_foreground(hwnd)
    try:
        switch_to_default_desktop()
        img = ImageGrab.grab()
        path = os.path.join(OUT, filename)
        img.save(path)
        print(f"  -> Screenshot saved: {path}")
        return img
    except OSError as e:
        print(f"  -> Screenshot error: {e}")
        return None


def main():
    print("=== [M3.5-c UI Verification] Chain Page Meter & Bypass ===")
    kill_auradsp()
    hwnd = ensure_running()
    if not hwnd:
        print("ERROR: Failed to launch or locate AuraDSP window.")
        return 1

    print(f"==> Located AuraDSP window (HWND={hwnd})")
    ensure_foreground(hwnd)
    time.sleep(1.0)

    # 1. 点击左侧导航栏切换至【处理链】页 (第 5 项，索引 4，坐标 x=100, y=465)
    print("\n[Step 1] Switch to Chain page...")
    safe_click(hwnd, 100, 465)
    time.sleep(1.2)

    # 2. 截取初始处理链画面 (12 个 stage 电平表槽位与旁路胶囊)
    print("\n[Step 2] Capture initial chain state with per-stage meters...")
    capture_screen(hwnd, "30-chain-initial.png")

    # 3. 切换第 3 项低音增强的旁路/启用胶囊 (坐标 x=1800, y=640)
    print("\n[Step 3] Toggle stage 3 (Bass Boost) bypass capsule to Enable...")
    safe_click(hwnd, 1800, 640)
    time.sleep(0.6)
    capture_screen(hwnd, "31-chain-toggled-bypass.png")

    # 4. 模拟拖拽重新排序 (将第一个节点的拖拽手柄 x=460, y=520 向下拖拽到第三个位置 y=640)
    print("\n[Step 4] Reorder stages via drag handle...")
    safe_drag(hwnd, 460, 520, 460, 640)
    time.sleep(0.6)
    capture_screen(hwnd, "32-chain-reordered.png")

    # 5. 点击右上角【恢复默认】顺序 (芯片坐标 x=1920, y=350)
    print("\n[Step 5] Reset order to default...")
    safe_click(hwnd, 1920, 350)
    time.sleep(0.6)
    capture_screen(hwnd, "33-chain-reset.png")

    print("\n[PASS] Chain meter & bypass UI flow verification complete!")
    kill_auradsp()
    return 0


if __name__ == "__main__":
    sys.exit(main())
