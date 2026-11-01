# -*- coding: utf-8 -*-
"""smoke_d7_asrc_consistency.py — D7 门禁：ASRC taps 统一 + 延迟口径如实。

审查 D7（P1）：采样率支持与 ASRC 三处不一致。
  ① jdspController.c 的 ASRC 抽头数：JamesDSPInit 用 64、JamesDSPSetSampleRate
     用 32 —— 同一设备"冷启动即 96k"与"48k 起来再热切"走不同阶数的滤波器，
     频响与群延迟都差一倍。两处都是函数内局部常量，谁也看不出对方。
  ② 延迟表完全没有 ASRC 的分量。
  ③ 结构性帧数被当成"按设备采样率换算"，但 ASRC 启用时 DSP 跑在 48k/44.1k
     工作域 —— 96k 下低估 2 倍。

落地过程中另外实测出两处比报告更硬的事实（本门禁一并锁住）：
  ④ comp 的延迟不是固定 4096 帧，而是 fftLen-ovpLen，随 tfresolution 变。
     （当时还写了「块长不足 ovpLen 就整块直通」——那条是测量假象，脉冲放在
     首块内才看到 0ms；已由 B1-d 推翻并改由 smoke_b1d_comp_startup.py 锁块长口径）
  ⑤ limiter 的 2.0ms 名义值在默认配置（lookahead=0）下是**高估**，真实 0ms；
     开前瞻时是 1.5ms 而不是 2.0ms。

本测试六层：
  [A] 源码不变式（taps 单点定义 / comp 剖面表 / 工作域换算 / ASRC 项接线）
  [B] ASRC 实际在跑（96k/192k 输出有限且非静音，重采样没被改坏）
  [C] comp 延迟随 tfresolution 变，且按启动缺额修正块长相位
  [D] limiter 两种模式的延迟
  [E] ASRC 环形缓冲分量
  [F] 上报值 == 脉冲实测（核心：报表不许骗人）
"""
import ctypes
import math
import os
import re
import sys

# S1（2026-11-01）：仓库根由 __file__ 推导，替代作者机硬编码
# D:\temp_desktop\Proj\JamesDSP（见 test/engine_artifact.py）。
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CANDS = [
    os.environ.get("AURADSP_ENGINE_DLL", ""),
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"),
]
CANDS = [p for p in CANDS if p]
DLL = next((p for p in CANDS if os.path.exists(p)), None)
if not DLL:
    print("SKIP（auradsp_engine.dll 不存在）")
    sys.exit(0)

INTERNAL_H = os.path.join(ROOT, "engine", "engine_internal.h")
CHAIN_CPP = os.path.join(ROOT, "engine", "chain", "engine_chain.cpp")
CTRL_C = os.path.join(ROOT, "engine", "legacy", "jdsp", "jdspController.c")

fails = []
passes = 0


def check(name, ok, note=""):
    global passes
    if ok:
        passes += 1
        print(f"PASS  {name}" + (f"  ({note})" if note else ""))
    else:
        fails.append(name)
        print(f"FAIL  {name}" + (f"  ({note})" if note else ""))


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def func_body(src, name):
    """取出 name(...) { ... } 的函数体（花括号配对）。

    反向验证教训（同 D2 的「断言自己失效」）：全文件搜索 jdsp.fs /
    limiter_lookahead 在 pre-fix 版本里同样能命中（limiter_process_mc 就在
    同一文件），断言会空转。必须把检查限定到 compute_latency 的函数体内。

    刻意不用 re.search 定位：函数名两侧的单词边界要写 \b，而该转义在不同
    工具链里反复被吃掉，改用手写的 find + 花括号配对，零转义风险。
    """
    pos = src.find(name + "(")
    if pos < 0:
        return ""
    i = src.find("{", pos)
    if i < 0:
        return ""
    start, depth = i, 0
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    return ""


def strip_comments(src):
    out, i, n, in_str = [], 0, len(src), False
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


# ---------------- [A] 源码不变式 ----------------
print("=== [A] 源码不变式 ===")
ctrl = strip_comments(read(CTRL_C))
m = re.search(r"#define\s+AURADSP_ASRC_TAPS\s+(\d+)u?", ctrl)
check("AURADSP_ASRC_TAPS defined", m is not None, m.group(0) if m else "")
check("AURADSP_ASRC_TAPS == 64", m is not None and int(m.group(1)) == 64,
      m.group(1) if m else "")
# 旧的函数内局部常量不得复活：它是分叉的载体
check("no local `const unsigned int asrc_taps` remains",
      re.search(r"const\s+unsigned\s+int\s+asrc_taps", ctrl) is None)
calls = re.findall(r"InitIntegerASRCHandler\s*\(([^;]*?)\)\s*;", ctrl)
check("4 ASRC init calls (= 2 paths x 2 channels)", len(calls) == 4, f"n={len(calls)}")
check("all ASRC init calls use AURADSP_ASRC_TAPS",
      len(calls) == 4 and all("AURADSP_ASRC_TAPS" in c for c in calls))

hdr = strip_comments(read(INTERNAL_H))
prof = re.search(r"kCompLatProfile\s*\[[^\]]*\]\s*=\s*\{(.*?)\n\};", hdr, re.S)
prows = re.findall(r"\{\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\}",
                   prof.group(1)) if prof else []
check("kCompLatProfile has 4 tf profiles", len(prows) == 4, f"n={len(prows)}")
prof_map = {int(r[0]): tuple(int(x) for x in r[1:]) for r in prows} if prows else {}
check("kCompLatProfile tf=1 is fftLen4096/ovp512/3584 frames",
      prof_map.get(1) == (4096, 512, 3584), str(prof_map.get(1)))
check("kCompLatProfile tf=3 is time-domain zero latency",
      prof_map.get(3) == (0, 0, 0), str(prof_map.get(3)))
check("kLatComp must NOT come back", "kLatComp" not in hdr)
check("kLatLimiter must NOT come back (mode-dependent)",
      "kLatLimiter" not in hdr)
check("AsrcRingLatencyMs defined", "AsrcRingLatencyMs" in hdr)

chain = strip_comments(read(CHAIN_CPP))
clat = func_body(chain, "compute_latency")
check("compute_latency body extracted", len(clat) > 200, f"{len(clat)} chars")
check("compute_latency reads work sample rate (jdsp.fs)", "jdsp.fs" in clat)
check("compute_latency uses lat_sr for structural frames", "lat_sr" in clat)
check("compute_latency calls AsrcRingLatencyMs", "AsrcRingLatencyMs(" in clat)
check("compute_latency gates comp by ovpLen", "cp.ovpLen" in clat)
check("compute_latency keys limiter on lookahead",
      "limiter_lookahead" in clat and "kLimLookaheadMax" in clat)
# 反过来：不许再用设备率换算结构性帧数
check("no structural item converted with device rate",
      re.search(r"LatencyMs\(\s*kLat\w+\s*,\s*sr\s*\)", clat) is None)

# ---------------- 引擎绑定 ----------------
b = ctypes.CDLL(DLL)
b.auradsp_create.restype = ctypes.c_void_p
b.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
b.auradsp_destroy.restype = None
b.auradsp_destroy.argtypes = [ctypes.c_void_p]
b.auradsp_process.restype = None
b.auradsp_process.argtypes = [ctypes.c_void_p,
                              ctypes.POINTER(ctypes.c_float),
                              ctypes.POINTER(ctypes.c_float),
                              ctypes.c_int]
b.auradsp_set_param.restype = ctypes.c_int
b.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p,
                                ctypes.c_uint32]
b.auradsp_get_latency_ms.restype = ctypes.c_double
b.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]


def set_int(h, pid, v):
    iv = ctypes.c_int32(v)
    return b.auradsp_set_param(h, pid.encode(), ctypes.byref(iv), 4)


def make(sr, blk):
    return b.auradsp_create(ctypes.c_float(sr), blk) or None


def lat(sr, blk, tf=None, la=None, comp=None):
    """建引擎→读上报延迟（不喂音频：走 max_block 回落路径）。"""
    h = make(sr, blk)
    if not h:
        return None
    try:
        if comp is not None:
            set_int(h, "comp.enable", comp)
        if tf is not None:
            set_int(h, "comp.tfresolution", tf)
        if la is not None:
            set_int(h, "limiter.lookahead", la)
        return b.auradsp_get_latency_ms(h)
    finally:
        b.auradsp_destroy(h)


# ---------------- [B] ASRC 确实在跑 ----------------
print("\n=== [B] ASRC 路径实际生效（重采样没被改坏） ===")


def run_pulse(sr, blk, comp=None, tf=None, la=None, lim=None):
    """喂脉冲，返回 (上报ms, 实测脉冲位移ms)。"""
    h = make(sr, blk)
    if not h:
        return None, None
    try:
        if comp is not None:
            set_int(h, "comp.enable", comp)
        if tf is not None:
            set_int(h, "comp.tfresolution", tf)
        if la is not None:
            set_int(h, "limiter.lookahead", la)
        if lim is not None:
            set_int(h, "limiter.enable", lim)
        rep = b.auradsp_get_latency_ms(h)
        blocks = max(400, int(sr * 2) // blk)
        total = blk * blocks
        inp = (ctypes.c_float * (total * 2))()
        out = (ctypes.c_float * (total * 2))()
        inp[8 * 2] = 0.5
        inp[8 * 2 + 1] = 0.5
        pos = 0
        for _ in range(blocks):
            b.auradsp_process(h,
                              ctypes.cast(ctypes.byref(inp, pos * 8),
                                          ctypes.POINTER(ctypes.c_float)),
                              ctypes.cast(ctypes.byref(out, pos * 8),
                                          ctypes.POINTER(ctypes.c_float)), blk)
            pos += blk
        peak, at = 0.0, -1
        for i in range(total):
            v = abs(out[i * 2])
            if v > peak:
                peak, at = v, i
        return rep, (at - 8) * 1000.0 / sr, peak
    finally:
        b.auradsp_destroy(h)


for sr in (96000, 192000):
    blk = 512 * max(1, sr // 48000)
    rep, meas, peak = run_pulse(sr, blk, comp=0, lim=0)
    # 阈值 0.05 而非 0.5：多相 FIR 是低通，把单样本脉冲的能量摊到若干抽头上，
    # 峰值本就随设备率升高而下降（实测 96k 0.16、192k 0.086）。这里只证明
    # "有非静音输出"，不证明幅度无损。
    check(f"{int(sr/1000)}k passthrough produces finite non-silent output",
          rep is not None and meas is not None and math.isfinite(meas) and peak >= 0.05,
          f"peak={peak:.4f}")

# ---------------- [C] comp 延迟剖面（块长口径见 B1-d 门禁） ----------------
print("\n=== [C] comp 延迟 = 工作域帧数，随 tf 变（块长口径已由 B1-d 修正） ===")
TF_EXPECT = {0: 1792 / 48000 * 1000, 1: 3584 / 48000 * 1000,
             2: 2048 / 48000 * 1000, 3: 0.0}
for tf, want in TF_EXPECT.items():
    got = lat(48000, 512, tf=tf, comp=1, la=0)
    check(f"48k tf={tf} comp ≈ {want:.2f}ms", got is not None and abs(got - want) < 0.3,
          f"got {got:.3f}ms" if got is not None else "create failed")

# 旧断言「块长 < ovpLen 就整块直通 → 报 0ms」是**测量假象**（脉冲放在首块内，
# 测到的是首个 hop 的启动段），已被 B1-d 实测推翻：块小时不但不直通，反而因
# 相位不齐多出 D = ovpLen - gcd(ovpLen, blk) 帧。这里改成「按缺额公式报，
# 且块长整除 hop 时等于纯帧数」，块长口径的完整矩阵见 smoke_b1d_comp_startup.py。
from math import gcd as _gcd
for sr, blk in ((48000, 256), (48000, 512), (96000, 512), (96000, 1024),
                (192000, 1024), (192000, 2048)):
    hop = 512
    work_blk = int(round(blk * 48000.0 / sr))
    d = hop - _gcd(hop, work_blk)
    want = (3584 + d) * 1000.0 / 48000.0
    got = lat(sr, blk, tf=1, comp=1, la=0)
    asrc = 0.0 if sr == 48000 else 0.0208
    check(f"{int(sr/1000)}k blk={blk} (work={work_blk}) comp ≈ {want:.2f}ms + asrc",
          got is not None and abs(got - (want + asrc)) < 0.05,
          f"got {got:.3f}ms want {want + asrc:.3f}ms" if got is not None else "create failed")

# ---------------- [D] limiter 两种模式 ----------------
print("\n=== [D] limiter 延迟随 lookahead 模式变（默认 0ms） ===")
for sr in (48000, 96000):
    zero = lat(sr, 512 * max(1, sr // 48000), comp=0, la=0)
    asrc = 0.0208 if sr != 48000 else 0.0
    check(f"{int(sr/1000)}k lookahead=0 → 0ms", zero is not None and abs(zero - asrc) < 0.01,
          f"got {zero:.3f}ms" if zero is not None else "create failed")
    one = lat(sr, 512 * max(1, sr // 48000), comp=0, la=1)
    # la_len = int(1.5ms*fs+0.5)，延迟线实占 la_len-1 帧 → 恒 ~1.48-1.5ms
    check(f"{int(sr/1000)}k lookahead=1 → ~1.5ms (not 2.0)",
          one is not None and abs(one - (1.49 + asrc)) < 0.06,
          f"got {one:.3f}ms" if one is not None else "create failed")

# ---------------- [E] ASRC 环形缓冲分量 ----------------
print("\n=== [E] ASRC 中转环形缓冲分量 ceil(inFs/fs) ===")
for sr in (48000, 96000, 192000):
    got = lat(sr, 512 * max(1, sr // 48000), comp=0, la=0)
    asrc = 0.0 if sr == 48000 else (sr // 48000) / float(sr) * 1000.0
    check(f"{int(sr/1000)}k ASRC ring ≈ {asrc:.4f}ms",
          got is not None and abs(got - asrc) < 0.005,
          f"got {got:.4f}ms" if got is not None else "create failed")

# ---------------- [F] 上报 == 实测（核心） ----------------
print("\n=== [F] get_latency_ms 上报值 == 脉冲实测（报表不许骗人） ===")
CASES = [
    (48000, 512, 1, 0, 1),
    (48000, 512, 1, 1, 1),
    (48000, 512, 0, 0, 1),
    (48000, 512, 2, 0, 1),
    (48000, 512, 3, 0, 1),
    (48000, 256, 1, 0, 1),
    (96000, 1024, 1, 0, 1),
    (96000, 1024, 1, 1, 1),
    (96000, 512, 1, 0, 1),
    (192000, 2048, 1, 0, 1),
    (192000, 2048, 1, 1, 1),
    (44100, 512, 1, 0, 1),
]
worst = 0.0
for sr, blk, tf, la, comp in CASES:
    rep, meas, _peak = run_pulse(sr, blk, comp=comp, tf=tf, la=la)
    if rep is None:
        check(f"{sr}/{blk}/tf{tf}/la{la} create", False)
        continue
    d = abs(rep - meas)
    worst = max(worst, d)
    check(f"{sr}/{blk}/tf{tf}/la{la}: reported == measured",
          d < 0.15, f"rep={rep:.3f} meas={meas:.3f} d={d:.3f}")
check("worst reported-vs-measured deviation < 0.15ms", worst < 0.15, f"worst={worst:.3f}ms")

print()
if fails:
    print(f"D7 FAILURES ({len(fails)}): {fails}")
    sys.exit(1)
print(f"D7 ALL PASSED ({passes} checks)")
