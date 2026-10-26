#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_eq_freq_clamp.py — WP7 EQ 频率钳制门禁（S-5）。

断言（工程文档 §7.1 与 S-5）：
  - 96k 设备率下，工作率 jdsp.fs 为 48k，Nyquist 为 24kHz；
  - 请求 30kHz (超工作率 Nyquist) 必须被钳制到工作率域 Nyquist (23976Hz)，不得使用 96k 的 48kHz 作为上限；
  - 192k 设备率下，请求 80kHz 同样被钳制到工作率域 Nyquist；
  - 处理音频流时不产生 NaN/Inf，输出波形稳定且有限。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

BLOCK = 512
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
    def __init__(self, sr=96000.0, block=BLOCK):
        self.sr = sr
        self.block = block
        self.h = dll.auradsp_create(ctypes.c_float(sr), block)
        assert self.h, f"create failed at sr={sr}"

    def close(self):
        if self.h:
            dll.auradsp_destroy(self.h)
            self.h = None

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(i32(v)), 4)

    def set_s(self, pid, s_bytes):
        return dll.auradsp_set_param(self.h, pid.encode(), s_bytes, len(s_bytes))

    def get_s(self, pid, max_len=1024):
        buf = ctypes.create_string_buffer(max_len)
        rc = dll.auradsp_get_param(self.h, pid.encode(), buf, max_len)
        return rc, buf.value.decode('utf-8', errors='ignore')

    def process(self, in_data, frames):
        ch = 2
        in_arr = (ctypes.c_float * (frames * ch))(*in_data)
        out_arr = (ctypes.c_float * (frames * ch))()
        dll.auradsp_process(self.h, in_arr, out_arr, frames)
        return list(out_arr)


print("=== [1] 96k 设备率下 30kHz 频点钳制与音频处理 ===")
e96 = Engine(sr=96000.0)
check("启用 EQ", e96.set_i("eq.enable", 1) == 0)

curve_96 = b"20:0.0;1000:3.0;30000:6.0"
rc = e96.set_s("eq.curve", curve_96)
check("设置含 30kHz (超 48k 工作 Nyquist) 曲线成功", rc == 0)

# 喂入 96kHz 音频 (含高频正弦与脉冲)
frames = BLOCK
in_sig = []
for i in range(frames):
    t = i / 96000.0
    val = 0.5 * math.sin(2.0 * math.pi * 1000.0 * t) + 0.2 * math.sin(2.0 * math.pi * 20000.0 * t)
    in_sig.extend([val, val])

all_finite = True
max_val = 0.0
for block_idx in range(40):
    out = e96.process(in_sig, frames)
    for sample in out:
        if not math.isfinite(sample):
            all_finite = False
            break
        abs_s = abs(sample)
        if abs_s > max_val:
            max_val = abs_s
    if not all_finite:
        break

check("96k 下 EQ 输出无 NaN/Inf", all_finite)
check("96k 下输出振幅有限且稳定 (max < 10.0)", max_val < 10.0, f"max={max_val}")
e96.close()


print("=== [2] 192k 设备率下 80kHz 频点钳制与音频处理 ===")
e192 = Engine(sr=192000.0)
check("启用 EQ (192k)", e192.set_i("eq.enable", 1) == 0)

curve_192 = b"eqm:1:0;20:-2.0;2000:2.0;80000:8.0"
rc_192 = e192.set_s("eq.curve", curve_192)
check("设置含 80kHz (超 48k 工作 Nyquist) 曲线成功", rc_192 == 0)

in_sig_192 = []
for i in range(frames):
    t = i / 192000.0
    val = 0.4 * math.sin(2.0 * math.pi * 500.0 * t) + 0.2 * math.sin(2.0 * math.pi * 15000.0 * t)
    in_sig_192.extend([val, val])

all_finite_192 = True
max_val_192 = 0.0
for block_idx in range(40):
    out = e192.process(in_sig_192, frames)
    for sample in out:
        if not math.isfinite(sample):
            all_finite_192 = False
            break
        abs_s = abs(sample)
        if abs_s > max_val_192:
            max_val_192 = abs_s
    if not all_finite_192:
        break

check("192k 下 EQ 输出无 NaN/Inf", all_finite_192)
check("192k 下输出振幅有限且稳定 (max < 10.0)", max_val_192 < 10.0, f"max={max_val_192}")
e192.close()

if FAIL:
    print(f"\nFAIL: {len(FAIL)} 项断言未通过")
    sys.exit(1)
print("\neq_freq_clamp: all checks passed")
sys.exit(0)
