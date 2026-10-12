# -*- coding: utf-8 -*-
"""探针：量化引擎侧 viz（FFT + 32 带）的真实开销，用于定位「背景频谱降本」该动哪里。

测三件事：
  1) viz 帧的产/读成本（引擎 FFT + ring push）
  2) auradsp_viz_read 的读取成本（FFI 侧一次拉 8 帧）
  3) 不同 fftSize 下 process() 的每块平均耗时差 -> 隔离出 FFT 的边际成本

结论用于决定：降本是该动引擎 FFT，还是该动 UI 侧离屏图/分配。
"""
import ctypes
import math
import os
import time

DLL = r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll"
FS = 48000.0
BLOCK = 1024

dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]


class VizFrame(ctypes.Structure):
    _fields_ = [
        ("seq", ctypes.c_uint64),
        ("timestamp_ms", ctypes.c_double),
        ("spectrum", ctypes.c_float * 32),
        ("eq_in_spectrum", ctypes.c_float * 32),
        ("level_l_dbfs", ctypes.c_float),
        ("level_r_dbfs", ctypes.c_float),
        ("stage_levels_l", ctypes.c_float * 16),
        ("stage_levels_r", ctypes.c_float * 16),
    ]


VizFramePtr = ctypes.POINTER(VizFrame)
dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, VizFramePtr, ctypes.c_uint32]
dll.auradsp_viz_read.restype = ctypes.c_uint32


def bench(fft_size, blocks=3000, warm=500):
    h = ctypes.c_void_p(dll.auradsp_create(FS, BLOCK))
    dll.auradsp_set_param(h, b"viz.fftSize", ctypes.byref(ctypes.c_int32(fft_size)), 4)
    dll.auradsp_set_param(h, b"viz.interval", ctypes.byref(ctypes.c_int32(1600)), 4)
    bi = (ctypes.c_float * (BLOCK * 2))()
    bo = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK * 2):
        bi[i] = math.sin(2 * math.pi * 440.0 * i / FS) * 0.3
    vb = (VizFrame * 8)()
    total = 0.0
    for n in range(blocks):
        t0 = time.perf_counter()
        dll.auradsp_process(h, bi, bo, BLOCK)
        dt = time.perf_counter() - t0
        if n >= warm:
            total += dt
        if n % 33 == 0:
            dll.auradsp_viz_read(h, vb, 8)
    avg_us = total / (blocks - warm) * 1e6
    dll.auradsp_destroy(h)
    return avg_us


def bench_read(blocks=3000, warm=500):
    """只测 viz_read（含 FFI 边界）的每帧成本。"""
    h = ctypes.c_void_p(dll.auradsp_create(FS, BLOCK))
    dll.auradsp_set_param(h, b"viz.interval", ctypes.byref(ctypes.c_int32(1600)), 4)
    bi = (ctypes.c_float * (BLOCK * 2))()
    bo = (ctypes.c_float * (BLOCK * 2))()
    vb = (VizFrame * 8)()
    n_read = 0
    t_all = 0.0
    for n in range(blocks):
        dll.auradsp_process(h, bi, bo, BLOCK)
        if n >= warm:
            t0 = time.perf_counter()
            got = dll.auradsp_viz_read(h, vb, 8)
            t_all += time.perf_counter() - t0
            n_read += 1
    dll.auradsp_destroy(h)
    return t_all / max(1, n_read) * 1e6, n_read


print("== process() 每块平均耗时 vs viz fftSize（块=1024@48k） ==")
res = {}
for fs in (1024, 2048, 4096, 8192):
    res[fs] = bench(fs)
    print("  fftSize=%-5d %8.2f us/block   (%.2f%% of one 21.3ms block)"
          % (fs, res[fs], res[fs] / (BLOCK / FS * 1e6) * 100))

print("\n== FFT 边际成本（相邻档差） ==")
ks = sorted(res)
for a, b in zip(ks, ks[1:]):
    print("  %5d -> %-5d : %+.2f us/block" % (a, b, res[b] - res[a]))

read_us, n = bench_read()
print("\n== viz_read (FFI, 一次最多 8 帧) ==")
print("  %.2f us/次  (%d 次采样)" % (read_us, n))
print("\n参考：1 块 = %.1f ms 音频；UI 侧每帧另有 4 次 List 分配（32+16+16+doubling）"
      % (BLOCK / FS * 1e3))