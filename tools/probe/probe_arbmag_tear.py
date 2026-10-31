#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_arbmag_tear.py — 探针：arbMag 主卷积「原位刷新」竞态的可观测性。

用途（P-047 / L-03 主卷积）：`ArbitraryResponseEqualizerStringParser` 对
`arbMag.conv` 做**原位** `RefreshImpulseResponse` —— 逐段改写 IR 的频域段
（`_segmentsLL/RRIRRe/Im`）。若与 RT 的 `FFTConvolver2x2Process` 并发，RT 会读到
「一半新、一半旧」的 IR ⇒ 滤波器响应既不是曲线 A 也不是曲线 B。

本探针用**两条直流增益相同、频谱不同**的曲线交替刷新：
    A = GraphicEQ: 20 0.0; 8000 12.0      （DC 增益 0 dB）
    B = GraphicEQ: 20 0.0; 8000 -12.0     （DC 增益 0 dB）
直流输入 ⇒ 稳态输出只取决于 DC 增益 ⇒ 合法换曲线**不产生跳变**；而撕裂的 IR
会让 DC 增益既不是 A 的也不是 B 的 ⇒ 输出出现偏离。

输出两个量：
    max_dev  —— 相对稳态值的最大偏离（相对幅度）
    n_dev    —— 偏离超过阈值（1%）的块数
用于对比「有锁 / 无锁」两种实现的差异。

用法：python tools/probe/probe_arbmag_tear.py [秒数]
"""
import ctypes
import math
import os
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 256
SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0

CURVE_A = b"GraphicEQ: 20 0.0; 8000 12.0"
CURVE_B = b"GraphicEQ: 20 0.0; 8000 -12.0"
DC = 0.30

dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

h = dll.auradsp_create(SR, BLOCK)
assert h, "create failed"


def i32(v):
    return ctypes.c_int32(v)


dll.auradsp_set_param(h, b"limiter.enable", ctypes.byref(i32(0)), 4)
dll.auradsp_set_param(h, b"arbmag.string", CURVE_A, len(CURVE_A))
dll.auradsp_set_param(h, b"arbmag.enable", ctypes.byref(i32(1)), 4)

buf = (ctypes.c_float * (BLOCK * 2))()
out = (ctypes.c_float * (BLOCK * 2))()
for i in range(BLOCK):
    buf[i * 2] = DC
    buf[i * 2 + 1] = DC

stop = threading.Event()
blocks = [0]
max_dev = [0.0]
n_dev = [0]
max_abs = [0.0]
sum_dev = [0.0]
n_dev_samples = [0]
curve_calls = [0]


def rt():
    k = 0
    prev = None
    while not stop.is_set():
        try:
            dll.auradsp_process(h, buf, out, BLOCK)
        except OSError as e:
            print("RT hard fault: %s" % e)
            return
        if k > 8:   # 跳过起始瞬态
            v = out[0]
            a = abs(v)
            if a > max_abs[0]:
                max_abs[0] = a
            if prev is not None:
                dev = abs(v - prev) / max(abs(prev), 1e-9)
                sum_dev[0] += dev
                n_dev_samples[0] += 1
                if dev > max_dev[0]:
                    max_dev[0] = dev
                if dev > 0.01:
                    n_dev[0] += 1
            prev = v
        k += 1
    blocks[0] = k


def ui():
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < SECONDS:
        dll.auradsp_set_param(h, b"arbmag.string",
                              CURVE_A if (n & 1) else CURVE_B, len(CURVE_A))
        n += 1
    curve_calls[0] = n


t_rt = threading.Thread(target=rt, daemon=True)
t_ui = threading.Thread(target=ui, daemon=True)
t_rt.start()
t_ui.start()
t_ui.join(SECONDS + 20)
stop.set()
t_rt.join(10)

print("blocks=%d curve_calls=%d" % (blocks[0], curve_calls[0]))
print("max_dev=%.6f%%  n_dev(>1%%)=%d" % (max_dev[0] * 100.0, n_dev[0]))
print("max_abs=%.4f  (input DC=%.3f, ratio=%.2fx)" % (max_abs[0], DC, max_abs[0] / DC))
if n_dev_samples[0]:
    print("mean_dev=%.6f%%  (n=%d)" % (sum_dev[0] / n_dev_samples[0] * 100.0,
                                       n_dev_samples[0]))
dll.auradsp_destroy(h)
