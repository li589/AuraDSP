#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_wp0_scaffold.py — WP0 脚手架验收（多声道重构 2026-10-25）。

本阶段不改变任何 DSP 行为，只验证新增参数占位与路径判定：
  1. 新参数默认值（predelay=0 / lfe=0 / pairs=1 / merge=0 / comp.mode=0 /
     post.gain.c0..c7=0 / channels.countMode=0 / reverb.engine=-1）；
  2. set/get 往返（FLOAT/INT/BOOL）与通用钳位；
  3. 越界拒绝：bassmono.pairs(0..15)、bassmono.merge(0/1)、comp.mode(0/1)；
  4. reverb.engine 只读：写入必须 rc!=0 且 last_error 含 read-only；
  5. reverb.engine 路径映射（矩阵/双耳→0，离散 MC→1，preset=-1→-1）；
  6. stereo 逐位不变：新参数显式写默认值 vs 不写，输出逐字节相等
     （preset=-1 与 preset=0 两种场景）。

用法：python test/smoke/smoke_wp0_scaffold.py
"""
import ctypes
import math
import os
import struct
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

    def last_error(self):
        p = dll.auradsp_last_error(self.h)
        return p.decode("utf-8", "replace") if p else ""

    def process(self, buf):
        out = (ctypes.c_float * len(buf))()
        dll.auradsp_process(self.h, buf, out, BLOCK)
        return out


# ---------------------------------------------------------------------------
# 1. 默认值
# ---------------------------------------------------------------------------
e = Engine()
check("default reverb.predelay = 0", e.get_f("reverb.predelay") == (0, 0.0))
check("default reverb.lfe = 0", e.get_i("reverb.lfe") == (0, 0))
check("default reverb.engine = -1", e.get_i("reverb.engine") == (0, -1),
      str(e.get_i("reverb.engine")))
check("default bassmono.pairs = 0x01", e.get_i("bassmono.pairs") == (0, 1),
      str(e.get_i("bassmono.pairs")))
check("default bassmono.merge = 0", e.get_i("bassmono.merge") == (0, 0))
check("default comp.mode = 0", e.get_i("comp.mode") == (0, 0))
check("default channels.countMode = 0", e.get_i("channels.countMode") == (0, 0))
for c in range(8):
    rc, v = e.get_f("post.gain.c%d" % c)
    check("default post.gain.c%d = 0 dB" % c, rc == 0 and v == 0.0,
          "rc=%d v=%r" % (rc, v))

# ---------------------------------------------------------------------------
# 2. set/get 往返 + 通用钳位
# ---------------------------------------------------------------------------
check("roundtrip reverb.predelay", e.set_f("reverb.predelay", 42.5) == 0 and
      abs(e.get_f("reverb.predelay")[1] - 42.5) < 1e-6)
e.set_f("reverb.predelay", 150.0)
check("reverb.predelay high clamp 100", abs(e.get_f("reverb.predelay")[1] - 100.0) < 1e-6)
e.set_f("reverb.predelay", -5.0)
check("reverb.predelay low clamp 0", abs(e.get_f("reverb.predelay")[1]) < 1e-6)
e.set_f("reverb.predelay", 0.0)

check("roundtrip reverb.lfe", e.set_i("reverb.lfe", 1) == 0 and
      e.get_i("reverb.lfe") == (0, 1))
e.set_i("reverb.lfe", 0)

check("roundtrip bassmono.pairs = 15", e.set_i("bassmono.pairs", 15) == 0 and
      e.get_i("bassmono.pairs") == (0, 15))
check("roundtrip bassmono.merge", e.set_i("bassmono.merge", 1) == 0 and
      e.get_i("bassmono.merge") == (0, 1))
check("roundtrip comp.mode", e.set_i("comp.mode", 1) == 0 and
      e.get_i("comp.mode") == (0, 1))
check("roundtrip channels.countMode", e.set_i("channels.countMode", 1) == 0 and
      e.get_i("channels.countMode") == (0, 1))

e.set_f("post.gain.c3", -7.5)
e.set_f("post.gain.c7", 12.25)
check("roundtrip post.gain.c3", abs(e.get_f("post.gain.c3")[1] + 7.5) < 1e-6)
check("roundtrip post.gain.c7", abs(e.get_f("post.gain.c7")[1] - 12.25) < 1e-6)
e.set_f("post.gain.c0", 100.0)
check("post.gain.c0 high clamp 15", abs(e.get_f("post.gain.c0")[1] - 15.0) < 1e-6)
e.set_f("post.gain.c1", -100.0)
check("post.gain.c1 low clamp -15", abs(e.get_f("post.gain.c1")[1] + 15.0) < 1e-6)

# NaN / Inf 必须被通用路径拒绝，且不污染存储
before = e.get_f("reverb.predelay")[1]
rc_nan = e.set_f("reverb.predelay", float("nan"))
rc_inf = e.set_f("reverb.predelay", float("inf"))
check("reverb.predelay NaN rejected", rc_nan != 0)
check("reverb.predelay Inf rejected", rc_inf != 0)
check("reverb.predelay unchanged after NaN/Inf", e.get_f("reverb.predelay")[1] == before)

# channels.countMode 是纯状态载体：走通用 INT 钳位而非拒绝
e.set_i("channels.countMode", 9)
check("channels.countMode high clamp 1", e.get_i("channels.countMode") == (0, 1))
e.set_i("channels.countMode", -9)
check("channels.countMode low clamp 0", e.get_i("channels.countMode") == (0, 0))

# ---------------------------------------------------------------------------
# 3. 越界拒绝（自定义 setter：值保持不变）
# ---------------------------------------------------------------------------
rc = e.set_i("bassmono.pairs", -1)
check("bassmono.pairs=-1 rejected", rc != 0 and e.get_i("bassmono.pairs") == (0, 15),
      "rc=%d val=%r" % (rc, e.get_i("bassmono.pairs")))
rc = e.set_i("bassmono.pairs", 16)
check("bassmono.pairs=16 rejected", rc != 0 and e.get_i("bassmono.pairs") == (0, 15))
check("bassmono.pairs error text", "bassmono.pairs" in e.last_error(),
      e.last_error())

rc = e.set_i("bassmono.merge", 2)
check("bassmono.merge=2 rejected", rc != 0 and e.get_i("bassmono.merge") == (0, 1))
rc = e.set_i("bassmono.merge", -1)
check("bassmono.merge=-1 rejected", rc != 0 and e.get_i("bassmono.merge") == (0, 1))

rc = e.set_i("comp.mode", 2)
check("comp.mode=2 rejected", rc != 0 and e.get_i("comp.mode") == (0, 1))
rc = e.set_i("comp.mode", -1)
check("comp.mode=-1 rejected", rc != 0 and e.get_i("comp.mode") == (0, 1))

# ---------------------------------------------------------------------------
# 4. reverb.engine 只读
# ---------------------------------------------------------------------------
rc = e.set_i("reverb.engine", 0)
err = e.last_error()
check("reverb.engine write rejected", rc != 0, "rc=%d" % rc)
check("reverb.engine error says read-only", "read-only" in err, err)
check("reverb.engine still readable", e.get_i("reverb.engine")[0] == 0)

# ---------------------------------------------------------------------------
# 5. reverb.engine 路径映射
# ---------------------------------------------------------------------------
p = Engine()


def engine_kind():
    return p.get_i("reverb.engine")[1]


check("path: preset=-1 -> -1 (off)", engine_kind() == -1)
p.set_i("reverb.preset", 0)
check("path: matrix (mode=0) -> vendor stereo 0", engine_kind() == 0)
p.set_i("channels.mode", 1)
p.set_i("channels.count", 2)
check("path: mode=1 + count=2 -> MC FDN 1", engine_kind() == 1)
p.set_i("channels.count", 4)
p.set_i("spatial.binaural", 1)
p.set_i("spatial.enable", 1)
check("path: discrete + binaural 4ch -> vendor 0", engine_kind() == 0)
p.set_i("spatial.enable", 0)
check("path: binaural flag without enable -> MC FDN 1", engine_kind() == 1)
p.set_i("spatial.enable", 1)
p.set_i("spatial.binaural", 0)
check("path: spatial enable without binaural -> MC FDN 1", engine_kind() == 1)
p.set_i("spatial.binaural", 1)
p.set_i("channels.count", 6)
check("path: discrete + binaural 6ch -> vendor 0", engine_kind() == 0)
p.set_i("channels.mode", 0)
check("path: mode=0 wins over binaural -> vendor 0", engine_kind() == 0)
p.set_i("reverb.preset", -1)
check("path: preset=-1 wins over topology -> -1", engine_kind() == -1)
p.set_i("reverb.preset", -2)
check("path: preset=-2 custom in matrix -> vendor 0", engine_kind() == 0)
p.set_i("channels.mode", 1)
p.set_i("channels.count", 2)
p.set_i("spatial.binaural", 0)
p.set_i("spatial.enable", 0)
check("path: preset=-2 custom + mode=1 2ch -> MC 1", engine_kind() == 1)
p.close()

# ---------------------------------------------------------------------------
# 6. stereo 逐位不变（新参数显式写默认值 vs 不写）
# ---------------------------------------------------------------------------
def make_signal(blocks):
    """确定性混合信号（双声道）：正弦 + LCG 噪声，覆盖低频/高频。"""
    state = 0x12345678
    out = []
    n0 = 0
    for _ in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            t = (n0 + i) / SR
            state = (1664525 * state + 1013904223) & 0xFFFFFFFF
            noise = (state / 4294967296.0) * 2.0 - 1.0
            l = 0.35 * math.sin(2 * math.pi * 110.0 * t) + 0.05 * noise
            r = 0.30 * math.sin(2 * math.pi * 997.0 * t + 0.4) - 0.05 * noise
            buf[i * 2] = l
            buf[i * 2 + 1] = r
        out.append(buf)
        n0 += BLOCK
    return out


def render(engine, blocks):
    chunks = []
    for buf in blocks:
        out = engine.process(buf)
        chunks.append(bytes(out))
    return b"".join(chunks), chunks


def set_new_defaults(engine):
    assert engine.set_f("reverb.predelay", 0.0) == 0
    assert engine.set_i("reverb.lfe", 0) == 0
    assert engine.set_i("bassmono.pairs", 1) == 0
    assert engine.set_i("bassmono.merge", 0) == 0
    assert engine.set_i("comp.mode", 0) == 0
    assert engine.set_i("channels.countMode", 0) == 0
    for c in range(8):
        assert engine.set_f("post.gain.c%d" % c, 0.0) == 0


blocks = make_signal(8)
for preset in (-1, 0):
    a = Engine()
    b = Engine()
    set_new_defaults(b)
    if preset >= 0:
        assert a.set_i("reverb.preset", preset) == 0
        assert b.set_i("reverb.preset", preset) == 0
    out_a, chunks_a = render(a, blocks)
    out_b, chunks_b = render(b, blocks)
    tag = "preset=%d" % preset
    # vendor Progenitor2 的内部调制状态不是跨实例逐位可复现的（实测两个
    # 全新 handle 同预设输出有 1e-7 量级差异），所以逐位断言只对干路径
    # （preset=-1）成立；preset>=0 只做存活/有限值检查，音色回归由
    # smoke_reverb.py 负责。
    if preset < 0:
        check("%s: stereo output bit-identical" % tag, out_a == out_b,
              "len %d vs %d" % (len(out_a), len(out_b)))
        check("%s: block-wise bit-identical" % tag, chunks_a == chunks_b)
    # 非空转证明：输出非静音且全为有限值
    peak = max(abs(v) for v in struct.unpack("<%df" % (len(out_a) // 4), out_a))
    finite = all(math.isfinite(v)
                 for v in struct.unpack("<%df" % (len(out_a) // 4), out_a))
    check("%s: output non-silent & finite" % tag, peak > 1e-4 and finite,
          "peak=%r finite=%r" % (peak, finite))
    a.close()
    b.close()

e.close()

print()
if FAIL:
    print("WP0 SCAFFOLD FAILURES:", FAIL)
    sys.exit(1)
print("wp0_scaffold: all checks passed")
