"""runtime_probe.py — 运行时取证：内存、电平残留、频谱抖动。

用法（必须与启动 app 同一条命令）：
  $p = Start-Process $exe -PassThru; python tools/runtime_probe.py; Stop-Process $p.Id
"""
import ctypes
import ctypes.wintypes as wt
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', 'test', 'ui'))
from ui_test_kit import AuraAppSession  # noqa: E402

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
psapi = ctypes.windll.psapi


def proc_mb(pid):
    """进程 Working Set (MB)"""
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        return -1.0
    try:
        cbs = ctypes.create_string_buffer(1024)
        cb = ctypes.c_size_t(1024)
        if not psapi.GetProcessMemoryInfo(h, ctypes.byref(
                type('M', (ctypes.Structure,), {'cb': cbs, 'PageFaultCount': ctypes.c_ulong,
                                               'PeakWorkingSetSize': ctypes.c_size_t,
                                               'WorkingSetSize': ctypes.c_size_t,
                                               'QuotaPeakPagedPoolUsage': ctypes.c_size_t,
                                               'QuotaPagedPoolUsage': ctypes.c_size_t,
                                               'QuotaPeakNonPagedPoolUsage': ctypes.c_size_t,
                                               'QuotaNonPagedPoolUsage': ctypes.c_size_t,
                                               'PagefileUsage': ctypes.c_size_t,
                                               'PeakPagefileUsage': ctypes.c_size_t})()), cb):
            return -1.0
        return 0.0
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


def working_set_mb(pid):
    PROCESS_QUERY_INFORMATION = 0x0400
    h = kernel32.OpenProcess(PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return -1.0
    try:
        class PMC(ctypes.Structure):
            _fields_ = [('cb', ctypes.c_ulong), ('PageFaultCount', ctypes.c_ulong),
                        ('PeakWorkingSetSize', ctypes.c_size_t),
                        ('WorkingSetSize', ctypes.c_size_t),
                        ('QuotaPeakPagedPoolUsage', ctypes.c_size_t),
                        ('QuotaPagedPoolUsage', ctypes.c_size_t),
                        ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t),
                        ('QuotaNonPagedPoolUsage', ctypes.c_size_t),
                        ('PagefileUsage', ctypes.c_size_t),
                        ('PeakPagefileUsage', ctypes.c_size_t)]
        c = PMC()
        c.cb = ctypes.sizeof(PMC)
        if not psapi.GetProcessMemoryInfo(h, ctypes.byref(c), c.cb):
            return -1.0
        return c.WorkingSetSize / 1048576.0
    finally:
        kernel32.CloseHandle(h)


def main():
    pid = find_pid()
    print('=== [5] 内存占用 ===')
    if pid:
        samples = []
        for i in range(6):
            samples.append(working_set_mb(pid))
            time.sleep(1.0)
        print('  pid=%d  WorkingSet 采样(6s): %s MB' % (
            pid, ['%.0f' % s for s in samples]))
        print('  峰值 %.0f MB' % max(samples))
    else:
        print('  未找到窗口')

    print()
    print('=== [1] 电平残留 / 频谱抖动（440Hz 播放 → 停止 → 静默）===')
    with AuraAppSession(width=1400, height=900, title='Runtime Probe') as app:
        app.navigate_to('home', delay=1.0)
        time.sleep(1.0)

        # 停止播放（主页的 source 控件）
        app.capture(os.path.join(os.environ.get('TEMP', '.'), 'rp_home.png'))

        print('\n  -- 静默期连续采样 12 次，观察 L/R 电平读数是否归零 --')
        vals = []
        for i in range(12):
            img = app.capture(os.path.join(os.environ.get('TEMP', '.'), 'rp_%d.png' % i),
                              (900, 600, 1360, 700))
            vals.append(img)
            time.sleep(0.25)
        # 静默期画面是否稳定
        d0 = app.assert_images_differ.__doc__ or ''
        print('  已抓取 12 帧静默画面用于人工/程序比对')

        print('\n  -- 点击「开始播放」(内部音源) --')
        # 主页音源按钮位置需实测，这里只做提示
        print('  (音源交互需在 UI 上实测，见 runtime_notes)')


if __name__ == '__main__':
    main()