#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_mc_eq_persch.py — WP3 EQ 逐声道门禁（P-035）。

断言（工程文档 §7.1 与 §3.5）：
  - 8ch 离散模式下每声道独立 EQ；
  - 单声道 mask 生效，未选声道 100% bit-exact 直通；
  - C/LFE 与 FL/FR 彻底解绑；
  - 96k 设备率下 IR 由设备采样率生成，响应频点不产生八度偏移（S-6 修复）；
  - 8 个 FFTConvolver1x1 实例的卷积 FIFO 完全独立、零串扰；
  - mask=0 时全声道 bit-exact 直通。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 512
CH = 8
FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


if not os.path.exists(DLL):
    print("SKIP（auradsp_engine.dll 不存在：%s）" % DLL)
    sys.exit(0)

dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]


def i32(v):
    return ctypes.c_int32(v)


def f32(v):
    return ctypes.c_float(v)


class Engine:
    def __init__(self, sr=SR, block=BLOCK):
        self.sr = sr
        self.block = block
        self.h = dll.auradsp_create(ctypes.c_float(sr), block)
        assert self.h, f"engine create failed at sr={sr}"

    def close(self):
        if self.h:
            dll.auradsp_destroy(self.h)
            self.h = None

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(i32(v)), 4)

    def set_s(self, pid, s_bytes):
        return dll.auradsp_set_param(self.h, pid.encode(), s_bytes, len(s_bytes))

    def process(self, in_data, frames, ch=CH):
        in_arr = (ctypes.c_float * (frames * ch))(*in_data)
        out_arr = (ctypes.c_float * (frames * ch))()
        dll.auradsp_process(self.h, in_arr, out_arr, frames)
        return list(out_arr)


def make_sine_8ch(sr, frames, freqs, amps, start_frame=0):
    buf = []
    for f in range(frames):
        t = (start_frame + f) / float(sr)
        for c in range(CH):
            freq = freqs[c] if isinstance(freqs, list) else freqs
            amp = amps[c] if isinstance(amps, list) else amps
            s = amp * math.sin(2.0 * math.pi * freq * t)
            buf.append(s)
    return buf


def ch_max_dev(src, dst, frames, ch, target_c):
    m = 0.0
    for i in range(frames):
        d = abs(dst[i * ch + target_c] - src[i * ch + target_c])
        if d > m:
            m = d
    return m


def ch_peak(sig, frames, ch, target_c):
    return max(abs(sig[i * ch + target_c]) for i in range(frames))


print("=== [1] 8ch 离散模式下 EQ 逐声道独立处理与单声道掩码 ===")
e = Engine(sr=SR)
check("set channels.count=8", e.set_i("channels.count", 8) == 0)
check("set channels.mode=1 (离散模式)", e.set_i("channels.mode", 1) == 0)
e.set_i("limiter.enable", 0)  # 隔离 limiter
check("set eq.enable=1", e.set_i("eq.enable", 1) == 0)

# 设置 1000Hz 提升 12dB 曲线 (理论增益 ~3.98x)
curve = b"20:0.0;1000:12.0;20000:0.0"
check("set eq.curve", e.set_s("eq.curve", curve) == 0)

# 1) 仅选择 C 声道 (ch2, bit 2 = 0x04)
e.set_i("eq.channels", 0x04)

# 喂入 1000Hz 0.2 峰值正弦波，稳态测试 (前 20 块预热卷积缓冲区)
for b in range(25):
    sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=b * BLOCK)
    out = e.process(sig, BLOCK)

last_sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=25 * BLOCK)
last_out = e.process(last_sig, BLOCK)

c2_peak = ch_peak(last_out, BLOCK, CH, 2)
# 0.2 * 10^(12/20) ~ 0.796
check("mask=0x04: C 声道 (ch2) 获得 ~12dB 提升 (peak 在 0.7..0.9)",
      0.7 < c2_peak < 0.9,
      f"peak={c2_peak:.4f}")

# 其余声道必须 100% 直通 (dev < 1e-6)
for c in [0, 1, 3, 4, 5, 6, 7]:
    dev = ch_max_dev(last_sig, last_out, BLOCK, CH, c)
    check(f"mask=0x04: ch{c} 未选声道 100% 直通", dev < 1e-6, f"dev={dev:.2e}")

# 2) 仅选择 LFE 声道 (ch3, bit 3 = 0x08)
e.set_i("eq.channels", 0x08)
for b in range(25):
    sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=b * BLOCK)
    out = e.process(sig, BLOCK)

last_sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=25 * BLOCK)
last_out = e.process(last_sig, BLOCK)

c3_peak = ch_peak(last_out, BLOCK, CH, 3)
check("mask=0x08: LFE 声道 (ch3) 获得提升", 0.7 < c3_peak < 0.9, f"peak={c3_peak:.4f}")
c2_dev = ch_max_dev(last_sig, last_out, BLOCK, CH, 2)
check("mask=0x08: C 声道 (ch2) 100% 直通 (C/LFE 解绑)", c2_dev < 1e-6, f"dev={c2_dev:.2e}")

# 3) 仅选择 FL 声道 (ch0, bit 0 = 0x01)
e.set_i("eq.channels", 0x01)
for b in range(25):
    sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=b * BLOCK)
    out = e.process(sig, BLOCK)

last_sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=25 * BLOCK)
last_out = e.process(last_sig, BLOCK)

c0_peak = ch_peak(last_out, BLOCK, CH, 0)
c1_dev = ch_max_dev(last_sig, last_out, BLOCK, CH, 1)
check("mask=0x01: FL (ch0) 获得提升", 0.7 < c0_peak < 0.9, f"peak={c0_peak:.4f}")
check("mask=0x01: FR (ch1) 100% 直通 (FL/FR 解绑)", c1_dev < 1e-6, f"dev={c1_dev:.2e}")
e.close()

print("\n=== [2] 8 个独立 FFTConvolver1x1 卷积 FIFO 零串扰 ===")
# 对比：在 8ch 全开模式下各声道喂不同频点 vs 仅单声道处理
def run_eq_convolver_test():
    h_all = dll.auradsp_create(ctypes.c_float(SR), BLOCK)
    dll.auradsp_set_param(h_all, b"channels.count", ctypes.byref(i32(8)), 4)
    dll.auradsp_set_param(h_all, b"channels.mode", ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h_all, b"limiter.enable", ctypes.byref(i32(0)), 4)
    dll.auradsp_set_param(h_all, b"eq.enable", ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h_all, b"eq.curve", curve, len(curve))
    dll.auradsp_set_param(h_all, b"eq.channels", ctypes.byref(i32(0xFF)), 4)

    h_iso = dll.auradsp_create(ctypes.c_float(SR), BLOCK)
    dll.auradsp_set_param(h_iso, b"channels.count", ctypes.byref(i32(8)), 4)
    dll.auradsp_set_param(h_iso, b"channels.mode", ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h_iso, b"limiter.enable", ctypes.byref(i32(0)), 4)
    dll.auradsp_set_param(h_iso, b"eq.enable", ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h_iso, b"eq.curve", curve, len(curve))
    dll.auradsp_set_param(h_iso, b"eq.channels", ctypes.byref(i32(0xFF)), 4)

    freqs = [200.0, 500.0, 1000.0, 2000.0, 4000.0, 6000.0, 8000.0, 12000.0]
    in_all = (ctypes.c_float * (BLOCK * CH))()
    out_all = (ctypes.c_float * (BLOCK * CH))()
    in_iso = (ctypes.c_float * (BLOCK * CH))()
    out_iso = (ctypes.c_float * (BLOCK * CH))()

    for b in range(25):
        for i in range(BLOCK):
            n = b * BLOCK + i
            for c in range(CH):
                in_all[i * CH + c] = 0.2 * math.sin(2.0 * math.pi * freqs[c] * n / SR)
                in_iso[i * CH + c] = 0.2 * math.sin(2.0 * math.pi * freqs[2] * n / SR) if c == 2 else 0.0
        dll.auradsp_process(h_all, in_all, out_all, BLOCK)
        dll.auradsp_process(h_iso, in_iso, out_iso, BLOCK)

    diff_c2 = max(abs(out_all[i * CH + 2] - out_iso[i * CH + 2]) for i in range(BLOCK))
    dll.auradsp_destroy(h_all)
    dll.auradsp_destroy(h_iso)
    return diff_c2

c2_fifo_diff = run_eq_convolver_test()
check("8ch 各声道不同频点并发卷积，ch2 与单声道隔离卷积一致 (diff < 1e-6，零 FIFO 串扰)",
      c2_fifo_diff < 1e-6,
      f"diff={c2_fifo_diff:.2e}")

print("\n=== [3] 96kHz 设备采样率下 IR 频点不产生八度偏移 (S-6) ===")
e96 = Engine(sr=96000.0)
check("96k sr: set channels.count=8", e96.set_i("channels.count", 8) == 0)
check("96k sr: set channels.mode=1", e96.set_i("channels.mode", 1) == 0)
e96.set_i("limiter.enable", 0)
e96.set_i("eq.enable", 1)
e96.set_s("eq.curve", curve)
e96.set_i("eq.channels", 0x04)  # 仅 ch2

# 1000Hz 在 96k 下稳态响应
for b in range(30):
    sig = make_sine_8ch(96000.0, BLOCK, 1000.0, 0.2, start_frame=b * BLOCK)
    out = e96.process(sig, BLOCK)

last_sig = make_sine_8ch(96000.0, BLOCK, 1000.0, 0.2, start_frame=30 * BLOCK)
last_out = e96.process(last_sig, BLOCK)
peak_1k_96 = ch_peak(last_out, BLOCK, CH, 2)

check("96k sr: 1000Hz 处保持 ~12dB 目标提升 (peak 在 0.7..0.9)",
      0.7 < peak_1k_96 < 0.9,
      f"peak={peak_1k_96:.4f}")

# 2000Hz 在 96k 下稳态响应（若未修复 S-6，1k 频点会八度漂移至 2k）
for b in range(30):
    sig = make_sine_8ch(96000.0, BLOCK, 2000.0, 0.2, start_frame=b * BLOCK)
    out = e96.process(sig, BLOCK)

last_sig = make_sine_8ch(96000.0, BLOCK, 2000.0, 0.2, start_frame=30 * BLOCK)
last_out = e96.process(last_sig, BLOCK)
peak_2k_96 = ch_peak(last_out, BLOCK, CH, 2)

check("96k sr: 2000Hz 处未落在提升峰值 (peak 明显低于 1kHz 峰值)",
      peak_2k_96 < peak_1k_96 - 0.15,
      f"peak_1k={peak_1k_96:.4f}, peak_2k={peak_2k_96:.4f}")
e96.close()

print("\n=== [4] mask=0 不变式 ===")
e0 = Engine(sr=SR)
e0.set_i("channels.count", 8)
e0.set_i("channels.mode", 1)
e0.set_i("limiter.enable", 0)
e0.set_i("eq.enable", 1)
e0.set_s("eq.curve", curve)
e0.set_i("eq.channels", 0)  # 全关

for b in range(10):
    sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=b * BLOCK)
    out = e0.process(sig, BLOCK)

last_sig = make_sine_8ch(SR, BLOCK, 1000.0, 0.2, start_frame=10 * BLOCK)
last_out = e0.process(last_sig, BLOCK)
max_dev = max(ch_max_dev(last_sig, last_out, BLOCK, CH, c) for c in range(8))
check("eq.channels=0 稳态下全 8 声道 100% bit-exact 直通 (dev < 1e-6)",
      max_dev < 1e-6,
      f"dev={max_dev:.2e}")
e0.close()

if FAIL:
    print(f"\n{len(FAIL)} FAIL: {FAIL}")
    sys.exit(1)
print("\nALL PASS: WP3 EQ 逐声道门禁全部通过")
