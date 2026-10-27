#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_mc_reverb.py — WP1 离散多声道 FDN 混响验收。

覆盖工程文档 §3.3/§3.4：
  1. 8ch N 进 N 出尾音存在，且左右/环绕具有去相关（不是简单复制）。
  2. LFE 默认直通：不进入 FDN、不产生湿声；其它声道也不会从 LFE 漏音。
  3. reverb.lfe=1：LFE 经 120Hz 低通 + -6dB 入 FDN，湿声回加前再低通。
  4. curated / 自定义预设、predelay / lfe 运行中切换：无 NaN、无爆炸。
  5. reverb.outgain 对 MC 路径真实生效（+6dB ≈ 2x）。
  6. 4ch Quad 拓扑可运行，四声道均有尾音。

只验证 MC FDN。vendor 立体声路径见 smoke_reverb.py；两套引擎互斥见
smoke_reverb_boundary.py。
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
    def __init__(self):
        self.h = dll.auradsp_create(SR, BLOCK)
        assert self.h, "auradsp_create failed"

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

    def process(self, buf):
        out = (ctypes.c_float * len(buf))()
        dll.auradsp_process(self.h, buf, out, BLOCK)
        return out


OFF_LIST = [
    ("limiter.enable", 0), ("gate.enable", 0), ("filter.enable", 0),
    ("shelf.enable", 0), ("dyneq.enable", 0), ("tube.enable", 0),
    ("exciter.enable", 0), ("loudness.enable", 0), ("haas.enable", 0),
    ("spatial.enable", 0), ("spatial.binaural", 0),
    ("bassmono.enable", 0), ("bass.enable", 0),
    ("convolver.enable", 0), ("ddc.enable", 0), ("liveprog.enable", 0),
    ("arbmag.enable", 0), ("comp.enable", 0), ("eq.enable", 0),
    ("crossfeed.enable", 0),
]


def new_engine(ch=8, mode=1):
    e = Engine()
    for k, v in OFF_LIST:
        assert e.set_i(k, v) == 0, k
    assert e.set_i("channels.count", ch) == 0
    assert e.set_i("channels.mode", mode) == 0
    assert e.set_i("reverb.preset", -1) == 0
    return e


def set_custom_wet_only(e, decay=0.7, damp=0.5, room=1.2, width=1.0,
                        predelay=0.0, lfe=0):
    assert e.set_i("reverb.preset", -2) == 0
    assert e.set_f("freeverb.decay", decay) == 0
    assert e.set_f("freeverb.damp", damp) == 0
    assert e.set_f("freeverb.wet", 1.0) == 0
    assert e.set_f("freeverb.dry", 0.0) == 0
    assert e.set_f("freeverb.roomsize", room) == 0
    assert e.set_f("freeverb.width", width) == 0
    assert e.set_f("reverb.predelay", predelay) == 0
    assert e.set_i("reverb.lfe", lfe) == 0


def run_blocks(e, ch, blocks, fill, on_block=None):
    outs = []
    for b in range(blocks):
        inb = (ctypes.c_float * (BLOCK * ch))()
        fill(inb, b)
        if on_block is not None:
            on_block(e, b)
        out = e.process(inb)
        outs.append([out[i] for i in range(BLOCK * ch)])
    return outs


def chan(blocks, ch, c):
    return [blk[i * ch + c] for blk in blocks for i in range(BLOCK)]


def rms(xs):
    return math.sqrt(sum(x * x for x in xs) / len(xs)) if xs else 0.0


def peak(xs):
    return max(abs(x) for x in xs) if xs else 0.0


def corr(a, b):
    n = len(a)
    ma = sum(a) / n
    mb = sum(b) / n
    va = sum((x - ma) ** 2 for x in a)
    vb = sum((x - mb) ** 2 for x in b)
    if va <= 0.0 or vb <= 0.0:
        return 0.0
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / math.sqrt(va * vb)


def impulse_fill(ch, imp_chs, amp=0.5):
    def fill(inb, b):
        if b == 2:
            for c in imp_chs:
                inb[c] = amp
    return fill


def tone_fill(ch, target_ch, freq, amp=0.3):
    def fill(inb, b):
        for i in range(BLOCK):
            t = (b * BLOCK + i) / SR
            inb[i * ch + target_ch] = amp * math.sin(2 * math.pi * freq * t)
    return fill


# ---------------------------------------------------------------------------
# 1. 8ch 尾音 + 去相关
# ---------------------------------------------------------------------------
print("=== [1] 8ch N 进 N 出 / 尾音去相关 ===")
e = new_engine(8)
set_custom_wet_only(e, lfe=0)
check("8ch custom MC path reports engine 1", e.get_i("reverb.engine") == (0, 1),
      str(e.get_i("reverb.engine")))
blocks = run_blocks(e, 8, 72, impulse_fill(8, [0, 1]))
chans = [chan(blocks, 8, c) for c in range(8)]
start = 2 * BLOCK + 100
end = 2 * BLOCK + 6000
tail = [c[start:end] for c in chans]
tail_rms = [rms(t) for t in tail]
check("FL/FR impulse produces FDN tail (wet-only)", tail_rms[0] > 1e-4,
      "rms=%.6f" % tail_rms[0])
for c in (0, 1, 2, 4, 5, 6, 7):
    check("ch%d has FDN tail" % c, tail_rms[c] > 1e-5,
          "rms=%.6g" % tail_rms[c])
check("LFE stays dry when reverb.lfe=0", peak(chans[3]) < 1e-9,
      "peak=%.3g" % peak(chans[3]))

c_fl_fr = corr(tail[0], tail[1])
c_fl_sl = corr(tail[0], tail[4])
c_fl_bl = corr(tail[0], tail[6])
c_sl_sr = corr(tail[4], tail[5])
print("      corr FL-FR=%.3f FL-SL=%.3f FL-BL=%.3f SL-SR=%.3f" %
      (c_fl_fr, c_fl_sl, c_fl_bl, c_sl_sr))
check("FL/FR correlated (same input, same near modes)", c_fl_fr > 0.5,
      "corr=%.3f" % c_fl_fr)
check("FL/SL decorrelated (FDN, not copy)", c_fl_sl < 0.3, "corr=%.3f" % c_fl_sl)
check("FL/BL decorrelated (FDN, not copy)", c_fl_bl < 0.2, "corr=%.3f" % c_fl_bl)
check("SL/SR correlated (same side pair)", c_sl_sr > 0.4, "corr=%.3f" % c_sl_sr)

# ---------------------------------------------------------------------------
# 2. LFE 默认直通（不进 FDN）
# ---------------------------------------------------------------------------
print("=== [2] LFE 默认直通 / 不漏入 FDN ===")
e2 = new_engine(8)
assert e2.set_i("reverb.preset", 5) == 0
assert e2.set_i("reverb.lfe", 0) == 0
blocks = run_blocks(e2, 8, 48, impulse_fill(8, [3]))
chans = [chan(blocks, 8, c) for c in range(8)]
idx = 2 * BLOCK
want = 0.5 / math.sqrt(1.0 + (0.45 * 0.7) ** 2)
check("LFE dry impulse passes at original time",
      abs(chans[3][idx] - want) < 5e-3,
      "got=%.6f want=%.6f" % (chans[3][idx], want))
check("LFE dry impulse is the peak (no wet pre-echo)",
      abs(max(chans[3], key=abs) - chans[3][idx]) < 1e-9)
check("LFE tail is silent", peak(chans[3][idx + 1:]) < 1e-9,
      "peak=%.3g" % peak(chans[3][idx + 1:]))
other_peak = max(peak(chans[c]) for c in range(8) if c != 3)
check("no LFE leakage into other channels", other_peak < 1e-9,
      "peak=%.3g" % other_peak)

# ---------------------------------------------------------------------------
# 3. reverb.lfe=1：LFE 有湿声，且低通
# ---------------------------------------------------------------------------
print("=== [3] reverb.lfe=1 湿声与 120Hz 低通 ===")
e3 = new_engine(8)
assert e3.set_i("reverb.preset", 5) == 0
assert e3.set_i("reverb.lfe", 1) == 0
blocks = run_blocks(e3, 8, 48, impulse_fill(8, [3]))
chans = [chan(blocks, 8, c) for c in range(8)]
check("LFE dry impulse still passes", abs(chans[3][idx] - want) < 5e-3,
      "got=%.6f" % chans[3][idx])
lfe_tail = rms(chans[3][idx + 100:idx + 10000])
check("LFE wet tail appears with reverb.lfe=1", lfe_tail > 1e-6,
      "rms=%.3g" % lfe_tail)
other_tail = min(rms(chans[c][idx + 100:idx + 10000]) for c in range(8) if c != 3)
check("LFE input also feeds other FDN outputs", other_tail > 1e-6,
      "min_rms=%.3g" % other_tail)

# 80Hz 应通过，1kHz 应被两级 120Hz 低通大幅衰减
rms_by_freq = {}
for freq in (80, 1000):
    ex = new_engine(8)
    set_custom_wet_only(ex, lfe=1)
    blocks = run_blocks(ex, 8, 60, tone_fill(8, 3, freq))
    out = chan(blocks, 8, 3)[2 * BLOCK:]
    rms_by_freq[freq] = rms(out)
    check("LFE tone %.0fHz output finite/non-silent" % freq,
          rms_by_freq[freq] > 1e-4 and
          all(math.isfinite(v) for v in out[:4096]),
          "rms=%.6g" % rms_by_freq[freq])
    ex.close()
ratio = rms_by_freq[80] / max(rms_by_freq[1000], 1e-12)
check("LFE wet is low-passed (80Hz >> 1kHz)", rms_by_freq[80] > 0.01 and ratio > 10.0,
      "80=%.5f 1k=%.5f ratio=%.1f" % (rms_by_freq[80], rms_by_freq[1000], ratio))

# ---------------------------------------------------------------------------
# 4. 运行中切换预设 / lfe / predelay：无 NaN、无爆炸
# ---------------------------------------------------------------------------
print("=== [4] 运行中切换预设/参数 ===")
e4 = new_engine(8)
assert e4.set_i("reverb.preset", 5) == 0
assert e4.set_i("reverb.lfe", 1) == 0
state = {"bad": False, "peak": 0.0}
curated = [5, 3, 1, 2, 9, 7, 11, 15]


def switch_cb(eng, b):
    if b == 20:
        eng.set_i("reverb.preset", 3)
    elif b == 35:
        eng.set_i("reverb.lfe", 0)
    elif b == 45:
        eng.set_f("reverb.predelay", 40.0)
    elif b == 55:
        eng.set_f("freeverb.decay", 0.85)
        eng.set_f("freeverb.damp", 0.2)
        eng.set_i("reverb.preset", -2)
    elif b == 70:
        eng.set_i("reverb.lfe", 1)
    elif b == 80:
        eng.set_i("reverb.preset", 15)
    elif b == 95:
        eng.set_f("reverb.predelay", 0.0)
    elif b == 105:
        eng.set_i("reverb.preset", -1)
    elif b == 112:
        eng.set_i("reverb.preset", curated[(b // 5) % len(curated)])


def mixed_fill(inb, b):
    for i in range(BLOCK):
        t = (b * BLOCK + i) / SR
        for c in range(8):
            inb[i * 8 + c] = 0.18 * math.sin(2 * math.pi * (70 + 37 * c) * t + 0.1 * c)


blocks = run_blocks(e4, 8, 120, mixed_fill, switch_cb)
for blk in blocks:
    for v in blk:
        if not math.isfinite(v):
            state["bad"] = True
        if abs(v) > state["peak"]:
            state["peak"] = abs(v)
check("preset/lfe/predelay switching finite (no NaN/Inf)", not state["bad"])
check("preset switching does not explode", state["peak"] < 5.0,
      "peak=%.3f" % state["peak"])
check("preset switching still produces audio",
      rms([v for blk in blocks[10:20] for v in blk]) > 1e-4)

# ---------------------------------------------------------------------------
# 5. reverb.outgain 真接线（MC 路径）
# ---------------------------------------------------------------------------
print("=== [5] reverb.outgain ===")


def render_outgain(gain_db):
    ex = new_engine(8)
    set_custom_wet_only(ex, lfe=0)
    assert ex.set_f("reverb.outgain", gain_db) == 0
    blocks = run_blocks(ex, 8, 48, impulse_fill(8, [0, 1]))
    out = chan(blocks, 8, 0)[2 * BLOCK + 1000:2 * BLOCK + 6000]
    val = rms(out)
    ex.close()
    return val


rms0 = render_outgain(0.0)
rms6 = render_outgain(6.0)
ratio = rms6 / max(rms0, 1e-12)
check("outgain +6dB ≈ 2x on MC FDN", 1.8 < ratio < 2.2,
      "0dB=%.6f +6dB=%.6f ratio=%.3f" % (rms0, rms6, ratio))

# ---------------------------------------------------------------------------
# 6. 4ch Quad
# ---------------------------------------------------------------------------
print("=== [6] 4ch Quad ===")
e6 = new_engine(4)
assert e6.set_i("reverb.preset", 5) == 0
blocks = run_blocks(e6, 4, 48, impulse_fill(4, [0, 1]))
chans = [chan(blocks, 4, c) for c in range(4)]
for c in range(4):
    check("4ch ch%d has FDN tail" % c,
          rms(chans[c][2 * BLOCK + 100:2 * BLOCK + 6000]) > 1e-5)
check("4ch output finite",
      all(math.isfinite(v) for c in chans for v in c))

for x in (e, e2, e3, e4, e6):
    x.close()

print()
if FAIL:
    print("MC REVERB FAILURES:", FAIL)
    sys.exit(1)
print("mc_reverb: all checks passed")
