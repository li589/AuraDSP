#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_reverb.py — WP1 vendor 立体声混响路径验收。

WP1 后 `reverb.preset` 是唯一混响开关：
  -1 关 / -2 自定义 / 0..18 预设。
矩阵/双耳路径使用 vendor Progenitor2；离散多声道路径使用 MC FDN
（见 smoke_mc_reverb.py）。本文件只测 vendor 路径，旧 Freeverb 断言已删除。

覆盖：
  1. 关闭：脉冲干通、无尾音、engine=-1、无 30ms 混响延迟。
  2. 预设 0 / 18：有可测尾音、engine=0、+30ms。
  3. 自定义 -2：vendor 先落 preset 0 保状态，仍有尾音与 +30ms。
  4. freeverb.* 自定义参数 set/get/钳位（ABI 兼容名保留）。
  5. freeverb.enable 写别名：只迁移 reverb.preset，不拉起第二套混响。
  6. preset 越界拒绝 + 拒绝后引擎存活；运行中切预设/参数无 NaN/爆炸。
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
E_PARAM = -1
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
dll.auradsp_get_latency_ms.restype = ctypes.c_double
dll.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]


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

    def latency(self):
        return dll.auradsp_get_latency_ms(self.h)

    def last_error(self):
        p = dll.auradsp_last_error(self.h)
        return p.decode("utf-8", "replace") if p else ""

    def process(self, inb):
        out = (ctypes.c_float * len(inb))()
        dll.auradsp_process(self.h, inb, out, BLOCK)
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


def new_vendor_engine():
    e = Engine()
    for k, v in OFF_LIST:
        assert e.set_i(k, v) == 0, k
    assert e.set_i("channels.count", 2) == 0
    assert e.set_i("channels.mode", 0) == 0
    assert e.set_i("reverb.preset", -1) == 0
    return e


def impulse_tail(e, blocks=48, amp=0.5):
    """首块打双声道脉冲，返回 (首非零采样, 尾能量占比, 峰值)。"""
    sig = []
    for b in range(blocks):
        inb = (ctypes.c_float * (BLOCK * 2))()
        if b == 0:
            inb[0] = amp
            inb[1] = amp
        out = e.process(inb)
        for i in range(BLOCK):
            sig.append(out[i * 2])
    total = sum(s * s for s in sig)
    tail = sum(s * s for s in sig[2000:12000])
    first = next((i for i, s in enumerate(sig) if abs(s) > 0.01), -1)
    return first, (tail / total) if total > 0.0 else 0.0, max(abs(s) for s in sig)


# ---------------------------------------------------------------------------
# [0] 基础参数往返 / 钳位
# ---------------------------------------------------------------------------
print("=== [0] 基础参数 ===")
e = new_vendor_engine()
check("default preset=-1 -> engine -1",
      e.get_i("reverb.preset") == (0, -1) and e.get_i("reverb.engine") == (0, -1))
check("default vendor latency 0ms (limiter off)", abs(e.latency()) < 0.01,
      "lat=%.2f" % e.latency())

check("freeverb.decay roundtrip",
      e.set_f("freeverb.decay", 0.7) == 0 and
      abs(e.get_f("freeverb.decay")[1] - 0.7) < 1e-6)
check("freeverb.damp roundtrip",
      e.set_f("freeverb.damp", 0.4) == 0 and
      abs(e.get_f("freeverb.damp")[1] - 0.4) < 1e-6)
check("freeverb.wet roundtrip",
      e.set_f("freeverb.wet", 0.8) == 0 and
      abs(e.get_f("freeverb.wet")[1] - 0.8) < 1e-6)
check("freeverb.dry roundtrip",
      e.set_f("freeverb.dry", 0.2) == 0 and
      abs(e.get_f("freeverb.dry")[1] - 0.2) < 1e-6)
check("freeverb.roomsize clamp 0.5..2.5",
      e.set_f("freeverb.roomsize", 9.0) == 0 and
      abs(e.get_f("freeverb.roomsize")[1] - 2.5) < 1e-6)
check("freeverb.width clamp 0.2..2.0",
      e.set_f("freeverb.width", 0.0) == 0 and
      abs(e.get_f("freeverb.width")[1] - 0.2) < 1e-6)
check("reverb.predelay roundtrip/clamp",
      e.set_f("reverb.predelay", 42.5) == 0 and
      abs(e.get_f("reverb.predelay")[1] - 42.5) < 1e-6 and
      e.set_f("reverb.predelay", 150.0) == 0 and
      abs(e.get_f("reverb.predelay")[1] - 100.0) < 1e-6)
check("reverb.lfe roundtrip",
      e.set_i("reverb.lfe", 1) == 0 and e.get_i("reverb.lfe") == (0, 1) and
      e.set_i("reverb.lfe", 0) == 0 and e.get_i("reverb.lfe") == (0, 0))

# 关闭状态：干通、无尾
first, tail, peak = impulse_tail(e)
check("disabled: impulse at sample 0", first == 0, "first=%d" % first)
check("disabled: no tail", tail < 0.001, "tail=%.6f" % tail)
check("disabled: peak equals dry input", abs(peak - 0.5) < 1e-6,
      "peak=%.6f" % peak)

# ---------------------------------------------------------------------------
# [1] vendor 预设：有尾 + 30ms
# ---------------------------------------------------------------------------
print("=== [1] vendor 预设 ===")
for preset in (0, 18):
    assert e.set_i("reverb.preset", -1) == 0
    base = e.latency()
    assert e.set_i("reverb.preset", preset) == 0
    first, tail, peak = impulse_tail(e)
    check("preset %d: engine 0" % preset, e.get_i("reverb.engine") == (0, 0),
          str(e.get_i("reverb.engine")))
    check("preset %d: +30ms vendor latency" % preset,
          abs(e.latency() - base - 30.0) < 0.01,
          "delta=%.2f" % (e.latency() - base))
    check("preset %d: readable tail" % preset, tail > 0.05,
          "tail=%.4f" % tail)
    check("preset %d: finite output" % preset, math.isfinite(peak) and peak < 1.0,
          "peak=%.4f" % peak)

# ---------------------------------------------------------------------------
# [2] 自定义 -2：WP2 前 vendor 落 preset 0
# ---------------------------------------------------------------------------
print("=== [2] 自定义 -2（vendor 兜底） ===")
assert e.set_i("reverb.preset", -2) == 0
base = e.latency()
first, tail, peak = impulse_tail(e)
check("preset -2 accepted and readback -2", e.get_i("reverb.preset") == (0, -2))
check("preset -2 uses vendor engine 0", e.get_i("reverb.engine") == (0, 0))
check("preset -2 has +30ms vendor latency", abs(base - 30.0) < 0.01,
      "lat=%.2f" % base)
check("preset -2 still produces tail (vendor preset 0)", tail > 0.05,
      "tail=%.4f" % tail)

# ---------------------------------------------------------------------------
# [3] freeverb.enable deprecated 写别名
# ---------------------------------------------------------------------------
print("=== [3] freeverb.enable 写别名 ===")
assert e.set_i("reverb.preset", -1) == 0
check("alias on: -1 -> preset 0",
      e.set_i("freeverb.enable", 1) == 0 and e.get_i("reverb.preset") == (0, 0))
check("alias on: engine 0 / +30ms",
      e.get_i("reverb.engine") == (0, 0) and abs(e.latency() - 30.0) < 0.01)
check("alias off: -> preset -1",
      e.set_i("freeverb.enable", 0) == 0 and e.get_i("reverb.preset") == (0, -1))
check("alias off: engine -1 / 0ms",
      e.get_i("reverb.engine") == (0, -1) and abs(e.latency()) < 0.01)

assert e.set_i("reverb.preset", 3) == 0
check("alias on keeps existing preset 3",
      e.set_i("freeverb.enable", 1) == 0 and e.get_i("reverb.preset") == (0, 3))
assert e.set_i("reverb.preset", -2) == 0
check("alias on keeps custom -2",
      e.set_i("freeverb.enable", 1) == 0 and e.get_i("reverb.preset") == (0, -2))

# ---------------------------------------------------------------------------
# [4] 预设越界 + 拒绝后存活
# ---------------------------------------------------------------------------
print("=== [4] preset 边界 ===")
check("preset -2 accepted", e.set_i("reverb.preset", -2) == 0)
check("preset 18 accepted", e.set_i("reverb.preset", 18) == 0 and
      e.get_i("reverb.preset") == (0, 18))
for bad in (19, 100, -2147483648, -3):
    rc = e.set_i("reverb.preset", bad)
    check("preset %d rejected (E_PARAM)" % bad, rc == E_PARAM,
          "rc=%d err=%s" % (rc, e.last_error()))
check("preset 0 ok after rejects", e.set_i("reverb.preset", 0) == 0)

buf = (ctypes.c_float * (BLOCK * 2))()
out = (ctypes.c_float * (BLOCK * 2))()
bad = False
for b in range(8):
    for i in range(BLOCK):
        buf[i * 2] = 0.2 * math.sin(b * 0.3 + i * 0.05)
        buf[i * 2 + 1] = buf[i * 2]
    out = e.process(buf)
    for i in range(BLOCK * 2):
        if not math.isfinite(out[i]) or abs(out[i]) > 10.0:
            bad = True
            break
check("engine alive after preset rejects (no NaN/blowup)", not bad)

# ---------------------------------------------------------------------------
# [5] 运行中切预设/参数：无 NaN、无爆炸
# ---------------------------------------------------------------------------
print("=== [5] 运行中切换 ===")
bad = False
peak = 0.0
for b in range(60):
    buf = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        t = (b * BLOCK + i) / SR
        buf[i * 2] = 0.2 * math.sin(2 * math.pi * 220.0 * t)
        buf[i * 2 + 1] = 0.2 * math.sin(2 * math.pi * 330.0 * t + 0.3)
    if b == 8:
        e.set_i("reverb.preset", 5)
    elif b == 16:
        e.set_i("reverb.preset", 18)
    elif b == 24:
        e.set_i("reverb.preset", -2)
    elif b == 32:
        e.set_i("reverb.preset", -1)
    elif b == 40:
        e.set_i("reverb.preset", 0)
    elif b == 44:
        e.set_f("reverb.predelay", 30.0)
        e.set_i("reverb.lfe", 1)
    elif b == 48:
        e.set_f("freeverb.decay", 0.9)
        e.set_f("freeverb.width", 1.5)
        e.set_i("reverb.lfe", 0)
    out = e.process(buf)
    for i in range(BLOCK * 2):
        v = out[i]
        if not math.isfinite(v):
            bad = True
        if abs(v) > peak:
            peak = abs(v)
check("mid-stream switching finite (no NaN/Inf)", not bad)
check("mid-stream switching no explosion", peak < 10.0, "peak=%.3f" % peak)

e.close()

print()
if FAIL:
    print("REVERB FAILURES:", FAIL)
    sys.exit(1)
print("reverb: all checks passed")
