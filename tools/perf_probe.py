"""perf_probe.py — 引擎 RT 路径分段计时（只读诊断工具，不修改引擎）

用途：在真实块长下量化各段成本，供引擎性能评估。取多次重复的最小值以压低调度噪声。
运行：python tools/perf_probe.py
"""
import ctypes
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
if not os.path.exists(DLL):
    print(f"Error: DLL not found at {DLL}")
    sys.exit(1)

lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.restype = None
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.restype = None
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]

SR = 48000.0


def set_i32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def set_f32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)


def bench(h, frames, iters, repeats, label):
    """返回该配置下每块的最小耗时（秒）。"""
    n = frames * 2
    buf = (ctypes.c_float * n)()
    for i in range(0, n, 2):
        buf[i] = 0.35 * ((i % 97) / 97.0 - 0.5)
        buf[i + 1] = 0.35 * ((i % 89) / 89.0 - 0.5)
    src = ctypes.cast(buf, ctypes.POINTER(ctypes.c_float))
    dst = (ctypes.c_float * n)()
    dstp = ctypes.cast(dst, ctypes.POINTER(ctypes.c_float))
    for _ in range(100):
        lib.auradsp_process(h, src, dstp, frames)
    best = float("inf")
    for _ in range(repeats):
        t0 = time.perf_counter()
        for _ in range(iters):
            lib.auradsp_process(h, src, dstp, frames)
        best = min(best, (time.perf_counter() - t0) / iters)
    return best


def report(dt, frames, label):
    block_s = frames / SR
    print(f"  {label:<32} {dt*1e6:8.1f} us/block   {dt/block_s*100:6.3f}% RT   "
          f"实时倍率 x{block_s/dt:7.1f}")


def main():
    for frames in (480, 2048):
        block_s = frames / SR
        print(f"\n=== block = {frames} frames @48kHz ({block_s*1000:.2f} ms 预算) ===")
        h = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(SR), 2048))
        if not h:
            print("  create failed")
            return 1
        set_i32(h, "mode.latency", 2)
        iters = 3000 if frames == 480 else 800
        reps = 5

        report(bench(h, frames, iters, reps, "空引擎（全部效果关，含 viz）"), frames, "")
        set_i32(h, "bass.enable", 1); set_f32(h, "bass.gain", 6.0)
        set_i32(h, "reverb.preset", 1); set_i32(h, "eq.enable", 1)
        t = bench(h, frames, iters, reps, "bass+reverb+eq")
        report(t, frames, "")
        set_i32(h, "tube.enable", 1)
        t = bench(h, frames, iters, reps, "  + tube")
        report(t, frames, "")
        set_i32(h, "tube.enable", 0)
        set_i32(h, "freeverb.enable", 1)
        t = bench(h, frames, iters, reps, "  + Freeverb wrapper")
        report(t, frames, "")
        set_i32(h, "freeverb.enable", 0)
        set_i32(h, "crossfeed.enable", 1)
        t = bench(h, frames, iters, reps, "  + crossfeed")
        report(t, frames, "")
        set_i32(h, "crossfeed.enable", 0)
        set_i32(h, "limiter.enable", 1); set_f32(h, "post.gain", 3.0)
        set_f32(h, "shelf.freq", 120.0); set_f32(h, "shelf.gain", 4.0)
        set_i32(h, "shelf.enable", 1)
        t = bench(h, frames, iters, reps, "  + limiter/post/shelf")
        report(t, frames, "")
        lib.auradsp_destroy(h)

    print("\n=== 控制面开销（非 RT 线程）===")
    h = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(SR), 2048))
    curve = "".join(f"{20*(1.44**i):.1f}:{0.1*(i%5-2):.1f};" for i in range(15))
    cb = ctypes.create_string_buffer(curve.encode())
    set_i32(h, "mode.latency", 2); set_i32(h, "eq.enable", 1)
    lib.auradsp_set_param(h, b"eq.curve", ctypes.cast(cb, ctypes.c_void_p), len(curve))
    best = float("inf")
    for _ in range(5):
        t0 = time.perf_counter()
        for _ in range(200):
            lib.auradsp_set_param(h, b"eq.curve", ctypes.cast(cb, ctypes.c_void_p), len(curve))
        best = min(best, (time.perf_counter() - t0) / 200)
    print(f"  eq.curve 重算（UI 拖 EQ 节点每次）  {best*1e6:8.1f} us/call")
    best = float("inf")
    for _ in range(5):
        t0 = time.perf_counter()
        for i in range(2000):
            set_f32(h, "post.gain", (i % 20) * 0.1)
        best = min(best, (time.perf_counter() - t0) / 2000)
    print(f"  post.gain 简单参数                 {best*1e6:8.3f} us/call")
    lib.auradsp_destroy(h)
    return 0


if __name__ == "__main__":
    sys.exit(main())