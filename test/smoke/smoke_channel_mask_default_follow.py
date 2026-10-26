#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_channel_mask_default_follow.py — X-6 修复（2026-10-26）门禁。

背景：dyneq/exciter 的 no-LFE 默认掩码 0xF7 是 8ch 位定义（bit3=LFE），
而 4ch Quad 布局 FL(0)/FR(1)/BL(2)/BR(3) 下 bit3=BR，默认会跳过 BR。

修复：set_channels_count 仅当掩码仍等于旧布局的 no-LFE 默认值时，按
ch_mask_no_lfe_for 平移为新布局默认；用户自定义掩码原样保留。

验证点：
  [1] 初始默认契约：fresh engine（2ch）dyneq/exciter.channels == 0xF7。
  [2] 平移链路：2→4 (0x0F) → 6 (0x37) → 8 (0xF7) → 2 (0xF7) → 4 (0x0F)。
  [3] 用户自定义掩码不被平移：0x03 / 0x30 在 2→4→6→8→2→4 全程保持；
      4ch 下显式写回 0xF7（自定义：仅排除 BR）切 2ch 也原样保留。
  [4] 4ch 音频级（dyneq）：默认掩码（平移后 0x0F）下 Mid 静态 +6dB，
      FL/FR/BL/BR 四声道基频一致 ≈ x2；显式 0xF7 时 BR 直通（旧位语义）。
  [5] 4ch 音频级（exciter）：默认掩码下 BR 与 FL/FR/BL 一致产生谐波处理；
      显式 0xF7 时 BR bit-exact 直通。
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

    def run_sine_mc(self, freq, amp, ch, blocks=40, keep=8):
        """多声道同相信号流；返回 keep 块内各声道样本列表。"""
        n0 = 0
        outs = []
        for b in range(blocks):
            src = (ctypes.c_float * (BLOCK * ch))()
            for i in range(BLOCK):
                s = amp * math.sin(2 * math.pi * freq * (n0 + i) / SR)
                for c in range(ch):
                    src[i * ch + c] = s
            dst = (ctypes.c_float * (BLOCK * ch))()
            dll.auradsp_process(self.h, src, dst, BLOCK)
            n0 += BLOCK
            if b >= blocks - keep:
                outs.append(list(dst))
        return outs


def gz(ys, f):
    n = len(ys)
    w = 2 * math.pi * f / SR
    cw, sw = math.cos(w), math.sin(w)
    s0 = s1 = s2 = 0.0
    for y in ys:
        s0 = y + 2 * cw * s1 - s2
        s2 = s1
        s1 = s0
    return ((cw * s1 - s2) ** 2 + (sw * s1) ** 2) / (n * n)


def fund(ys, f):
    return math.sqrt(gz(ys, f)) * 2


# ---------------------------------------------------------------- [1] 初始默认契约
print("=== [1] fresh engine 初始默认契约 ===")
e = Engine()
check("channels.count 默认 2", e.get_i("channels.count") == (0, 2))
check("dyneq.channels 默认 0xF7", e.get_i("dyneq.channels") == (0, 0xF7),
      "got 0x%02X" % e.get_i("dyneq.channels")[1])
check("exciter.channels 默认 0xF7", e.get_i("exciter.channels") == (0, 0xF7),
      "got 0x%02X" % e.get_i("exciter.channels")[1])
check("dyneq.channel_mask 别名共享 0xF7",
      e.get_i("dyneq.channel_mask") == (0, 0xF7))

# ---------------------------------------------------------------- [2] 平移链路
print("\n=== [2] 默认掩码随 channels.count 按布局平移 ===")
expected = {2: 0xF7, 4: 0x0F, 6: 0x37, 8: 0xF7}
for ch in (4, 6, 8, 2, 4):
    check("set channels.count=%d" % ch, e.set_i("channels.count", ch) == 0)
    rc_d, vd = e.get_i("dyneq.channels")
    rc_e, ve = e.get_i("exciter.channels")
    check("dyneq.channels -> 0x%02X (%dch)" % (expected[ch], ch),
          rc_d == 0 and vd == expected[ch], "got 0x%02X" % vd)
    check("exciter.channels -> 0x%02X (%dch)" % (expected[ch], ch),
          rc_e == 0 and ve == expected[ch], "got 0x%02X" % ve)
e.close()

# ---------------------------------------------------------------- [3] 自定义保留
print("\n=== [3] 用户自定义掩码不被平移 ===")
e = Engine()
check("dyneq.channels=0x03", e.set_i("dyneq.channels", 0x03) == 0)
check("exciter.channels=0x30", e.set_i("exciter.channels", 0x30) == 0)
for ch in (4, 6, 8, 2, 4):
    check("set channels.count=%d" % ch, e.set_i("channels.count", ch) == 0)
    check("dyneq.channels 保持 0x03 (%dch)" % ch,
          e.get_i("dyneq.channels") == (0, 0x03))
    check("exciter.channels 保持 0x30 (%dch)" % ch,
          e.get_i("exciter.channels") == (0, 0x30))
# 边界：4ch 下显式写回 0xF7（= 用户自定义"仅排除 BR"），切布局后保留
check("4ch 显式 dyneq.channels=0xF7", e.set_i("dyneq.channels", 0xF7) == 0)
check("set channels.count=2", e.set_i("channels.count", 2) == 0)
check("4ch 自定义 0xF7 切 2ch 保留", e.get_i("dyneq.channels") == (0, 0xF7))
e.close()

# ---------------------------------------------------------------- [4] 4ch dyneq 音频级
print("\n=== [4] 4ch dyneq 默认掩码处理 BR（Mid 静态 +6dB）===")


def dyneq_static_boost(mask=None):
    e = Engine()
    e.set_i("channels.count", 4)
    e.set_i("channels.mode", 1)
    e.set_i("limiter.enable", 0)
    e.set_i("dyneq.enable", 1)
    e.set_i("dyneq.mid.enable", 1)
    e.set_f("dyneq.mid.freq", 1000.0)
    e.set_f("dyneq.mid.q", 1.0)
    e.set_f("dyneq.mid.gain", 6.0)
    e.set_f("dyneq.mid.range", 0.0)
    if mask is not None:
        e.set_i("dyneq.channels", mask)
    outs = e.run_sine_mc(1000.0, 0.2, 4)
    e.close()
    return [fund([blk[i * 4 + c] for blk in outs for i in range(BLOCK)],
                 1000.0) for c in range(4)]


funds = dyneq_static_boost()  # 默认（平移后 0x0F）
for c, name in enumerate(("FL", "FR", "BL", "BR")):
    check("默认掩码 dyneq 处理 %s（基频 ≈0.4）" % name,
          abs(funds[c] - 0.4) < 0.02, "fund[%d]=%.4f" % (c, funds[c]))

funds_old = dyneq_static_boost(0xF7)  # 显式 0xF7 = 旧行为位语义
check("显式 0xF7: FL/FR/BL 仍被处理", all(
    abs(funds_old[c] - 0.4) < 0.02 for c in (0, 1, 2)),
    "funds=%s" % ["%.4f" % x for x in funds_old])
check("显式 0xF7: BR 直通（旧位语义保留）", abs(funds_old[3] - 0.2) < 0.01,
      "fund[3]=%.4f" % funds_old[3])

# ---------------------------------------------------------------- [5] 4ch exciter 音频级
print("\n=== [5] 4ch exciter 默认掩码处理 BR ===")


def exciter_diff(mask=None):
    e = Engine()
    e.set_i("channels.count", 4)
    e.set_i("channels.mode", 1)
    e.set_i("limiter.enable", 0)
    e.set_i("exciter.enable", 1)
    e.set_f("exciter.harmonics", 1.0)
    e.set_f("exciter.blend", 1.0)
    if mask is not None:
        e.set_i("exciter.channels", mask)
    # 稳态 16 块，取最后一块做逐声道 diff
    outs = e.run_sine_mc(1000.0, 0.4, 4, blocks=16, keep=1)
    e.close()
    F = BLOCK
    src_s = [0.4 * math.sin(2 * math.pi * 1000.0 * (15 * F + i) / SR)
             for i in range(F)]
    blk = outs[0]
    return [sum(abs(blk[i * 4 + c] - src_s[i]) for i in range(F)) / F
            for c in range(4)]


diffs = exciter_diff()  # 默认（平移后 0x0F）
check("默认掩码 exciter 四声道均有处理", all(d > 0.01 for d in diffs),
      "diffs=%s" % ["%.4f" % d for d in diffs])

diffs_old = exciter_diff(0xF7)
check("显式 0xF7: FL/FR/BL 仍有处理", all(
    diffs_old[c] > 0.01 for c in (0, 1, 2)),
    "diffs=%s" % ["%.4f" % d for d in diffs_old])
check("显式 0xF7: BR bit-exact 直通", diffs_old[3] < 1e-6,
      "diff[3]=%.2e" % diffs_old[3])

print()
if FAIL:
    print("CHANNEL MASK DEFAULT FOLLOW FAILURES:", FAIL)
    sys.exit(1)
print("channel mask default follow: all checks passed")
