"""log_clicks.py — 人工点击的旁路记录器。

用途：UI 自动化里最费时间的是「点了没反应」。本工具**不代点**，而是挂在
运行中的 APP 上做旁路记录，由人手动点击，它实时记下：

  * 时间戳（毫秒，相对启动）
  * 光标位置（窗口相对 + 屏幕绝对）
  * 光标下的像素 RGB 与分类（accent / light / dark / mid）
  * 点击前后 12x12 区域的像素差分 —— 差分为 0 即「点了但什么都没发生」
  * 进程 Working Set（观察内存随交互的变化）

用法：
  1) 手动启动 auradsp_app.exe
  2) python tools/log_clicks.py --seconds 180 --out clicks.csv
  3) 在 APP 里按需点击；结束时直接 Ctrl+C 或等计时结束
  4) 分析 clicks.csv

说明：轮询间隔 8ms，只读内存状态，不注入任何输入。
"""
import argparse
import csv
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), 'test', 'ui'))

import ui_test_kit as K  # noqa: E402
from PIL import ImageChops  # noqa: E402

SCRATCH = os.path.join(os.environ.get('TEMP', '.'), 'auradsp_click_log.png')
ACCENT = (212, 255, 63)
TOL = 52
VK_LBUTTON = 0x01
VK_ESCAPE = 0x1B
POLL = 0.008

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32


def cursor():
    pt = wt.POINT()
    user32.GetCursorPos(ctypes.byref(pt))
    return pt.x, pt.y


def classify(px):
    r, g, b = px[:3]
    lum = (r + g + b) / 3.0
    if (abs(r - ACCENT[0]) <= TOL and abs(g - ACCENT[1]) <= TOL
            and abs(b - ACCENT[2]) <= TOL):
        return 'accent'
    if lum > 170:
        return 'light'
    if lum < 40:
        return 'dark'
    return 'mid'


def working_set_mb(pid):
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

    class PMC(ctypes.Structure):
        # cb / PageFaultCount 是 DWORD，其余 SIZE_T —— 写错会让所有后续字段错位
        _fields_ = [('cb', ctypes.c_ulong), ('PageFaultCount', ctypes.c_ulong),
                    ('PeakWorkingSetSize', ctypes.c_size_t),
                    ('WorkingSetSize', ctypes.c_size_t),
                    ('QuotaPeakPagedPoolUsage', ctypes.c_size_t),
                    ('QuotaPagedPoolUsage', ctypes.c_size_t),
                    ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t),
                    ('QuotaNonPagedPoolUsage', ctypes.c_size_t),
                    ('PagefileUsage', ctypes.c_size_t),
                    ('PeakPagefileUsage', ctypes.c_size_t)]

    h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        return -1.0
    try:
        c = PMC()
        c.cb = ctypes.sizeof(PMC)
        if not K.psapi.GetProcessMemoryInfo(h, ctypes.byref(c), c.cb):
            return -1.0
        return c.WorkingSetSize / 1048576.0
    finally:
        kernel32.CloseHandle(h)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=int, default=180)
    ap.add_argument('--out', default='clicks.csv')
    ap.add_argument('--margin', type=int, default=6,
                    help='点击前后取样的半边长 px')
    ap.add_argument('--normalize', action='store_true',
                    help='把窗口强制归一化到 (80,50) 1400x900，与 UI 测试同基准')
    args = ap.parse_args()

    hwnd = K.find_auradsp()
    if not hwnd:
        print('未找到 AuraDSP 窗口，请先手动启动 APP。')
        return 1
    if args.normalize:
        # **必须归一化**：UI 测试里 AuraAppSession 会把窗口强制设为
        # (80,50) 1400x900，因此测试用的一切坐标都以该尺寸为基准。
        # 用户手动打开的窗口通常更大 —— 窗口更宽则滑轨更长、Thumb 更靠右，
        # 实测同一控件的 x 可相差 300px 以上，纵坐标却基本一致。
        # 不归一化就拿这些坐标去改测试，必然对不上。
        K.ensure_foreground(hwnd)
        K.user32.MoveWindow(hwnd, 80, 50, 1400, 900, True)
        time.sleep(0.8)
        print('窗口已归一化到 (80,50) 1400x900（与 UI 测试同基准）')
    geom = K.WindowGeometry(hwnd)
    pid = wt.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    print('已挂上窗口 HWND=0x%X pid=%d 位置=(%d,%d)' % (
        hwnd, pid.value, geom.left, geom.top))
    print('开始记录，按 ESC 或等计时结束。共 %d 秒\n' % args.seconds)
    print('%-8s %-12s %-18s %-8s %-7s %s' %
          ('t(ms)', '窗口xy', 'rgb', 'kind', 'diff', 'mem(MB)'))

    rows = []
    t0 = time.time()
    down_prev = False
    m = args.margin
    last_geom = (geom.left, geom.top)
    try:
        while time.time() - t0 < args.seconds:
            if user32.GetAsyncKeyState(VK_ESCAPE) & 0x8000:
                print('\n收到 ESC，停止记录。')
                break
            # 窗口被移动/缩放后坐标基准会漂移，每圈刷新一次
            geom.refresh()
            if (geom.left, geom.top) != last_geom:
                last_geom = (geom.left, geom.top)
                print('  [窗口移动] -> (%d,%d)' % last_geom)
            down = bool(user32.GetAsyncKeyState(VK_LBUTTON) & 0x8000)
            if down and not down_prev:
                # 按下瞬间：记位置与像素，并抓一张点击前的图
                sx, sy = cursor()
                wx, wy = sx - geom.left, sy - geom.top
                box = (geom.left + wx - m, geom.top + wy - m,
                       geom.left + wx + m, geom.top + wy + m)
                img = K.ImageGrab.grab(bbox=box)
                px = img.load()[m, m]
                time.sleep(0.20)  # 等 UI 响应
                after = K.ImageGrab.grab(bbox=box)
                d = ImageChops.difference(img, after).convert('L')
                diff = sum(1 for p in d.get_flattened_data() if p > 15)
                mem = working_set_mb(pid.value)
                ms = int((time.time() - t0) * 1000)
                kind = classify(px)
                rows.append((ms, wx, wy, sx, sy, px[0], px[1], px[2],
                             kind, diff, round(mem, 1)))
                print('%-8d (%5d,%5d) %-18s %-8s %-7d %.0f' % (
                    ms, wx, wy, tuple(px[:3]), kind, diff, mem))
            down_prev = down
            time.sleep(POLL)
    except KeyboardInterrupt:
        print('\nCtrl+C，停止记录。')

    with open(args.out, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['t_ms', 'win_x', 'win_y', 'screen_x', 'screen_y',
                    'r', 'g', 'b', 'kind', 'click_diff', 'ws_mb'])
        w.writerows(rows)
    print('\n共记录 %d 次点击，已导出 %s' % (len(rows), args.out))
    dead = [r for r in rows if r[9] == 0]
    if dead:
        print('其中 %d 次 diff=0（点击后无任何像素变化）：' % len(dead))
        for r in dead[:20]:
            print('  t=%dms (%d,%d) rgb=%s %s' % (r[0], r[1], r[2],
                                            (r[5], r[6], r[7]), r[8]))
    return 0


if __name__ == '__main__':
    sys.exit(main())