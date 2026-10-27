#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_mc_comp_persch.py — WP3 comp 逐声道门禁（P-034）。

断言（工程文档 §7.1 与 §3.4）：
  - 8ch 离散模式下每声道独立压缩；
  - C/LFE 彻底解绑不联动；
  - FL/FR 单声道可选；
  - mask 可单声道独立选中，未选声道 100% bit-exact 直通；
  - 无跨声道状态串扰（热信号声道的深压缩不波及同选但冷信号的邻近声道，逐位一致）；
  - comp.mode=1 性能模式回退：半选对完全不压缩（全直通），全选对按对处理；
  - 运行中切 mode 无崩溃、无 NaN/Inf。
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
        assert self.h, "engine create failed"

    def close(self):
        if self.h:
            dll.auradsp_destroy(self.h)
            self.h = None

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(i32(v)), 4)

    def set_f(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(f32(v)), 4)

    def get_i(self, pid):
        v = i32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def get_f(self, pid):
        v = f32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def process(self, in_data, frames, ch=CH):
        in_arr = (ctypes.c_float * (frames * ch))(*in_data)
        out_arr = (ctypes.c_float * (frames * ch))()
        dll.auradsp_process(self.h, in_arr, out_arr, frames)
        return list(out_arr)


def make_dynamic_signal(block_idx, frames=BLOCK, ch=CH):
    buf = []
    for i in range(frames):
        n = block_idx * frames + i
        s = 0.5 * ((n * 7) % 97 - 48) / 48.0
        buf.extend([s] * ch)
    return buf


def ch_avg_dev(src, dst, frames, ch, target_c):
    return sum(abs(dst[i * ch + target_c] - src[i * ch + target_c]) for i in range(frames)) / float(frames)


def ch_max_dev(src, dst, frames, ch, target_c):
    m = 0.0
    for i in range(frames):
        d = abs(dst[i * ch + target_c] - src[i * ch + target_c])
        if d > m:
            m = d
    return m


print("=== [1] 8ch 离散模式下 Mode 0 (逐声道独立压缩) 基础 ===")
e = Engine()
check("set channels.count=8", e.set_i("channels.count", 8) == 0)
check("set channels.mode=1 (离散模式)", e.set_i("channels.mode", 1) == 0)
check("默认 comp.mode == 0", e.get_i("comp.mode") == (0, 0))

# 禁用 limiter 避免干扰，启用 comp
e.set_i("limiter.enable", 0)
e.set_i("comp.enable", 1)

print("\n=== [2] 单声道掩码隔离与 C/LFE 解绑 (Mode 0) ===")
# 1) 仅选择 C 声道 (ch2, bit 2 = 0x04)
e.set_i("comp.channels", 0x04)

for b in range(10):
    sig = make_dynamic_signal(b)
    last_out = e.process(sig, BLOCK)
    last_sig = sig

c2_diff = ch_avg_dev(last_sig, last_out, BLOCK, CH, 2)
check("mask=0x04: C 声道 (ch2) 压缩处理生效 (diff > 0.05)", c2_diff > 0.05, f"diff={c2_diff:.4f}")

# 其余 7 个声道必须 100% 直通 (max_dev < 1e-6)
for c in [0, 1, 3, 4, 5, 6, 7]:
    dev = ch_max_dev(last_sig, last_out, BLOCK, CH, c)
    check(f"mask=0x04: ch{c} 未选声道 100% 直通", dev < 1e-6, f"dev={dev:.2e}")

# 2) 仅选择 LFE 声道 (ch3, bit 3 = 0x08)
e.set_i("comp.channels", 0x08)
for b in range(10):
    sig = make_dynamic_signal(b)
    last_out = e.process(sig, BLOCK)
    last_sig = sig

c3_diff = ch_avg_dev(last_sig, last_out, BLOCK, CH, 3)
check("mask=0x08: LFE 声道 (ch3) 压缩生效 (diff > 0.05)", c3_diff > 0.05, f"diff={c3_diff:.4f}")
c2_dev = ch_max_dev(last_sig, last_out, BLOCK, CH, 2)
check("mask=0x08: C 声道 (ch2) 100% 直通 (C/LFE 彻底解绑)", c2_dev < 1e-6, f"dev={c2_dev:.2e}")

# 3) 仅选择 FL 声道 (ch0, bit 0 = 0x01)
e.set_i("comp.channels", 0x01)
for b in range(10):
    sig = make_dynamic_signal(b)
    last_out = e.process(sig, BLOCK)
    last_sig = sig

c0_diff = ch_avg_dev(last_sig, last_out, BLOCK, CH, 0)
c1_dev = ch_max_dev(last_sig, last_out, BLOCK, CH, 1)
check("mask=0x01: FL (ch0) 压缩生效", c0_diff > 0.05, f"diff={c0_diff:.4f}")
check("mask=0x01: FR (ch1) 100% 直通 (FL/FR 彻底解绑)", c1_dev < 1e-6, f"dev={c1_dev:.2e}")

print("\n=== [3] 无跨声道状态串扰 (Mode 0) ===")
# 验证：ch0 与 ch1 同时使能 (mask=0x03)
# ch1 喂入确定性小信号，测量 ch0 处于不同信号（静音 vs 强动态）时 ch1 的稳态输出是否完全一致
def run_c1_probe(ch0_hot):
    h = dll.auradsp_create(ctypes.c_float(SR), BLOCK)
    dll.auradsp_set_param(h, b"channels.count", ctypes.byref(i32(8)), 4)
    dll.auradsp_set_param(h, b"channels.mode", ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h, b"limiter.enable", ctypes.byref(i32(0)), 4)
    dll.auradsp_set_param(h, b"comp.enable", ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h, b"comp.channels", ctypes.byref(i32(0x03)), 4)
    in_arr = (ctypes.c_float * (BLOCK * CH))()
    out_arr = (ctypes.c_float * (BLOCK * CH))()
    for b in range(12):
        for i in range(BLOCK):
            n = b * BLOCK + i
            in_arr[i * CH + 0] = 0.5 * ((n * 7) % 97 - 48) / 48.0 if ch0_hot else 0.0
            in_arr[i * CH + 1] = 0.02 * math.sin(2.0 * math.pi * 440.0 * n / SR)
            for c in range(2, CH):
                in_arr[i * CH + c] = 0.0
        dll.auradsp_process(h, in_arr, out_arr, BLOCK)
    res = [out_arr[i * CH + 1] for i in range(BLOCK)]
    dll.auradsp_destroy(h)
    return res

c1_isolated = run_c1_probe(ch0_hot=False)
c1_with_hot_c0 = run_c1_probe(ch0_hot=True)
max_crosstalk_dev = max(abs(a - b) for a, b in zip(c1_isolated, c1_with_hot_c0))
check("ch0 强信号与静音时 ch1 输出逐位一致 (max_dev < 1e-6，零跨声道状态串扰)",
      max_crosstalk_dev < 1e-6,
      f"max_dev={max_crosstalk_dev:.2e}")

print("\n=== [4] Mode 1 (逐对性能模式回退) 语义 ===")
check("切换 comp.mode=1", e.set_i("comp.mode", 1) == 0)

# 测试半选对：设置 comp.channels=0x04 (仅 ch2，ch3 未选)
# 在 Mode 1 下，pair 1 (ch2, ch3) 属于半选对，必须完全跳过（全直通）
e.set_i("comp.channels", 0x04)
for b in range(10):
    sig = make_dynamic_signal(b)
    last_out = e.process(sig, BLOCK)
    last_sig = sig

for c in range(8):
    dev = ch_max_dev(last_sig, last_out, BLOCK, CH, c)
    check(f"Mode 1 半选对 (mask=0x04): ch{c} 100% 直通", dev < 1e-6, f"dev={dev:.2e}")

# 测试全选对：设置 comp.channels=0x0C (ch2 与 ch3 均选中：pair 1)
e.set_i("comp.channels", 0x0C)
for b in range(10):
    sig = make_dynamic_signal(b)
    last_out = e.process(sig, BLOCK)
    last_sig = sig

p1_c2_diff = ch_avg_dev(last_sig, last_out, BLOCK, CH, 2)
p1_c3_diff = ch_avg_dev(last_sig, last_out, BLOCK, CH, 3)
check("Mode 1 全选对 (mask=0x0C): ch2 压缩生效", p1_c2_diff > 0.05, f"diff={p1_c2_diff:.4f}")
check("Mode 1 全选对 (mask=0x0C): ch3 压缩生效", p1_c3_diff > 0.05, f"diff={p1_c3_diff:.4f}")

# 其余声道直通
for c in [0, 1, 4, 5, 6, 7]:
    dev = ch_max_dev(last_sig, last_out, BLOCK, CH, c)
    check(f"Mode 1 全选对 (mask=0x0C): ch{c} 直通", dev < 1e-6, f"dev={dev:.2e}")

print("\n=== [5] mask=0 不变式与动态切换安全 ===")
e.set_i("comp.mode", 0)
e.set_i("comp.channels", 0)
for b in range(10):
    sig = make_dynamic_signal(b)
    last_out = e.process(sig, BLOCK)
    last_sig = sig

max_dev = max(ch_max_dev(last_sig, last_out, BLOCK, CH, c) for c in range(8))
check("mask=0 稳态下 8ch 逐样本 bit-exact (dev < 1e-6)", max_dev < 1e-6, f"max_dev={max_dev:.2e}")

# 动态切 mode 压力
e.set_i("comp.channels", 0xFF)
all_finite = True
for b in range(30):
    e.set_i("comp.mode", b % 2)
    sig = make_dynamic_signal(b)
    out = e.process(sig, BLOCK)
    for sample in out:
        if not math.isfinite(sample):
            all_finite = False
            break

check("连续动态切换 comp.mode 输出无 NaN/Inf", all_finite)
e.close()

if FAIL:
    print(f"\n{len(FAIL)} FAIL: {FAIL}")
    sys.exit(1)
print("\nALL PASS: WP3 Compressor 逐声道门禁全部通过")
