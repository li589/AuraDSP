"""mem_baseline.py — 内存基线取证。

背景：计划登记的 L-08。此前测得的 ~760 MB 稳态是在 **插件缓存只有 3 条伪造
路径** 的状态下取得的，而那 3 条根本加载不了插件。批次 A 修好缓存后插件数
变为 76，旧基线已失效，必须重测。

指标说明：
  * WorkingSet  —— 物理驻留，波动大，受系统缓存影响
  * PrivateBytes —— 私有提交量，最能反映进程自身真实占用，优先看它

用法（必须与启动 app 同一条命令，脚本只连接已有进程）：
  $p = Start-Process $exe -PassThru; python tools/mem_baseline.py; Stop-Process $p.Id
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
psapi = ctypes.windll.psapi

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


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


def main():
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 90
    pid = find_pid()
    if not pid:
        print('未找到 AuraDSP 窗口，请先在同一命令里启动 APP。')
        return 1

    print('=== 内存基线 ===')
    print('pid=%d  采样 %d 秒，每 3 秒一次\n' % (pid, seconds))
    print('%-7s %-12s %-14s %-12s' % ('t(s)', 'WorkingSet', 'PrivateBytes', 'PeakWS'))

    samples = []
    start = time.time()
    next_at = start
    while time.time() - start < seconds:
        now = time.time()
        if now >= next_at:
            m = read_mem(pid)
            if m:
                elapsed = now - start
                samples.append((elapsed, m))
                print('%-7.0f %-12.1f %-14.1f %-12.1f'
                      % (elapsed, m[0], m[1], m[2]))
            next_at = now + 3.0
        time.sleep(0.2)

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