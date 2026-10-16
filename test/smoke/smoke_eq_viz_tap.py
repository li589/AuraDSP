#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_eq_viz_tap.py — 均衡器面板的背景谱必须是「EQ 输出」而不是整链输出

背景（用户反馈「效果 → 多段图形均衡器 中的这个图是显示的全链输出频谱，
应该显示均衡器输出的频谱」）：

  viz 帧里的 spectrum 取自 process_stereo_chain 的**最终输出**，EQ 之后的
  混响 / 卷积 / Freeverb / 插件全都混在里面。拿它当 EQ 面板背景柱，用户看到的
  根本不是均衡器输出的东西。

  EQ 位于 libjamesdsp 的单体链内部（processFloatMultiplexd 一次跑完全链），
  拿不到它的输出 tap。于是本改动在链入口（EQ 输入）加了一条 tap，
  下发 eq_in_spectrum，由 UI 按 |Y(f)| = |X(f)|·|H_eq(f)| 合成输出谱。

本用例直接验证那条合成公式在真实链上成立：
  对每个频带，  dBFS(整链输出)  ==  dBFS(EQ 输入) + H_eq(频带中心)
容差取 4 dB：带内取的是 max(mag)，而 H 在带内并非严格常数（EQ 响应逐频点变化），
这是该口径下的固有残差，不是实现误差。

若改回旧行为（拿整链输出冒充 EQ 输出），本用例会因「输入谱不含 EQ 之前的效果、
无法解释输出」而失败——即它能钉住这个回归。
"""
import ctypes
import math
import os
import random
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")
SRC = os.path.join(ROOT, "engine", "engine_internal.h")

FS = 48000.0
BLOCK = 1024
BANDS = 32
DB_SPAN = 75.0          # 引擎 -75..0 dBFS -> [0,1]
RESP_POINTS = 129
TOL_DB = 4.0

# 只在中频段断言：低频侧链内有 DC blocker，超高频侧受窗旁瓣与 band 边缘影响，
# 都不适合用来验证"输入 + 响应 = 输出"这条关系。
BAND_LO, BAND_HI = 8, 27

# 平滑缓变的 EQ 形状：刻意避开窄峰/窄凹，否则 H 在单个频带内的跨度本身就会
# 超过容差，测的就不是合成对不对而是频带划分粗不粗。
CURVE = "60:9;300:0;1000:-9;8000:0;16000:9"


def load_band_edges():
    """从 C++ 源码里抠 kBandEdges，避免与 Dart/引擎两边各抄一份而漂移。"""
    with open(SRC, encoding="utf-8", errors="replace") as f:
        text = f.read()
    m = re.search(r"kBandEdges\[AURADSP_VIZ_BANDS \+ 1\]\s*=\s*\{(.*?)\}",
                  text, re.S)
    if not m:
        print("[FAIL] 源码里找不到 kBandEdges 定义")
        return None
    body = re.sub(r"//[^\n]*", "", m.group(1))
    vals = [float(v) for v in re.findall(r"\d+(?:\.\d+)?", body)]
    if len(vals) != BANDS + 1:
        print("[FAIL] kBandEdges 解析出 %d 个值，期望 %d" % (len(vals), BANDS + 1))
        return None
    return vals


class VizFrame(ctypes.Structure):
    _fields_ = [
        ("seq", ctypes.c_uint64),
        ("timestamp_ms", ctypes.c_double),
        ("spectrum", ctypes.c_float * BANDS),
        ("eq_in_spectrum", ctypes.c_float * BANDS),
        ("level_l_dbfs", ctypes.c_float),
        ("level_r_dbfs", ctypes.c_float),
        ("stage_levels_l", ctypes.c_float * 32),
        ("stage_levels_r", ctypes.c_float * 32),
    ]


def main() -> int:
    edges = load_band_edges()
    if edges is None:
        return 1

    dll = ctypes.CDLL(DLL)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_set_param.restype = ctypes.c_int
    dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_last_error.restype = ctypes.c_char_p
    dll.auradsp_last_error.argtypes = [ctypes.c_void_p]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_viz_read.restype = ctypes.c_uint32
    dll.auradsp_viz_read.argtypes = [ctypes.c_void_p,
                                     ctypes.POINTER(VizFrame), ctypes.c_uint32]
    dll.auradsp_probe_eq_response.restype = ctypes.c_int
    dll.auradsp_probe_eq_response.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_double,
        ctypes.POINTER(ctypes.c_float)]

    h = ctypes.c_void_p(dll.auradsp_create(FS, BLOCK))
    if not h:
        print("[FAIL] auradsp_create")
        return 1

    # ---- 实测 EQ 响应（与 UI 走同一个纯函数） ----
    resp = (ctypes.c_float * RESP_POINTS)()
    rc = dll.auradsp_probe_eq_response(int(FS), CURVE.encode(), RESP_POINTS,
                                       20000.0, resp)
    if rc != 0:
        print("[FAIL] auradsp_probe_eq_response rc=%d" % rc)
        dll.auradsp_destroy(h)
        return 1

    def resp_db_at(hz):
        t = math.log(hz / 20.0) / math.log(20000.0 / 20.0)
        t = max(0.0, min(1.0, t))
        x = t * (RESP_POINTS - 1)
        i = int(x)
        if i >= RESP_POINTS - 1:
            return float(resp[RESP_POINTS - 1])
        f = x - i
        return resp[i] * (1 - f) + resp[i + 1] * f

    # ---- 下发曲线并使能 EQ ----
    cb = CURVE.encode("utf-8")
    pb = (ctypes.c_char * len(cb)).from_buffer_copy(cb)
    for name, val in (("eq.curve", pb), ):
        rc = dll.auradsp_set_param(h, name.encode(), val, len(cb))
        if rc != 0:
            print("[FAIL] %s rc=%d %s" % (name, rc,
                                         dll.auradsp_last_error(h)))
            dll.auradsp_destroy(h)
            return 1
    rc = dll.auradsp_set_param(h, b"eq.enable",
                               ctypes.byref(ctypes.c_int32(1)), 4)
    if rc != 0:
        print("[FAIL] eq.enable %s" % dll.auradsp_last_error(h))
        dll.auradsp_destroy(h)
        return 1

    # ---- 灌白噪声（宽带平稳，最适合验证逐频点乘法定理） ----
    rng = random.Random(1234)
    buf_in = (ctypes.c_float * (BLOCK * 2))()
    buf_out = (ctypes.c_float * (BLOCK * 2))()
    acc_out = [0.0] * BANDS
    acc_in = [0.0] * BANDS
    frames = 0
    vb = (VizFrame * 8)()
    for n in range(900):
        for i in range(BLOCK * 2):
            buf_in[i] = rng.uniform(-0.3, 0.3)
        dll.auradsp_process(h, buf_in, buf_out, BLOCK)
        if n % 8 == 0:
            got = dll.auradsp_viz_read(h, vb, 8)
            if got > 0:
                fr = vb[got - 1]
                for b in range(BANDS):
                    acc_out[b] += fr.spectrum[b]
                    acc_in[b] += fr.eq_in_spectrum[b]
                frames += 1
    dll.auradsp_destroy(h)

    if frames < 5:
        print("[FAIL] 只取到 %d 帧 viz，样本不足" % frames)
        return 1

    def to_db(v):
        return max(0.0, min(1.0, v)) * DB_SPAN - DB_SPAN

    print("frames=%d  eq.curve=%s" % (frames, CURVE))
    print("band   centerHz   in(dBFS)  out(dBFS)   H(dB)   resid")
    worst = 0.0
    worst_band = -1
    for b in range(BAND_LO, BAND_HI):
        hz = math.sqrt(edges[b] * edges[b + 1])
        vin = acc_in[b] / frames
        vout = acc_out[b] / frames
        if vin <= 0.002 or vout <= 0.002:
            continue                      # 该带无有效信号，不参与判定
        d_in, d_out = to_db(vin), to_db(vout)
        hq = resp_db_at(hz)
        resid = d_out - (d_in + hq)
        print("%4d  %8.1f  %8.2f  %8.2f  %6.2f  %+6.2f"
              % (b, hz, d_in, d_out, hq, resid))
        if abs(resid) > abs(worst):
            worst, worst_band = resid, b

    # --- 断言 1：EQ 输入 tap 真的有数据（接线通了） ---
    peak_in = max(acc_in) / frames
    peak_out = max(acc_out) / frames
    if peak_in <= 0.05:
        print("[FAIL] eq_in_spectrum 全线接近 0（peak=%.4f）：EQ 输入 tap 没生效"
              % peak_in)
        return 1

    # --- 断言 2：合成公式成立 ---
    if abs(worst) > TOL_DB:
        print("[FAIL] 合成不成立：band%d 残差 %.2f dB（容差 %.1f dB）"
              % (worst_band, worst, TOL_DB))
        print("      dBFS(out) 必须 ≈ dBFS(eq_in) + H_eq，否则 UI 合成出的"
              "「EQ 输出频谱」是错的")
        return 1

    print("\nOK: eq_in peak=%.3f out peak=%.3f, 最大残差 %.2f dB @band%d"
          % (peak_in, peak_out, worst, worst_band))
    print("PASS: 整链输出 == EQ 输入 + 实测响应，UI 合成公式成立")
    return 0


if __name__ == "__main__":
    sys.exit(main())