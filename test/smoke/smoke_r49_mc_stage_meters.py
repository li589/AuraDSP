#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_r49_mc_stage_meters — 第四十九轮 S1 门禁。

定罪背景（r48 宾机 D1 复核）：离散 7.1 下 tube/comp/eq/
reverb/output 等效果器电平或无显示或假立体声。审计定罪：
emit_viz 对 vendor 索引级（0..11）的 L/R 只读 jdsp.
stagePeakL/R，而 MC 模式下这些效果走自研 *_process_mc、
不过 vendor，jdsp 槽永不更新；stage_peak_ch 网格同样无
人写。本轮补接 sample_stage_mc_vendor 六处 tap（0 tube /
1 comp / 3 eq / 4 arbmag 改镜像 / 10 reverb / 11 output）。

本门禁钉住：
  1. 源码口径：helper 存在且六处 tap 在 MC 链内；
  2. 行为（DLL 在场时）：8 声道离散、全声道异频正弦直通，
     上述六级 + 既有自研级的 stage_levels L/R 与
     stage_ch_levels 全 8 列均应有信号（> -30 dBFS）；
  3. 诚实口径：立体声本性级（2 bass / 5..9 vendor 对）的
     网格 2..7 列恒 -120（不借位假装多声道），其 L/R 由
     vendor 对采样保持鲜活（> -30）。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "test"))
from engine_artifact import engine_lib_path  # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (("  " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


# ---------- 1) 源码口径 ----------
chain = read("engine/chain/engine_chain.cpp")
check("helper sample_stage_mc_vendor defined",
      "static inline void sample_stage_mc_vendor" in chain and
      "h->jdsp.stagePeakL[sidx] = h->stage_peak_l[sidx];" in chain)
for sidx, label in [(0, "tube"), (1, "comp"), (3, "eq"), (4, "arbmag"),
                    (10, "reverb"), (11, "output")]:
    check(f"MC tap present: stage {sidx} ({label})",
          f"sample_stage_mc_vendor(h, {sidx}, dst, frames, ch)" in chain)

# ---------- 2) 行为（DLL 在场时） ----------
dll_path = engine_lib_path()
if not os.path.exists(dll_path):
    print(f"SKIP behavioral (engine artifact missing: {dll_path})")
else:
    _VIZ_BIN = os.path.join(ROOT, "tools", "bin")
    if _VIZ_BIN not in sys.path:
        sys.path.insert(0, _VIZ_BIN)
    from viz_frame import VizFrame  # noqa: E402

    dll = ctypes.CDLL(dll_path)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_set_param.restype = ctypes.c_int
    dll.auradsp_set_param.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_viz_read.restype = ctypes.c_uint32
    dll.auradsp_viz_read.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(VizFrame), ctypes.c_uint32]

    h = dll.auradsp_create(48000.0, 240)
    assert h, "engine create failed"

    def set_i(pid, v):
        return dll.auradsp_set_param(h, pid.encode(),
                                     ctypes.byref(ctypes.c_int32(v)), 4)

    check("set channels.count=8", set_i("channels.count", 8) == 0)
    check("set channels.mode=1 (discrete)", set_i("channels.mode", 1) == 0)

    N, CH = 240, 8
    in_buf = (ctypes.c_float * (N * CH))()
    out_buf = (ctypes.c_float * (N * CH))()
    frames = (VizFrame * 64)()
    phases = [0.0] * CH
    last = None
    for _ in range(300):
        for i in range(N):
            for c in range(CH):
                phases[c] += 2.0 * math.pi * (110.0 * (c + 1)) / 48000.0
                in_buf[i * CH + c] = 0.4 * math.sin(phases[c])
        dll.auradsp_process(h, in_buf, out_buf, N)
        n = dll.auradsp_viz_read(h, frames, 64)
        if n > 0:
            last = frames[n - 1]
    assert last is not None, "no viz frames"

    full = [0, 1, 3, 4, 10, 11, 13, 14, 15, 16, 18, 19]
    for s in full:
        check(f"stage {s} L/R live",
              last.stage_levels_l[s] > -30.0 and last.stage_levels_r[s] > -30.0,
              f"L={last.stage_levels_l[s]:.1f} R={last.stage_levels_r[s]:.1f}")
        bad = [c for c in range(CH)
               if last.stage_ch_levels[s * 8 + c] <= -30.0]
        check(f"stage {s} grid all 8ch live", not bad,
              f"dark columns: {bad}")

    for s in [2, 5, 6, 7, 8, 9]:
        check(f"stage {s} pair L/R live (vendor tap)",
              last.stage_levels_l[s] > -30.0 and last.stage_levels_r[s] > -30.0,
              f"L={last.stage_levels_l[s]:.1f} R={last.stage_levels_r[s]:.1f}")
        lit = [c for c in range(2, CH)
               if last.stage_ch_levels[s * 8 + c] > -119.0]
        check(f"stage {s} grid honest-dark beyond FL/FR", not lit,
              f"lit columns: {lit}")

    dll.auradsp_destroy(h)

if FAILS:
    print("MC_STAGE_METERS FAILURES:", FAILS)
    sys.exit(1)
print("mc_stage_meters: all checks passed")
