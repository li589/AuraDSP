#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_reverb_boundary.py — WP1 混响边界验收（多声道重构 2026-10-25）。

本门禁只回答一个问题：**同一时刻只有一套混响在跑吗？**

  1. 路径判定：矩阵 / 双耳 → vendor Progenitor2（reverb.engine=0）；
     离散多声道 → MC FDN（reverb.engine=1）；reverb.preset=-1 → -1。
  2. 互斥证明：vendor 路径是唯一给总延迟 +30ms 的混响；MC 路径必须
     0ms。切到 MC 后 vendor 若仍启用，延迟会留在 30ms → 本门禁变红。
  3. deprecated 写别名：freeverb.enable 只能迁移到 reverb.preset，不得
     重新拉起第二套混响。
  4. 源码不变式：Freeverb DSP 文件/调用已删除，MC FDN 已接入链。

不测音色（由 smoke_reverb.py / smoke_mc_reverb.py 负责），只测边界。
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

    def latency(self):
        return dll.auradsp_get_latency_ms(self.h)

    def last_error(self):
        p = dll.auradsp_last_error(self.h)
        return p.decode("utf-8", "replace") if p else ""

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


def silence_all(e):
    for k, v in OFF_LIST:
        assert e.set_i(k, v) == 0, k


def configure(e, mode, count, binaural=0, spatial_on=0):
    assert e.set_i("spatial.binaural", binaural) == 0
    assert e.set_i("spatial.enable", spatial_on) == 0
    assert e.set_i("channels.count", count) == 0
    assert e.set_i("channels.mode", mode) == 0


def path_case(e, label, mode, count, preset, want_kind, want_delta,
              binaural=0, spatial_on=0):
    """在指定拓扑下比较 preset=-1 与 preset 的延迟差，并核对 engine 回读。"""
    configure(e, mode, count, binaural, spatial_on)
    assert e.set_i("reverb.preset", -1) == 0
    base = e.latency()
    assert e.set_i("reverb.preset", preset) == 0
    kind = e.get_i("reverb.engine")[1]
    delta = e.latency() - base
    ok = (kind == want_kind and abs(delta - want_delta) < 0.01)
    check(label, ok, "kind=%d delta=%.2f (want %d / %.2f)" %
          (kind, delta, want_kind, want_delta))


# ---------------------------------------------------------------------------
# 1. 路径判定 + 延迟互斥证明
# ---------------------------------------------------------------------------
e = Engine()
silence_all(e)

print("=== [1] 路径判定 & 30ms 互斥证明 ===")
# 矩阵模式（默认立体声链）→ vendor
path_case(e, "matrix 2ch preset=5 -> vendor +30ms", 0, 2, 5, 0, 30.0)
# 离散 2ch 也属于 MC FDN（文档 D3/§3.2）
path_case(e, "discrete 2ch preset=5 -> FDN +0ms", 1, 2, 5, 1, 0.0)
path_case(e, "discrete 8ch preset=5 -> FDN +0ms", 1, 8, 5, 1, 0.0)
# 双耳：mode=1 但满足 binaural && spatial.enable && count>=4 → vendor
path_case(e, "discrete 8ch + binaural -> vendor +30ms", 1, 8, 5, 0, 30.0,
          binaural=1, spatial_on=1)
path_case(e, "discrete 4ch + binaural -> vendor +30ms", 1, 4, 5, 0, 30.0,
          binaural=1, spatial_on=1)
# count<4 不允许双耳接管
path_case(e, "discrete 2ch + binaural flags -> FDN +0ms", 1, 2, 5, 1, 0.0,
          binaural=1, spatial_on=1)
# 只有 binaural 或只有 spatial.enable 都不算双耳路径
path_case(e, "binaural flag without spatial.enable -> FDN", 1, 8, 5, 1, 0.0,
          binaural=1, spatial_on=0)
path_case(e, "spatial.enable without binaural -> FDN", 1, 8, 5, 1, 0.0,
          binaural=0, spatial_on=1)
# matrix 模式优先于双耳标志
path_case(e, "matrix wins over binaural flags -> vendor", 0, 8, 5, 0, 30.0,
          binaural=1, spatial_on=1)
# 自定义 -2：vendor 先落 preset 0 保状态；MC 走 FDN 自定义映射
path_case(e, "matrix preset=-2 -> vendor +30ms", 0, 2, -2, 0, 30.0)
path_case(e, "discrete 8ch preset=-2 -> FDN +0ms", 1, 8, -2, 1, 0.0)
# 关闭优先于一切拓扑（基线与开启后对比，避免把 spatial 自身延迟算进来）
configure(e, 1, 8, binaural=1, spatial_on=1)
assert e.set_i("reverb.preset", -1) == 0
base = e.latency()
check("preset=-1 wins over binaural topology -> -1",
      e.get_i("reverb.engine")[1] == -1 and abs(e.latency() - base) < 0.01,
      "kind=%r lat=%.2f" % (e.get_i("reverb.engine")[1], e.latency()))

# 切回 matrix 后 vendor 立即回来；再切 MC 延迟必须归零（无残留第二套引擎）
assert e.set_i("reverb.preset", 5) == 0
configure(e, 0, 2)
check("handoff: MC -> matrix re-enables vendor (+30ms)",
      e.get_i("reverb.engine")[1] == 0 and abs(e.latency() - 30.0) < 0.01,
      "kind=%r lat=%.2f" % (e.get_i("reverb.engine")[1], e.latency()))
configure(e, 1, 8)
check("handoff: matrix -> MC disables vendor (+0ms)",
      e.get_i("reverb.engine")[1] == 1 and abs(e.latency()) < 0.01,
      "kind=%r lat=%.2f" % (e.get_i("reverb.engine")[1], e.latency()))

# ---------------------------------------------------------------------------
# 2. deprecated freeverb.enable 写别名
# ---------------------------------------------------------------------------
print("=== [2] freeverb.enable 写别名（唯一开关仍是 reverb.preset） ===")
configure(e, 0, 2)
assert e.set_i("reverb.preset", -1) == 0
base = e.latency()

check("alias on: -1 -> preset 0", e.set_i("freeverb.enable", 1) == 0 and
      e.get_i("reverb.preset") == (0, 0),
      "preset=%r" % (e.get_i("reverb.preset"),))
check("alias on: vendor actually enabled (+30ms)",
      e.get_i("reverb.engine")[1] == 0 and abs(e.latency() - base - 30.0) < 0.01,
      "kind=%r lat=%.2f" % (e.get_i("reverb.engine")[1], e.latency()))

check("alias off: -> preset -1", e.set_i("freeverb.enable", 0) == 0 and
      e.get_i("reverb.preset") == (0, -1),
      "preset=%r" % (e.get_i("reverb.preset"),))
check("alias off: vendor disabled (latency back to base)",
      e.get_i("reverb.engine")[1] == -1 and abs(e.latency() - base) < 0.01,
      "kind=%r lat=%.2f" % (e.get_i("reverb.engine")[1], e.latency()))

# 已经开着别的预设时，别名 on 不得改写预设
assert e.set_i("reverb.preset", 3) == 0
check("alias on keeps existing preset 3",
      e.set_i("freeverb.enable", 1) == 0 and e.get_i("reverb.preset") == (0, 3),
      "preset=%r" % (e.get_i("reverb.preset"),))
check("alias off turns preset 3 off",
      e.set_i("freeverb.enable", 0) == 0 and e.get_i("reverb.preset") == (0, -1))

# 自定义态下别名 on 只恢复“开”，不得把 -2 改成 0
assert e.set_i("reverb.preset", -2) == 0
check("alias on keeps custom -2",
      e.set_i("freeverb.enable", 1) == 0 and e.get_i("reverb.preset") == (0, -2),
      "preset=%r" % (e.get_i("reverb.preset"),))

# ---------------------------------------------------------------------------
# 3. 预设越界拒绝 + 引擎存活
# ---------------------------------------------------------------------------
print("=== [3] reverb.preset 边界 ===")
assert e.set_i("reverb.preset", -2) == 0
check("preset -2 accepted", e.get_i("reverb.preset") == (0, -2))
check("preset 18 accepted", e.set_i("reverb.preset", 18) == 0 and
      e.get_i("reverb.preset") == (0, 18))
for bad in (19, 100, -2147483648, -3):
    rc = e.set_i("reverb.preset", bad)
    check("preset %d rejected (E_PARAM)" % bad, rc == E_PARAM,
          "rc=%d err=%s" % (rc, e.last_error()))
check("preset 0 ok after rejects", e.set_i("reverb.preset", 0) == 0)

# 拒绝后引擎仍能播放（不给 SIGFPE / NaN）
buf = (ctypes.c_float * (BLOCK * 2))()
out = (ctypes.c_float * (BLOCK * 2))()
bad = False
for b in range(8):
    for i in range(BLOCK):
        buf[i * 2] = 0.2 * math.sin(b * 0.3 + i * 0.05)
        buf[i * 2 + 1] = buf[i * 2]
    dll.auradsp_process(e.h, buf, out, BLOCK)
    for i in range(BLOCK * 2):
        if not math.isfinite(out[i]) or abs(out[i]) > 10.0:
            bad = True
            break
check("engine alive after preset rejects (finite output)", not bad)

# ---------------------------------------------------------------------------
# 4. 源码不变式：Freeverb 退役 / MC FDN 接入
# ---------------------------------------------------------------------------
print("=== [4] 源码不变式 ===")
freeverb_cpp = os.path.join(ROOT, "engine", "dsp", "dsp_freeverb.cpp")
mc_cpp = os.path.join(ROOT, "engine", "dsp", "dsp_mc_reverb.cpp")
chain_cpp = os.path.join(ROOT, "engine", "chain", "engine_chain.cpp")
cmake = os.path.join(ROOT, "core", "desktop", "windows", "CMakeLists.txt")
core_sources = os.path.join(ROOT, "engine", "core_sources.cmake")

check("dsp_freeverb.cpp removed", not os.path.exists(freeverb_cpp))
check("dsp_mc_reverb.cpp exists", os.path.exists(mc_cpp))
if os.path.exists(chain_cpp):
    chain = open(chain_cpp, encoding="utf-8").read()
    check("engine_chain has no freeverb_process call", "freeverb_process" not in chain)
    check("engine_chain calls mc_reverb_process_mc", "mc_reverb_process_mc" in chain)
if os.path.exists(cmake) or os.path.exists(core_sources):
    # CP-27（2026-11-01）：chain/dsp 源表已抽到 engine/core_sources.cmake，
    # 断言需同时覆盖 Windows CMake 与唯一源表。
    cm = ""
    for p in (cmake, core_sources):
        if os.path.exists(p):
            cm += open(p, encoding="utf-8").read()
    check("CMake no dsp_freeverb.cpp", "dsp_freeverb.cpp" not in cm)
    check("CMake includes dsp_mc_reverb.cpp", "dsp_mc_reverb.cpp" in cm)

e.close()

print()
if FAIL:
    print("REVERB BOUNDARY FAILURES:", FAIL)
    sys.exit(1)
print("reverb_boundary: all checks passed")
