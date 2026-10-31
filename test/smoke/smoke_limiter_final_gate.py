#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_limiter_final_gate.py — ADR-010「限幅器是链尾最后一道门」不变量门禁。

背景（D-1，2026-10-31 用户裁定）：
    内置信号链里，总输出增益（post.gain）与逐声道 trim（post.gain.cN）
    必须排在限幅器**之前**——限幅器是链尾最后一道门，负责兜住所有会抬电平的环节。
    推论：限幅器开启时，把 post.gain 往上推不会让最终输出超过限幅门限
    （表现为 GR 上升而不是电平上升）；限幅器关闭时 post.gain 才是纯输出增益。

本门禁覆盖四条路径（post gain 的两套实现 + 三条调度分支）：
    [1] 立体声     process_stereo_chain（post gain 在 vendor stage_output 内）
    [2] 矩阵混音   mx_downmix → process_stereo_chain → mx_upmix
    [3] 双耳空间   spatial_binaural_process → process_stereo_chain
    [4] 离散多声道 process_multichannel_chain（post_gain_process_mc）

判据（每条路径都跑 A/B 两组）：
    A. 限幅器 ON  + post.gain=+12dB + threshold=-6dBFS → 输出峰值 ≤ 门限
       （证明限幅器在 post gain 之后，确实兜住了）
    B. 限幅器 OFF + 同样 post.gain                    → 输出峰值显著高于门限
       （反向验证：若 post gain 被排到限幅器之后，A 必然失败而 B 仍然成立
        → 门禁非空转。若哪天有人把 post gain 挪到限幅器之后，A 会转红。）

对照组（立体声 / 离散多声道额外做精确比例核对）：
    C. 限幅器 OFF 时输出峰值 == 输入峰值 × 10^(post.gain/20)（误差 < 0.1 dB）
    D. 限幅器 ON 时 gr.limiter > 0（限幅器确实动手了，不是直通）

门禁不变量本身此前**只写在代码注释里，无任何测试执行**——与本仓反复出现的
「契约写在标志/注释里但无人执行」同型（见 10-28 预设系统复检 P1）。
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

IN_AMP = 0.2          # 稳态直流（比正弦更可控：ISP 真峰检波对常量无过冲）
POST_DB = 12.0        # 总输出增益上推
THRESH_DB = -6.0      # 限幅门限（dBFS）
CEILING = 10.0 ** (THRESH_DB / 20.0)          # 0.501187
BOOSTED = IN_AMP * 10.0 ** (POST_DB / 20.0)  # 0.796215

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


def dc_signal(frames, ch, amp=IN_AMP):
    return [amp] * (frames * ch)


def peak_of(data):
    return max(abs(x) for x in data) if data else 0.0


def db(x):
    return 20.0 * math.log10(max(1e-12, x))


def settle_and_measure(e, sig, frames, ch, blocks=14):
    """跑若干块让 10ms post_gain 平滑器收敛，返回最后一块的峰值。"""
    out = None
    for _ in range(blocks):
        out = e.process(sig, frames, ch)
    return peak_of(out), out


def run_path(label, ch, mode, binaural=False, exact_ratio=False, amp=IN_AMP):
    """跑一条路径的两组对照，返回 (peak_on, peak_off, gr_db)。"""
    print("\n--- %s（ch=%d, mode=%d, binaural=%s） ---" % (label, ch, mode, binaural))

    # ---- B 组：限幅器关闭（post gain 为纯输出增益） ----
    e = Engine()
    if ch > 2:
        e.set_i("channels.count", ch)
        e.set_i("channels.mode", mode)
    if binaural:
        e.set_i("spatial.enable", 1)
        e.set_i("spatial.binaural", 1)
    e.set_i("limiter.enable", 0)
    e.set_f("post.gain", POST_DB)
    sig = dc_signal(BLOCK, ch, amp)
    peak_off, _ = settle_and_measure(e, sig, BLOCK, ch)
    e.close()

    # ---- A 组：限幅器开启 ----
    e = Engine()
    if ch > 2:
        e.set_i("channels.count", ch)
        e.set_i("channels.mode", mode)
    if binaural:
        e.set_i("spatial.enable", 1)
        e.set_i("spatial.binaural", 1)
    e.set_i("limiter.enable", 1)
    e.set_f("limiter.threshold", THRESH_DB)
    e.set_f("post.gain", POST_DB)
    sig = dc_signal(BLOCK, ch, amp)
    peak_on, _ = settle_and_measure(e, sig, BLOCK, ch)
    rc, gr = e.get_f("gr.limiter")
    e.close()

    # A：限幅器 ON 时输出峰值必须被门限兜住
    check("%s: 限幅器 ON 时输出峰值 ≤ 门限 (%.4f ≤ %.4f)" % (label, peak_on, CEILING),
          peak_on <= CEILING * 1.02,
          "peak_on=%.6f, ceiling=%.6f" % (peak_on, CEILING))

    # A'：限幅器 ON 时不得远低于门限（否则说明限幅器没在工作 = 空转）
    check("%s: 限幅器 ON 时输出确实被压到门限附近 (≥ 门限×0.85)" % label,
          peak_on >= CEILING * 0.85,
          "peak_on=%.6f, ceiling=%.6f" % (peak_on, CEILING))

    # B（反向验证）：限幅器 OFF 时必须显著超过门限，否则 A 组无意义
    check("%s: 限幅器 OFF 时输出显著超过门限 (%.4f > %.4f)" %
          (label, peak_off, CEILING),
          peak_off > CEILING * 1.25,
          "peak_off=%.6f, ceiling=%.6f" % (peak_off, CEILING))

    if exact_ratio:
        expected = amp * 10.0 ** (POST_DB / 20.0)
        err = abs(db(peak_off) - db(expected))
        check("%s: 限幅器 OFF 时 post gain 精确生效 (%.4f dB ≈ %.4f dB)" %
              (label, db(peak_off), db(expected)),
              err < 0.1, "err=%.4f dB" % err)

        check("%s: 限幅器 ON 时 gr.limiter > 0 (限幅器确实动手)" % label,
              rc == 0 and gr > 0.5, "gr=%.3f dB, rc=%d" % (gr, rc))

    print("    实测：peak_on=%.6f  peak_off=%.6f  gr=%.3f dB  (ceiling=%.6f)" %
          (peak_on, peak_off, gr, CEILING))
    return peak_on, peak_off, gr


print("=== ADR-010 不变量：post gain 在限幅器之前，限幅器是链尾最后一道门 ===")
print("参数：输入 %.3f 恒定直流, post.gain=+%.1f dB, limiter.threshold=%.1f dBFS"
      % (IN_AMP, POST_DB, THRESH_DB))
print("门限 = %.6f ；限幅关闭时理论输出 = %.6f" % (CEILING, BOOSTED))

# [1] 立体声（post gain 在 vendor stage_output 内）
run_path("立体声", 2, 0, exact_ratio=True)

# [4] 离散多声道（post_gain_process_mc）
run_path("离散多声道 8ch", 8, 1, exact_ratio=True)

# [2] 矩阵混音（下混 → 立体声链 → 上混）
run_path("矩阵混音 6ch", 6, 0, amp=0.5)

# [3] 双耳空间（HRTF 渲染 → 立体声链）
run_path("双耳空间 6ch", 6, 0, binaural=True, amp=0.5)


print("\n=== [5] 逐声道 trim 同样排在限幅器之前（多声道路径） ===")
e = Engine()
e.set_i("channels.count", 8)
e.set_i("channels.mode", 1)
e.set_i("limiter.enable", 1)
e.set_f("limiter.threshold", THRESH_DB)
e.set_f("post.gain", POST_DB)
e.set_f("post.gain.c3", 6.0)   # LFE 额外 +6dB
sig = dc_signal(BLOCK, 8)
peak_on, _ = settle_and_measure(e, sig, BLOCK, 8)
e.close()
check("LFE trim(+6dB) 后仍被限幅门限兜住 (%.4f ≤ %.4f)" % (peak_on, CEILING),
      peak_on <= CEILING * 1.02, "peak_on=%.6f" % peak_on)


print("\n=== [6] 限幅门限本身生效（无 post gain 时输出不得超过门限） ===")
e = Engine()
e.set_i("limiter.enable", 1)
e.set_f("limiter.threshold", THRESH_DB)
e.set_f("post.gain", 0.0)
sig = dc_signal(BLOCK, 2, 0.8)   # 输入本身就超门限
peak_on, _ = settle_and_measure(e, sig, BLOCK, 2)
e.close()
check("输入超门限时输出被压到门限 (%.4f ≤ %.4f)" % (peak_on, CEILING),
      peak_on <= CEILING * 1.02, "peak_on=%.6f" % peak_on)


if FAIL:
    print("\nFAIL: %d 项断言未通过" % len(FAIL))
    for f in FAIL:
        print("  - " + f)
    sys.exit(1)
print("\nlimiter_final_gate: all checks passed")
sys.exit(0)
