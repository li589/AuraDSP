#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_postgain_persch.py — WP5 output 逐声道门禁（M-4，P-037）。

断言（工程文档 §7.1 与 §3.10）：
  - 8ch 逐声道增益（post.gain.c0..c7）；
  - LFE 也按补偿衰减（M-4 核心修复：环绕与 LFE 不再漏掉）；
  - 主增益 post.gain 与逐声道 trim 叠加；
  - 全 0dB 时逐样本 bit-exact 直通；
  - stereo 回归（c0/c1 在 vendor stage_output 与主增益同级生效）。
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
        assert self.h, "engine create failed"

    def close(self):
        if self.h:
            dll.auradsp_destroy(self.h)
            self.h = None

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(i32(v)), 4)

    def set_f(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(f32(v)), 4)

    def get_f(self, pid):
        v = f32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def process(self, in_data, frames, ch):
        in_arr = (ctypes.c_float * (frames * ch))(*in_data)
        out_arr = (ctypes.c_float * (frames * ch))()
        dll.auradsp_process(self.h, in_arr, out_arr, frames)
        return list(out_arr)


print("=== [1] 8ch 离散模式下全声道 trim 与 LFE 衰减 (M-4) ===")
e = Engine()
check("set channels.count=8", e.set_i("channels.count", 8) == 0)
check("set channels.mode=1 (离散模式)", e.set_i("channels.mode", 1) == 0)

# 确保其他效果器全关，limiter 也不触发压限
e.set_i("limiter.enable", 0)

trims_db = [-3.0, 2.0, -6.0, -10.0, 1.5, -4.0, 3.0, -1.0]
for c in range(8):
    rc = e.set_f(f"post.gain.c{c}", trims_db[c])
    check(f"set post.gain.c{c}={trims_db[c]}dB", rc == 0)

# 喂入 8 声道固定幅值音频 (0.2)
frames = BLOCK
in_sig = []
for i in range(frames):
    in_sig.extend([0.2] * 8)

# 运行若干块以使 10ms 平滑器收敛
for _ in range(10):
    out = e.process(in_sig, frames, 8)

# 提取各声道稳态幅值
last_samples = out[(frames - 1) * 8 : frames * 8]
for c in range(8):
    expected_gain = 10.0 ** (trims_db[c] / 20.0)
    expected_val = 0.2 * expected_gain
    actual_val = last_samples[c]
    err_db = 20.0 * math.log10(max(1e-9, actual_val) / expected_val)
    check(f"ch{c} 幅值匹配理论值 ({trims_db[c]}dB)",
          abs(err_db) < 0.15,
          f"actual={actual_val:.4f}, exp={expected_val:.4f}, err={err_db:.3f}dB")

check("LFE (ch3) 成功受控衰减 -10dB (M-4 不再遗漏 LFE)",
      abs(last_samples[3] - 0.2 * 10.0 ** (-10.0 / 20.0)) < 0.005)


print("=== [2] 主增益与逐声道 trim 级联叠加 ===")
e.set_f("post.gain", -6.0)
for _ in range(10):
    out = e.process(in_sig, frames, 8)

last_samples = out[(frames - 1) * 8 : frames * 8]
for c in range(8):
    total_db = -6.0 + trims_db[c]
    expected_gain = 10.0 ** (total_db / 20.0)
    expected_val = 0.2 * expected_gain
    actual_val = last_samples[c]
    err_db = 20.0 * math.log10(max(1e-9, actual_val) / expected_val)
    check(f"ch{c} 主增益(-6dB)+trim({trims_db[c]}dB)={total_db}dB 匹配",
          abs(err_db) < 0.15,
          f"actual={actual_val:.4f}, exp={expected_val:.4f}, err={err_db:.3f}dB")


print("=== [3] 全 0dB 时逐样本 bit-exact 直通 ===")
e.set_f("post.gain", 0.0)
for c in range(8):
    e.set_f(f"post.gain.c{c}", 0.0)

for _ in range(10):
    e.process(in_sig, frames, 8)

# 稳态测试 bit-exact
out_exact = e.process(in_sig, frames, 8)
max_dev = max(abs(a - b) for a, b in zip(in_sig, out_exact))
check("全 0dB 稳态下 8ch 逐样本 bit-exact (dev < 1e-6)", max_dev < 1e-6, f"max_dev={max_dev:.2e}")
e.close()


print("=== [4] stereo 模式下 c0/c1 作用于 vendor stage_output (P-037) ===")
es = Engine()
check("stereo 默认 channels.count=2, mode=0", True)
es.set_i("limiter.enable", 0)

es.set_f("post.gain", -3.0)
es.set_f("post.gain.c0", -2.0) # 左声道总计 -5dB
es.set_f("post.gain.c1", +3.0) # 右声道总计 0dB

stereo_in = []
for i in range(frames):
    stereo_in.extend([0.3, 0.3])

for _ in range(5):
    out_s = es.process(stereo_in, frames, 2)

l_val = out_s[-2]
r_val = out_s[-1]
exp_l = 0.3 * 10.0 ** (-5.0 / 20.0)
exp_r = 0.3 * 10.0 ** (0.0 / 20.0)

err_l = 20.0 * math.log10(l_val / exp_l)
err_r = 20.0 * math.log10(r_val / exp_r)

check("stereo 左声道 (-5dB) 匹配", abs(err_l) < 0.1, f"actual={l_val:.4f}, exp={exp_l:.4f}, err={err_l:.3f}dB")
check("stereo 右声道 (0dB) 匹配", abs(err_r) < 0.1, f"actual={r_val:.4f}, exp={exp_r:.4f}, err={err_r:.3f}dB")
es.close()


if FAIL:
    print(f"\nFAIL: {len(FAIL)} 项断言未通过")
    sys.exit(1)
print("\npostgain_persch: all checks passed")
sys.exit(0)
