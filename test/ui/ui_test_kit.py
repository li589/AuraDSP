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
import shutil
import subprocess
import tempfile
import time
from PIL import Image, ImageChops, ImageGrab


def _SCRATCH():
    """像素反查用的临时落盘路径（capture 需要真实路径才能截图）。"""
    return os.path.join(tempfile.gettempdir(), 'auradsp_ui_scratch.png')

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
psapi = ctypes.windll.psapi
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


def ensure_running(timeout=12.0):
    """确保 APP 正在运行并返回 hwnd；已在运行则直接返回。**不负责关闭。**

    存在的理由：各测试文件对生命周期的管理并不一致 ——
      * 用 AuraAppSession 的会在 __enter__ 杀进程重启、__exit__ 再关闭；
      * 用裸 Win32 的（ui_verify_chain_meter）结束时自行 kill，退出后没有进程；
      * 还有一类（ui_verify_effects_3d）自己 find_auradsp()，
        **要求 APP 已经在运行**，否则直接 FATAL。
    于是「前一个用例收尾把 APP 杀掉」会让后一个用例莫名其妙失败。
    runner 在每个用例前调用本函数，即可把前置条件收敛到一处。
    """
    hwnd = find_auradsp()
    if hwnd:
        return hwnd
    si = STARTUPINFO()
    si.cb = ctypes.sizeof(STARTUPINFO)
    si.lpDesktop = "WinSta0\\Default"
    pi = PROCESS_INFORMATION()
    if not kernel32.CreateProcessW(APP_EXE, None, None, None, False, 0, None,
                                  APP_DIR, ctypes.byref(si), ctypes.byref(pi)):
        return None
    for _ in range(max(1, int(timeout / 0.3))):
        time.sleep(0.3)
        hwnd = find_auradsp()
        if hwnd:
            return hwnd
    return None


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
            self._state_backup = {}
            self._stash_state()

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
        self._restore_state()
        return False

    # --- 持久化状态隔离 -------------------------------------------------
    # 症状：`effects_3d` / `advanced_sections` 单独跑通过、全量 runner 下失败。
    # 根因：`clean_start` 只杀进程重启，**不重置 %APPDATA% 里的持久化状态**，
    # 于是每个用例都从上一个用例留下的开关/滑块值/滚动位置开始跑。
    # 证据：实测同一份测试代码两次运行的控件坐标可相差 400px。
    #
    # 这里在 clean_start 下备份并清空可变状态文件，退出时原样恢复，
    # 既让用例确定性可复现，又不破坏开发者自己的应用设置。
    # 不动的文件：plugins/plugin_cache.json（派生缓存）、presets/factory（只读）。

    _VOLATILE_STATE = ('config.json', 'session_state.json')

    def _appdata_dir(self):
        return os.path.join(os.environ.get('APPDATA', ''), 'AuraDSP')

    def _stash_state(self):
        self._state_backup = {}
        base = self._appdata_dir()
        for name in self._VOLATILE_STATE:
            src = os.path.join(base, name)
            if os.path.exists(src):
                dst = os.path.join(tempfile.gettempdir(),
                                   'auradsp_state_%s_%d' % (name, os.getpid()))
                try:
                    shutil.copy2(src, dst)
                    self._state_backup[name] = dst
                    os.remove(src)
                except OSError as e:
                    print(f"[{self.title}] 状态备份失败 {name}: {e}")

    def _restore_state(self):
        if not getattr(self, '_state_backup', None):
            return
        base = self._appdata_dir()
        for name, dst in self._state_backup.items():
            try:
                shutil.copy2(dst, os.path.join(base, name))
                os.remove(dst)
            except OSError as e:
                print(f"[{self.title}] 状态恢复失败 {name}: {e}")
        self._state_backup = {}

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
        """滚轮。**符号约定极易踩坑**（已因此浪费多轮排查）：
        clicks > 0 → 向上滚（用于「回到顶部」）；clicks < 0 → 向下滚。
        Windows mouse_event(MOUSEEVENTF_WHEEL) 的 dwData 为正表示滚轮远离用户（即向上），
        故**想往下滚必须传负数**；传正数且已在顶部时完全无效果，
        很容易误判成「页面不可滚动」。
        """
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
                f"[{label}] 预期像素差分成立，但实测差异像素 {diff_count} < {min_diff_pixels}，控件可能未在响应态"
            )
        return diff_count

    # --- 像素反查：滑块 Thumb 定位 -------------------------------------------
    # 铁律：严禁盲写假坐标。滑块 Thumb 会随卡片开关状态与当前数值移动，
    # 硬编码 x 必然漂移（旧值 583 就因此落在轨道空白处，拖拽产生 0 差异）。
    # 在运行时从真实像素反查：accent 色的连通块里，轨道只有 ~4px 高，
    # 而 Thumb 是 ~13px 的圆 —— 按高度区分二者。
    ACCENT = (212, 255, 63)

    def _near(self, px, ref, tol=52):
        return (abs(px[0] - ref[0]) <= tol and abs(px[1] - ref[1]) <= tol
                and abs(px[2] - ref[2]) <= tol)

    def find_thumb(self, box, min_height=9):
        """在 box=(x0,y0,x1,y1)（窗口相对坐标）内定位滑块 Thumb 圆心。

        返回 (x, y)；找不到抛 AssertionError，绝不静默返回 None 让调用方
        继续用假坐标拖拽 —— 那只会得到 0 差异的假 PASS。
        """
        img = self.capture(_SCRATCH(), box)
        px = img.load()
        w, h = img.size
        cols = {}
        for x in range(w):
            run = 0
            best = 0
            for y in range(h):
                if self._near(px[x, y], self.ACCENT):
                    run += 1
                    best = max(best, run)
                else:
                    run = 0
            if best >= min_height:
                cols[x] = best
        if not cols:
            raise AssertionError(
                f"未能在 {box} 内定位到滑块 Thumb（accent 色块）；"
                "通常是控件未渲染、卡片开关未开，或 box 已随布局变化失效"
            )
        # 取纵向跨度最大的一簇，避免选中轨道上的细窄装饰块
        run_len = 0
        best_run = []
        for x in sorted(cols):
            if run_len == 0 or cols[x] >= 8:
                run_len += 1
                best_run.append(x)
            else:
                run_len = 1
                best_run = [x]
        center_x = int(sum(best_run) / len(best_run)) + box[0]
        y = self._thumb_row_y(px, cols, box)
        return (center_x, y)

    def find_card_switch(self, box, min_area=80):
        """在 box 内定位「卡片主开关」中心，返回 (x, y)。

        与滑块 Thumb 的区分：主开关是 ~19x20 / area>140 的实心 accent 方块，
        而滑块 Thumb 只有 ~13px 见方、面积远小于此。故取面积最大的 accent
        色块即为开关。严禁硬编码开关坐标 —— 卡片折叠/展开时 header 位置
        会整体平移，写死的 (x, y) 会点空，而只按颜色判断的 ensure_switch_on
        会「点空也不报错」，导致后续所有步骤建立在错误状态上。
        """
        img = self.capture(_SCRATCH(), box)
        px = img.load()
        w, h = img.size
        seen = [[False] * w for _ in range(h)]
        best = (0, 0, 0)  # (area, cx, cy)
        for y0 in range(h):
            for x0 in range(w):
                if seen[y0][x0] or not self._near(px[x0, y0], self.ACCENT):
                    continue
                stack = [(x0, y0)]
                seen[y0][x0] = True
                pts = []
                while stack:
                    x, y = stack.pop()
                    pts.append((x, y))
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] \
                                and self._near(px[nx, ny], self.ACCENT):
                            seen[ny][nx] = True
                            stack.append((nx, ny))
                if len(pts) < min_area:
                    continue
                xs = [p[0] for p in pts]
                ys = [p[1] for p in pts]
                a = len(pts)
                if a > best[0]:
                    best = (a, int(sum(xs) / len(xs)) + box[0],
                            int(sum(ys) / len(ys)) + box[1])
        if best[0] < min_area:
            raise AssertionError(
                f"未能于 {box} 内定位到卡片主开关（最大 accent 色块面积 {best[0]} < {min_area}）")
        return (best[1], best[2])

    def _thumb_row_y(self, px, cols, box):
        best_y, best_n = 0, -1
        w = max(cols) + 1 if cols else 0
        for y in range(box[3] - box[1]):
            n = sum(1 for x in range(w) if x in cols and self._near(px[x, y], self.ACCENT))
            if n > best_n:
                best_n, best_y = n, y
        return best_y + box[1]
