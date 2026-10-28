"""probe_load_live.py — 复现 VB 桥「先出声、后台补挂其余组」的加载期音频抖动。

结构对应 VmBridge：
  1) eng[0] 同步加载（用户主监听总线立即可用）；
  2) 其余组由后台线程逐个加载（每实例 ~2-4s，BELOW_NORMAL）；
  3) 期间 RT 回调继续跑 —— 用户听到的「刚加载一阵卡」就在这个窗口。

本探针不加载桥 DLL，只复现同一时序：
  handle0 加载 → 起 1 条定时处理线程 → 依次加载 handle1/2（记录耗时）
  → 可选打开编辑器 → 继续跑 N 秒 → 报告逐秒 p50/p95/max 与超预算块数。

判定：
  - 尖峰只出现在「某实例加载中/刚完成」的 1-3s 内 => 加载/初始化资源争用；
  - 加载完成 10s 后仍有尖峰 => Ozone 内部后台线程（分析/IR/UI）持续占用；
  - 全程无尖峰 => 桥的 BELOW_NORMAL/掩码/预算保护已足够，卡顿来自 GUI。

用法：
  python tools/probe/probe_load_live.py --instances 3 --frames 1024 --hold 20
  python tools/probe/probe_load_live.py --instances 3 --frames 1024 --hold 20 --editors 1
"""

import argparse
import ctypes
import json
import os
import statistics
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                        "auradsp_engine.dll")
OZONE_PATH = r"C:\Program Files\Common Files\VST3\iZotope\Ozone 12.vst3"
OZONE_ID = "5a5453564f424f5a7a6f6e6500000000"

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.GetCurrentThread.restype = ctypes.c_void_p
kernel32.SetThreadPriority.argtypes = [ctypes.c_void_p, ctypes.c_int]
kernel32.SetThreadPriority.restype = ctypes.c_int
winmm = ctypes.WinDLL("winmm")
THREAD_PRIORITY_TIME_CRITICAL = 15
THREAD_PRIORITY_NORMAL = 0
THREAD_PRIORITY_BELOW_NORMAL = -1


def set_current_thread_priority(prio):
    return bool(kernel32.SetThreadPriority(kernel32.GetCurrentThread(), prio))


def load_engine():
    lib = ctypes.CDLL(DLL_PATH)
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int,
    ]
    lib.auradsp_plugin_slot_load.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p
    ]
    lib.auradsp_plugin_slot_load.restype = ctypes.c_int
    lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.auradsp_plugin_slot_unload.restype = ctypes.c_int
    lib.auradsp_plugin_slot_show_editor.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p
    ]
    lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int
    lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p,
                                                    ctypes.c_int]
    lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int
    lib.auradsp_plugin_slot_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int
    ]
    lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int
    lib.auradsp_plugin_chain_set_enabled.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.auradsp_plugin_chain_set_enabled.restype = ctypes.c_int
    return lib


def slot_status(lib, h, slot=0):
    buf = ctypes.create_string_buffer(2048)
    n = lib.auradsp_plugin_slot_get_status(h, slot, buf, len(buf))
    if n <= 0:
        return {}
    try:
        return json.loads(buf.value.decode())
    except Exception:
        return {}


def free_mb():
    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ("dwLength", ctypes.c_uint32),
            ("dwMemoryLoad", ctypes.c_uint32),
            ("ullTotalPhys", ctypes.c_uint64),
            ("ullAvailPhys", ctypes.c_uint64),
            ("ullTotalPageFile", ctypes.c_uint64),
            ("ullAvailPageFile", ctypes.c_uint64),
            ("ullTotalVirtual", ctypes.c_uint64),
            ("ullAvailVirtual", ctypes.c_uint64),
            ("ullAvailExtendedVirtual", ctypes.c_uint64),
        ]
    st = MEMORYSTATUSEX()
    st.dwLength = ctypes.sizeof(st)
    ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st))
    return st.ullAvailPhys / (1024 * 1024)


class TimedRunner:
    """定时调用 process，记录每块墙钟（单写者）。"""

    def __init__(self, lib, handle, frames, sr=48000.0, rt_priority=True):
        self.lib = lib
        self.handle = handle
        self.frames = frames
        self.period = frames / sr
        self.rt_priority = rt_priority
        self.samples = []  # (elapsed_s, ms)
        self._stop = threading.Event()
        self._thr = None
        n = frames * 2
        self.src = (ctypes.c_float * n)()
        for i in range(n):
            self.src[i] = 0.15 * (((i * 17) % 101) / 50.0 - 1.0)
        self.dst = (ctypes.c_float * n)()

    def start(self):
        self._thr = threading.Thread(target=self._run, daemon=True)
        self._t0 = time.perf_counter()
        self._thr.start()

    def _run(self):
        # 对齐真实环境：Z17 worker 是 TIME_CRITICAL；探测线程也按实时优先级跑，
        # 否则普通优先级会把加载线程的 CPU 争用放大成假尖峰。
        if self.rt_priority:
            set_current_thread_priority(THREAD_PRIORITY_TIME_CRITICAL)
        srcp = ctypes.cast(self.src, ctypes.POINTER(ctypes.c_float))
        dstp = ctypes.cast(self.dst, ctypes.POINTER(ctypes.c_float))
        next_t = time.perf_counter()
        while not self._stop.is_set():
            t0 = time.perf_counter()
            self.lib.auradsp_process(self.handle, srcp, dstp, self.frames)
            dt = (time.perf_counter() - t0) * 1000.0
            self.samples.append((time.perf_counter() - self._t0, dt))
            next_t += self.period
            delay = next_t - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            else:
                next_t = time.perf_counter()

    def stop(self):
        self._stop.set()
        if self._thr:
            self._thr.join(timeout=5)
        return self.samples


def report(samples, period_ms, label):
    if not samples:
        print(f"  {label}: no samples")
        return
    buckets = {}
    for t, dt in samples:
        buckets.setdefault(int(t), []).append(dt)
    print(f"  {label} ({len(samples)} blocks, budget={period_ms:.2f}ms)")
    for sec in sorted(buckets):
        bs = sorted(buckets[sec])
        over = sum(1 for v in bs if v > period_ms)
        print(f"    t+{sec:3d}s n={len(bs):4d} p50={statistics.median(bs):6.2f} "
              f"p95={bs[int(len(bs) * 0.95)]:6.2f} max={max(bs):7.2f} "
              f"over={over}")
    allv = sorted(dt for _, dt in samples)
    print(f"    ALL p50={statistics.median(allv):6.2f} "
          f"p95={allv[int(len(allv) * 0.95)]:6.2f} "
          f"p99={allv[int(len(allv) * 0.99)]:6.2f} max={max(allv):7.2f} ms")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--instances", type=int, default=3)
    ap.add_argument("--frames", type=int, default=1024)
    ap.add_argument("--hold", type=float, default=20.0,
                    help="加载完成后的观察时长（秒）")
    ap.add_argument("--editors", type=int, default=0,
                    help="加载完成后打开几个编辑器（1..instances）")
    ap.add_argument("--bypass-during-load", action="store_true",
                    help="加载其余实例时临时关闭主组插件链，验证锁/争用假设")
    ap.add_argument("--no-rt-priority", dest="rt_priority", action="store_false",
                    help="探测线程用普通优先级（默认对齐真实环境 TIME_CRITICAL）")
    ap.add_argument("--no-timer-1ms", dest="timer_1ms", action="store_false",
                    help="不提升系统定时器精度（默认 timeBeginPeriod(1)）")
    ap.add_argument("--plugin", default=OZONE_PATH)
    ap.add_argument("--id", default=OZONE_ID)
    args = ap.parse_args()

    if not os.path.exists(DLL_PATH):
        print(f"engine not found: {DLL_PATH}")
        return 1
    if not os.path.exists(args.plugin):
        print(f"plugin not found: {args.plugin}")
        return 1

    lib = load_engine()
    handles = []
    period_ms = args.frames / 48.0
    if args.timer_1ms:
        winmm.timeBeginPeriod(1)
    print(f"engine={DLL_PATH}")
    print(f"plugin={os.path.basename(args.plugin)} frames={args.frames} "
          f"budget={period_ms:.2f}ms instances={args.instances}")
    print(f"free={free_mb():.0f}MB rt_prio={args.rt_priority} "
          f"timer1ms={args.timer_1ms}")

    try:
        # 1) 主组同步加载（对应桥的 eng[0]）
        h0 = lib.auradsp_create(ctypes.c_float(48000.0), args.frames)
        if not h0:
            print("create handle 0 failed")
            return 1
        t0 = time.perf_counter()
        rc = lib.auradsp_plugin_slot_load(h0, 0, args.plugin.encode(),
                                          args.id.encode())
        print(f"  handle[0] load rc={rc} {time.perf_counter() - t0:.2f}s "
              f"free={free_mb():.0f}MB")
        if rc != 1:
            return 1
        handles.append(h0)

        # 2) 起音频（模拟主监听总线已出声）
        runner = TimedRunner(lib, h0, args.frames, rt_priority=args.rt_priority)
        runner.start()
        time.sleep(2.0)
        print(f"  audio started; free={free_mb():.0f}MB")

        # 3) 依次加载其余组（对应后台补齐线程），记录耗时。
        #    桥的 GroupLoadWorker 是 BELOW_NORMAL；主线程同步降优先级以对齐。
        load_marks = []
        if args.bypass_during_load:
            print(f"  chain bypass ON during load: "
                  f"rc={lib.auradsp_plugin_chain_set_enabled(h0, 0)}")
        main_prio_ok = set_current_thread_priority(THREAD_PRIORITY_BELOW_NORMAL)
        print(f"  loader thread BELOW_NORMAL={main_prio_ok}")
        for i in range(1, args.instances):
            t0 = time.perf_counter()
            h = lib.auradsp_create(ctypes.c_float(48000.0), args.frames)
            if not h:
                print(f"create handle {i} failed")
                break
            rc = lib.auradsp_plugin_slot_load(h, 0, args.plugin.encode(),
                                              args.id.encode())
            dt = time.perf_counter() - t0
            print(f"  handle[{i}] load rc={rc} {dt:.2f}s "
                  f"free={free_mb():.0f}MB")
            if rc != 1:
                break
            handles.append(h)
            load_marks.append(time.perf_counter() - runner._t0)

        set_current_thread_priority(THREAD_PRIORITY_NORMAL)
        if args.bypass_during_load:
            print(f"  chain bypass OFF after load: "
                  f"rc={lib.auradsp_plugin_chain_set_enabled(h0, 1)}")

        # 4) 可选：打开编辑器（模拟加载后马上开界面）
        if args.editors > 0:
            for i, h in enumerate(handles[:args.editors]):
                t0 = time.perf_counter()
                rc = lib.auradsp_plugin_slot_show_editor(
                    h, 0, f"Ozone live {i + 1}".encode())
                print(f"  handle[{i}] show_editor rc={rc} "
                      f"{time.perf_counter() - t0:.2f}s "
                      f"free={free_mb():.0f}MB")
                load_marks.append(time.perf_counter() - runner._t0)

        # 5) 加载完成后的观察窗
        print(f"  hold {args.hold:.0f}s; free={free_mb():.0f}MB")
        time.sleep(args.hold)
        samples = runner.stop()
        print(f"  load/open marks (s since audio start): "
              f"{[round(v, 1) for v in load_marks]}")
        report(samples, period_ms, "handle0 process time")

        print(f"  status: " + " | ".join(
            f"h[{i}] calls={slot_status(lib, h).get('processCalls')} "
            f"in={slot_status(lib, h).get('inRms')} "
            f"out={slot_status(lib, h).get('outRms')}"
            for i, h in enumerate(handles)))
        return 0
    finally:
        for h in handles:
            try:
                lib.auradsp_plugin_slot_close_editor(h, 0)
            except Exception:
                pass
        time.sleep(0.5)
        for h in handles:
            try:
                lib.auradsp_plugin_slot_unload(h, 0)
            except Exception:
                pass
            try:
                lib.auradsp_destroy(h)
            except Exception:
                pass
        if args.timer_1ms:
            winmm.timeEndPeriod(1)


if __name__ == "__main__":
    sys.exit(main())
