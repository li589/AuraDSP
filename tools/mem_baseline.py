"""mem_baseline.py — 内存基线取证 + 点击记录（截图切片）。

背景：计划登记的 L-08 / L-15。此前测得的 ~760 MB 稳态是在 **插件缓存只有 3 条
伪造路径** 的状态下取得的，而那 3 条根本加载不了插件。修好后需重测；
L-15 进一步要求播放态基线，并定位「重度操作下 ~5 GB 暴涨」的触发点。

指标说明：
  * WorkingSet  —— 物理驻留，波动大，受系统缓存影响
  * PrivateBytes —— 私有提交量，最能反映进程自身真实占用，优先看它

点击记录（R2/L-15 新增，**已弃用 UIA**）：
  * 后台线程每 30ms **轮询** 左键状态（GetAsyncKeyState），**不装鼠标钩子、
    不锁鼠标**。
  * ⚠️ 历史教训：曾用 UI Automation 的 `ControlFromPoint` 读取点击控件名，
    结果**每点一次就触发 Flutter Windows 无障碍桥 `HitTestSync` 崩溃**
    （栈：accHitTest → AccessibilityBridge → HitTestSync）。已彻底移除 UIA。
  * 现改为：点击时保存光标周围一张小截图切片（PNG），事后看图即可识别点了什么。
    纯 GDI 截屏，不触碰目标进程，绝对安全。
  * 内存采样与点击事件写入同一时间轴，并落 CSV。

用法（与启动 app 同一条命令；脚本只连接已有进程，不控制鼠标）：
  python tools/mem_baseline.py [秒数] [采样间隔秒]

输出：
  * 终端：内存表 + 点击事件行（同轴）
  * CSV ：tools/mem_trace_YYYYmmdd_HHMMSS.csv
  * 切片：tools/mem_trace_YYYYmmdd_HHMMSS_clicks/click_*.png
"""
import ctypes
import ctypes.wintypes as wt
import csv
import datetime
import os
import sys
import threading
import time

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
psapi = ctypes.windll.psapi

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
VK_LBUTTON = 0x01

_print_lock = threading.Lock()


class _PMC(ctypes.Structure):
    # 注意：PROCESS_MEMORY_COUNTERS 的 cb / PageFaultCount 是 DWORD（4 字节），
    # 其余为 SIZE_T（8 字节）。若把前两个写成 c_size_t，后续字段全部错位，
    # 会读出「WorkingSet 0.8 MB」这种明显荒谬的值。
    _fields_ = [
        ('cb', ctypes.c_ulong),
        ('PageFaultCount', ctypes.c_ulong),
        ('PeakWorkingSetSize', ctypes.c_size_t),
        ('WorkingSetSize', ctypes.c_size_t),
        ('QuotaPeakPagedPoolUsage', ctypes.c_size_t),
        ('QuotaPagedPoolUsage', ctypes.c_size_t),
        ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t),
        ('QuotaNonPagedPoolUsage', ctypes.c_size_t),
        ('PagefileUsage', ctypes.c_size_t),
        ('PeakPagefileUsage', ctypes.c_size_t),
    ]


def read_mem(pid):
    """返回 (WorkingSet MB, PrivateBytes MB, PeakWorkingSet MB)"""
    h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        return None
    try:
        c = _PMC()
        c.cb = ctypes.sizeof(_PMC)
        if not psapi.GetProcessMemoryInfo(h, ctypes.byref(c), c.cb):
            return None
        return (c.WorkingSetSize / 1048576.0,
                c.PagefileUsage / 1048576.0,
                c.PeakWorkingSetSize / 1048576.0)
    finally:
        kernel32.CloseHandle(h)


def find_pid():
    WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    found = []

    def cb(hwnd, _):
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value:
            buf = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, buf, 256)
            if 'AuraDSP' in buf.value:
                found.append(pid.value)
        return True

    user32.EnumWindows(WNDENUMPROC(cb), 0)
    return found[0] if found else None


# ---- 点击记录（截图切片，无 UIA） ---------------------------------------

_crop_dir = None


def _crop_click(x, y, t):
    """保存点击点周围的小截图；纯 GDI 截屏，不触碰目标进程。"""
    try:
        from PIL import ImageGrab
    except Exception:
        return ''
    if not _crop_dir:
        return ''
    half_w, half_h = 160, 110
    bbox = (x - half_w, y - half_h, x + half_w, y + half_h)
    try:
        img = ImageGrab.grab(bbox=bbox)
        p = os.path.join(_crop_dir, 'click_%07.2f_%d_%d.png' % (t, x, y))
        img.save(p)
        return p
    except Exception:
        return ''


def click_watcher(stop_evt, start, sink):
    last = False
    while not stop_evt.is_set():
        try:
            pressed = (user32.GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0
        except Exception:
            pressed = False
        if pressed and not last:
            pt = wt.POINT()
            user32.GetCursorPos(ctypes.byref(pt))
            t = time.time() - start
            crop = _crop_click(pt.x, pt.y, t)
            with _print_lock:
                print('  [CLICK %6.1fs] (%d,%d)  %s'
                      % (t, pt.x, pt.y, os.path.basename(crop) if crop else ''))
                sys.stdout.flush()
            sink.append(('click', t, None, None, None, pt.x, pt.y,
                         os.path.basename(crop) if crop else ''))
        last = pressed
        time.sleep(0.03)


def main():
    global _crop_dir
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 90
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    pid = find_pid()
    if not pid:
        print('未找到 AuraDSP 窗口，请先在同一命令里启动 APP。')
        return 1

    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        f'mem_trace_{stamp}')
    _crop_dir = base + '_clicks'
    try:
        os.makedirs(_crop_dir, exist_ok=True)
    except Exception:
        _crop_dir = None

    print('=== 内存基线 + 点击记录 ===')
    print('pid=%d  采样 %d 秒，每 %.1f 秒一次' % (pid, seconds, interval))
    print('%-7s %-12s %-14s %-12s' % ('t(s)', 'WorkingSet', 'PrivateBytes', 'PeakWS'))

    start = time.time()
    rows = []  # (kind, t, ws, pb, peak, x, y, note)
    stop_evt = threading.Event()
    watcher = threading.Thread(target=click_watcher,
                               args=(stop_evt, start, rows), daemon=True)
    watcher.start()

    samples = []
    next_at = start
    while time.time() - start < seconds:
        now = time.time()
        if now >= next_at:
            m = read_mem(pid)
            if m:
                elapsed = now - start
                samples.append((elapsed, m))
                with _print_lock:
                    print('%-7.0f %-12.1f %-14.1f %-12.1f'
                          % (elapsed, m[0], m[1], m[2]))
                    sys.stdout.flush()
                rows.append(('mem', elapsed, m[0], m[1], m[2], None, None, ''))
            next_at = now + interval
        time.sleep(0.1)

    stop_evt.set()

    csv_path = base + '.csv'
    try:
        with open(csv_path, 'w', newline='', encoding='utf-8') as f:
            w = csv.writer(f)
            w.writerow(['t_sec', 'kind', 'ws_mb', 'private_mb', 'peak_mb',
                        'screen_x', 'screen_y', 'snippet'])
            for r in sorted(rows, key=lambda r: r[1]):
                w.writerow([f'{r[1]:.2f}', r[0]] +
                           [(f'{v:.1f}' if isinstance(v, float) else (v or ''))
                            for v in r[2:]])
        print(f'\nCSV -> {csv_path}')
        if _crop_dir:
            print(f'点击切片 -> {_crop_dir}')
    except Exception as e:
        print(f'CSV 写入失败: {e}')

    if not samples:
        print('未取到样本。')
        return 1

    ws = [s[1][0] for s in samples]
    pb = [s[1][1] for s in samples]
    tail = samples[len(samples) // 2:]
    steady_ws = sum(s[1][0] for s in tail) / len(tail)
    steady_pb = sum(s[1][1] for s in tail) / len(tail)

    print('\n--- 结论 ---')
    print('WorkingSet : 起 %.0f MB, 峰 %.0f MB, 后半程均值 %.0f MB, 末值 %.0f MB'
          % (ws[0], max(ws), steady_ws, ws[-1]))
    print('Private    : 起 %.0f MB, 峰 %.0f MB, 后半程均值 %.0f MB, 末值 %.0f MB'
          % (pb[0], max(pb), steady_pb, pb[-1]))
    drift = pb[-1] - pb[0]
    print('Private 漂移(末-起): %+.0f MB' % drift)
    if drift > 80:
        print('判定: 存在持续增长，需进一步定位。')
    else:
        print('判定: 无明显持续增长（非泄漏型），属稳态偏高。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
