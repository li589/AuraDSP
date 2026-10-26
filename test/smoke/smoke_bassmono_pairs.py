#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_bassmono_pairs.py — WP4 BassMono 多声道声道对选择与合并模式门禁。

验证点（工程文档 §3.9.1 / §3.9.2）：
  1. 参数范围校验：bassmono.pairs 仅受 0..15（4-bit 掩码），bassmono.merge 仅受 0..1；
  2. 8ch 独立按对 (merge=0)：未选声道对逐样本 bit-exact 直通（< 1e-6）；选中对低频单声道化；
  3. 8ch 全局合并 (merge=1)：所有选中声道全局平均，低频收敛为同一信号；未选声道 bit-exact 直通；
  4. pairs=0 时全声道 bit-exact 直通；
  5. 4ch Quad 布局：忽略不存在的对（C/LFE, SL/SR）；正确将 BL/BR 映射到物理声道 2/3；
  6. 2ch 模式：仅 bit 0 (FL/FR) 生效；未选 bit 0 时立体声 bit-exact 直通；
  7. 动态平滑：切换 pairs/merge 触发 bm_reinit 首块无爆音；声道切换清零状态。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 128
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
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
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

    def process(self, in_data, frames, ch):
        in_arr = (ctypes.c_float * (frames * ch))(*in_data)
        out_arr = (ctypes.c_float * (frames * ch))()
        dll.auradsp_process(self.h, in_arr, out_arr, frames)
        return list(out_arr)


print("=== [1] 参数范围校验与越界拒绝 ===")
e = Engine()
check("pairs=16 拒绝", e.set_i("bassmono.pairs", 16) != 0)
check("pairs=-1 拒绝", e.set_i("bassmono.pairs", -1) != 0)
check("merge=2 拒绝", e.set_i("bassmono.merge", 2) != 0)
check("merge=-1 拒绝", e.set_i("bassmono.merge", -1) != 0)
check("pairs=0 接受", e.set_i("bassmono.pairs", 0) == 0)
check("pairs=15 接受", e.set_i("bassmono.pairs", 15) == 0)
check("merge=0 接受", e.set_i("bassmono.merge", 0) == 0)
check("merge=1 接受", e.set_i("bassmono.merge", 1) == 0)
e.close()

print("\n=== [2] 8ch 独立按对处理 (merge=0) 与未选对 bit-exact 直通 ===")
e = Engine()
e.set_i("channels.count", 8)
e.set_i("channels.mode", 1)
e.set_i("limiter.enable", 0)
e.set_i("bassmono.enable", 1)
e.set_f("bassmono.freq", 300.0)  # 300Hz 截止频率
e.set_i("bassmono.merge", 0)

# 选择 Pair 0 (FL/FR: 0,1) 与 Pair 2 (SL/SR: 4,5)；未选 Pair 1 (C/LFE: 2,3) 与 Pair 3 (BL/BR: 6,7)
check("set bassmono.pairs=0x05", e.set_i("bassmono.pairs", 0x05) == 0)

frames = BLOCK
w = 2.0 * math.pi * 5.0 / SR  # 5Hz 深低频连续波形

last_in = None
last_out = None

# 连续流式喂入 60 个块，让 5Hz 经过数个完整周期并达到一阶滤波器稳态
for b in range(60):
    in_buf = []
    for i in range(frames):
        t = float(b * frames + i)
        s0 = 0.5 * math.sin(w * t)
        s1 = 0.5 * math.cos(w * t)
        s2 = 0.3 * math.sin(w * t * 1.5)
        s3 = 0.4 * math.cos(w * t * 2.0)
        s4 = 0.6 * math.sin(w * t)
        s5 = -0.6 * math.sin(w * t)
        s6 = 0.25 * math.sin(w * t * 0.7)
        s7 = 0.35 * math.cos(w * t * 0.9)
        in_buf.extend([s0, s1, s2, s3, s4, s5, s6, s7])
    last_in = in_buf
    last_out = e.process(in_buf, frames, 8)

# 校验未选中的对 (Pair 1: ch2, ch3 和 Pair 3: ch6, ch7) 是否 bit-exact 直通 (< 1e-6 float32 精度)
p1_diff = max(abs(last_out[i * 8 + 2] - last_in[i * 8 + 2]) for i in range(frames))
p1_diff_sub = max(abs(last_out[i * 8 + 3] - last_in[i * 8 + 3]) for i in range(frames))
p3_diff_l = max(abs(last_out[i * 8 + 6] - last_in[i * 8 + 6]) for i in range(frames))
p3_diff_r = max(abs(last_out[i * 8 + 7] - last_in[i * 8 + 7]) for i in range(frames))
check("未选对 Pair 1 (C/LFE) bit-exact 直通", p1_diff < 1e-6 and p1_diff_sub < 1e-6,
      f"diff: {p1_diff}, {p1_diff_sub}")
check("未选对 Pair 3 (BL/BR) bit-exact 直通", p3_diff_l < 1e-6 and p3_diff_r < 1e-6,
      f"diff: {p3_diff_l}, {p3_diff_r}")

# 校验 Pair 2 (反相) 输出是否收敛到近零 (< 0.02，相对输入 0.6 衰减 >30dB)
sl_max = max(abs(last_out[i * 8 + 4]) for i in range(frames))
sr_max = max(abs(last_out[i * 8 + 5]) for i in range(frames))
check("Pair 2 (SL/SR 反相) 输出收敛到零 (< 0.02)", sl_max < 0.02 and sr_max < 0.02,
      f"max: {sl_max}, {sr_max}")

# 校验 Pair 0 (FL/FR)：单声道化后，低频差值 y0 - y1 应当大幅衰减 (< 0.02)
diff_01 = max(abs(last_out[i * 8 + 0] - last_out[i * 8 + 1]) for i in range(frames))
check("Pair 0 (FL/FR) 低频收敛到单声道 (差值 < 0.02)", diff_01 < 0.02,
      f"diff: {diff_01}")

# 校验 Pair 0 和保留特性：y0 + y1 恒等于 s0 + s1 (能量守恒)
sum_01_diff = max(abs((last_out[i * 8 + 0] + last_out[i * 8 + 1]) - (last_in[i * 8 + 0] + last_in[i * 8 + 1])) for i in range(frames))
check("Pair 0 (FL/FR) 和信号能量精确守恒 (差值 < 1e-5)", sum_01_diff < 1e-5, f"diff: {sum_01_diff}")
e.close()

print("\n=== [3] 8ch 全局合并 (merge=1) ===")
e = Engine()
e.set_i("channels.count", 8)
e.set_i("channels.mode", 1)
e.set_i("limiter.enable", 0)
e.set_i("bassmono.enable", 1)
e.set_f("bassmono.freq", 300.0)
e.set_i("bassmono.merge", 1)
# 选择 Pair 0 (0,1) 与 Pair 3 (6,7)，共 4 个声道参与全局平均
e.set_i("bassmono.pairs", 0x09)

for b in range(60):
    in_buf = []
    for i in range(frames):
        t = float(b * frames + i)
        s0 = 0.5 * math.sin(w * t)
        s1 = 0.3 * math.cos(w * t)
        s2 = 0.7  # 未选
        s3 = 0.8  # 未选
        s4 = 0.9  # 未选
        s5 = 0.1  # 未选
        s6 = 0.4 * math.sin(w * t + 1.0)
        s7 = 0.2 * math.cos(w * t + 2.0)
        in_buf.extend([s0, s1, s2, s3, s4, s5, s6, s7])
    last_in = in_buf
    last_out = e.process(in_buf, frames, 8)

# 稳态下，4 个选中声道的输出低频全部被替换为同一个全局平均
diff_0_1 = max(abs(last_out[i * 8 + 0] - last_out[i * 8 + 1]) for i in range(frames))
diff_0_6 = max(abs(last_out[i * 8 + 0] - last_out[i * 8 + 6]) for i in range(frames))
diff_0_7 = max(abs(last_out[i * 8 + 0] - last_out[i * 8 + 7]) for i in range(frames))
check("merge=1 时所有选中声道 (FL/FR/BL/BR) 低频收敛到同一信号 (差值 < 0.02)",
      diff_0_1 < 0.02 and diff_0_6 < 0.02 and diff_0_7 < 0.02,
      f"diff: {diff_0_1}, {diff_0_6}, {diff_0_7}")

# 未选声道 (ch 2..5) 必须 bit-exact 直通
unsel_diff = max(max(abs(last_out[i * 8 + c] - last_in[i * 8 + c]) for c in range(2, 6))
                 for i in range(frames))
check("merge=1 时未选声道 bit-exact 直通", unsel_diff < 1e-6, f"diff: {unsel_diff}")
e.close()

print("\n=== [4] pairs=0 全声道 bit-exact 直通 ===")
e = Engine()
e.set_i("channels.count", 8)
e.set_i("channels.mode", 1)
e.set_i("limiter.enable", 0)
e.set_i("bassmono.enable", 1)
e.set_i("bassmono.pairs", 0)
test_sig = [0.1 * (i % 7) for i in range(frames * 8)]
out = e.process(test_sig, frames, 8)
max_d = max(abs(out[i] - test_sig[i]) for i in range(len(test_sig)))
check("pairs=0 时全声道 bit-exact 直通", max_d < 1e-6, f"max_d: {max_d}")
e.close()

print("\n=== [5] 4ch Quad 布局：忽略不存在的对，正确映射 BL/BR (物理声道 2/3) ===")
e = Engine()
e.set_i("channels.count", 4)
e.set_i("channels.mode", 1)
e.set_i("limiter.enable", 0)
e.set_i("bassmono.enable", 1)
e.set_f("bassmono.freq", 300.0)
e.set_i("bassmono.merge", 0)

# 4ch Quad: 0=FL, 1=FR, 2=BL, 3=BR
# 勾选 bit 1 (C/LFE) 与 bit 2 (SL/SR) —— 4ch 下不存在
e.set_i("bassmono.pairs", 0x06)
sig4 = [0.3, 0.4, 0.5, 0.6] * frames
out4 = e.process(sig4, frames, 4)
max_d4 = max(abs(out4[i] - sig4[i]) for i in range(len(sig4)))
check("4ch 下勾选不存在的对 (C/LFE, SL/SR) 时全通道直通", max_d4 < 1e-6, f"diff: {max_d4}")

# 勾选 bit 3 (BL/BR)
e.set_i("bassmono.pairs", 0x08)  # 仅选 BL/BR
for b in range(60):
    sig4_buf = []
    for i in range(frames):
        t = float(b * frames + i)
        sig4_buf.extend([
            0.5 * math.sin(w * t),         # FL: 不处理
            0.5 * math.cos(w * t),         # FR: 不处理
            0.6 * math.sin(w * t),         # BL: 处理 (反相)
            -0.6 * math.sin(w * t),        # BR: 处理 (反相)
        ])
    last_in4 = sig4_buf
    last_out4 = e.process(sig4_buf, frames, 4)

fl_diff = max(abs(last_out4[i * 4 + 0] - last_in4[i * 4 + 0]) for i in range(frames))
fr_diff = max(abs(last_out4[i * 4 + 1] - last_in4[i * 4 + 1]) for i in range(frames))
check("4ch 仅选 bit 3 时 FL/FR bit-exact 直通", fl_diff < 1e-6 and fr_diff < 1e-6)

bl_max = max(abs(last_out4[i * 4 + 2]) for i in range(frames))
br_max = max(abs(last_out4[i * 4 + 3]) for i in range(frames))
check("4ch bit 3 (BL/BR) 落在物理声道 2/3 且反相被消除 (< 0.02)", bl_max < 0.02 and br_max < 0.02,
      f"max: {bl_max}, {br_max}")
e.close()

print("\n=== [6] 2ch 仅 bit 0 有效 ===")
e = Engine()
e.set_i("channels.count", 2)
e.set_i("channels.mode", 0)
e.set_i("limiter.enable", 0)
e.set_i("bassmono.enable", 1)
e.set_f("bassmono.freq", 300.0)

# bit 0 未选 (仅选 bit 1..3) -> 直通
e.set_i("bassmono.pairs", 0x0E)
sig2 = [0.5 * math.sin(w * i) for i in range(frames * 2)]
out2 = e.process(sig2, frames, 2)
max_d2 = max(abs(out2[i] - sig2[i]) for i in range(len(sig2)))
check("2ch bit 0 未选时 bit-exact 直通", max_d2 < 1e-6, f"diff: {max_d2}")

# bit 0 选中 -> 反相被抵消
e.set_i("bassmono.pairs", 0x01)
for b in range(60):
    sig2_buf = []
    for i in range(frames):
        t = float(b * frames + i)
        sig2_buf.extend([0.6 * math.sin(w * t), -0.6 * math.sin(w * t)])
    out2 = e.process(sig2_buf, frames, 2)
out2_max = max(abs(out2[i]) for i in range(len(out2)))
check("2ch bit 0 选中时反相低频被抵消 (< 0.02)", out2_max < 0.02, f"max: {out2_max}")
e.close()

print("\n=== [7] 动态切换瞬态平滑 (bm_reinit) 与声道切换清零 ===")
e = Engine()
e.set_i("channels.count", 8)
e.set_i("channels.mode", 1)
e.set_i("limiter.enable", 0)
e.set_i("bassmono.enable", 1)
e.set_f("bassmono.freq", 120.0)
e.set_i("bassmono.pairs", 0x01)

test_buf = [0.5] * (frames * 8)
# 运行若干块稳定
for _ in range(5):
    e.process(test_buf, frames, 8)

# 动态切换 pairs 到 0x0F
e.set_i("bassmono.pairs", 0x0F)
out_first = e.process(test_buf, frames, 8)

# 检查首块未出现超过 1.5 的瞬态跳变
max_jump = max(abs(out_first[i]) for i in range(len(out_first)))
check("动态切换 pairs 时首块无大跳变 (< 1.5)", max_jump < 1.5, f"max_jump: {max_jump}")

# 8 -> 2 -> 8 切换测试
e.set_i("channels.count", 2)
e.set_i("channels.count", 8)
# 立即喂入静音块
silence = [0.0] * (frames * 8)
out_silence = e.process(silence, frames, 8)
silence_max = max(abs(s) for s in out_silence)
check("8->2->8 切换后首块无残留历史尾音 (< 1e-6)", silence_max < 1e-6, f"max: {silence_max}")
e.close()

if FAIL:
    print(f"\nFAILED ({len(FAIL)} failures): {FAIL}")
    sys.exit(1)
else:
    print("\nALL PASS")
    sys.exit(0)
