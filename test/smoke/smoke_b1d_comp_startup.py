# -*- coding: utf-8 -*-
"""smoke_b1d_comp_startup.py — B1-d 门禁：comp 启动段不得原声直通。

缺陷（实测标定，推翻了 D7 当时的一条结论）：
  FFTCompanderProcessSamples 的抽干循环条件是 `mOutputBufferCount > 0`，管线
  第一次产出之前该计数为 0，整个循环不执行，于是输出缓冲里仍是**未处理的
  输入**（调用方 in==out 原地处理）。后果两条：
    ① 启动段最多 ovpLen 个样本原声直通，与稍后产出的处理流在时间上错开叠加
       → 双声/梳状；
    ② 块长与 hop(ovpLen) 不整除时，「已产出-已交付」必须永久落后一个相位量，
       旧实现靠 ① 的"泄漏"意外维持平衡，所以泄漏**不是一次性的**：实测 441 帧
       块 7 次、500 帧块 2 次，周期性复发。

D7 当时把「块长 < ovpLen 就整块直通、延迟报 0」写进了门禁，那是测量假象：
脉冲放在第 8 帧（首块内），测到的是首个 hop 的启动段。把脉冲放到第 50 块之后，
48k/blk=256 位移 3840 帧、blk=512 位移 3584 帧——块小不但不直通，反而多延迟。

修复模型（可证）：显式做相位落后 D = ovpLen - gcd(ovpLen, blockLen)，
启动先以静音交付 D 个样本（OLA 爬升段本就是静音），此后
`可用输出 = D + ovpLen*floor(I/ovpLen) - I = D - (I mod ovpLen) >= 0` 恒成立。
抽干仍不足时补静音，绝不把未处理输入留在输出里。

本测试五层：
  [A] 源码不变式（缺额分支 / 静音兜底 / 完整块长取 gcd / Init 清零 OLA 反馈态）
  [B] 启动段 = 静音（DC 输入下前 D 个输出必须是精确 0，缺陷版是 0.5）
  [C] 稳态无饥饿（DC 输入下首活之后不得再出现精确 0 —— 补零版饥饿会打洞）
  [D] 脉冲位移 == fftLen-ovpLen + D（48k 逐帧精确；ASRC 率按 ms 容差）
  [E] 上报延迟 == 实测延迟（不与 [D] 重复：这里查的是"报表"而非"管线"）
"""
import ctypes
import os
import sys
from math import gcd

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

DYNAMIC_C = os.path.join(ROOT, "engine", "legacy", "jdsp", "Effects", "dynamic.c")
HEADER_H = os.path.join(ROOT, "engine", "legacy", "jdsp", "jdsp_header.h")
INTERNAL_H = os.path.join(ROOT, "engine", "engine_internal.h")
CHAIN_CPP = os.path.join(ROOT, "engine", "chain", "engine_chain.cpp")

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
    """取 name(...) { ... } 的函数体（花括号配对，零正则转义风险）。"""
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


# 各 tf 的 (fftLen, hop=ovpLen, frames=fftLen-hop)
PROF = {0: (2048, 256, 1792), 1: (4096, 512, 3584), 2: (4096, 512, 2048)}


def deficit(hop, blk):
    return hop - gcd(hop, blk)


# ---------------------------------------------------------------- [A] 源码
print("\n=== [A] 源码不变式：缺额 + 静音兜底 + 完整块长取 gcd + Init 清零 ===")

dyn_src = read(DYNAMIC_C)
hdr_src = read(HEADER_H)

body_ps = func_body(dyn_src, "FFTCompanderProcessSamples")
check("[A1] FFTCompanderProcessSamples 存在", bool(body_ps))
check("[A2] ProcessSamples 有启动缺额分支（mOutputDeficit）",
      "mOutputDeficit" in body_ps)
check("[A3] ProcessSamples 首次调用即定缺额（< 0 判定）",
      "mOutputDeficit < 0" in body_ps or "mOutputDeficit<0" in body_ps)
check("[A4] ProcessSamples 单次至多推进一个 hop（防 FIFO 越界）",
      "c > cm->ovpLen" in body_ps or "> cm->ovpLen" in body_ps)

body_chunk = func_body(dyn_src, "comp_process_chunk")
check("[A5] comp_process_chunk 存在（填充→缺额→抽干）", bool(body_chunk))
check("[A6] 抽干不足时补静音（不是保留输入）",
      "comp_zero_pairs" in body_chunk and "inSampleCount - outSampleCount" in body_chunk)
check("[A7] 缺额段写静音",
      "mOutputDeficit > 0" in body_chunk and "comp_zero_pairs" in body_chunk)
# 旧语义的痕迹：return outSampleCount 表示"没写满就返回"，正是直通的根源
check("[A8] 不再有 `return outSampleCount` 的半截返回",
      "return outSampleCount" not in body_ps)

body_def = func_body(dyn_src, "CompressorStartupDeficit")
check("[A9] CompressorStartupDeficit 用完整块长取 gcd（不得先裁到 hop）",
      "comp_gcd_u(ovpLen, blockLen)" in body_def.replace(" ", " ")
      and "min(" not in body_def,
      repr(body_def.strip()[:120]))

body_proc = func_body(dyn_src, "CompressorProcess")
check("[A10] CompressorProcess 不再预切块（否则缺额按裁剪后块长算错）",
      "min(n - offset" not in body_proc and "FFTCompanderProcessSamples(cm, jdsp->tmpBuffer[0]" in body_proc)

body_init = func_body(dyn_src, "FFTCompanderInit")
check("[A11] Init 清零 mInput（复用影子槽不得带上一份音频）",
      "memset(cm->mInput[0]" in body_init and "memset(cm->mInput[1]" in body_init)
check("[A12] Init 清零 mOverlapStage2dash（OLA 反馈态）",
      "memset(cm->mOverlapStage2dash[0]" in body_init
      and "memset(cm->mOverlapStage2dash[1]" in body_init)
check("[A13] Init 把缺额置 -1（待首次调用确定）",
      "mOutputDeficit = -1" in body_init)

check("[A14] FFTCompander 结构含 mOutputDeficit 字段",
      "mOutputDeficit" in hdr_src)
maxbuf = None
for line in hdr_src.splitlines():
    if line.strip().startswith("#define MAX_OUTPUT_BUFFERS_DRS"):
        maxbuf = int(line.split()[-1])
check("[A15] MAX_OUTPUT_BUFFERS_DRS >= 4（缺额策略的队列峰值 = 2，留余量）",
      maxbuf is not None and maxbuf >= 4, f"值={maxbuf}")

chain_src = read(CHAIN_CPP)
body_lat = func_body(chain_src, "compute_latency")
check("[A16] compute_latency 按缺额修正 comp 延迟",
      "CompressorStartupDeficit" in body_lat)
check("[A17] compute_latency 不再有 `workBlk >= ovpLen` 的块长门槛",
      "workBlk >= (size_t)cp.ovpLen" not in body_lat)
int_src = read(INTERNAL_H)
check("[A18] kCompLatProfile 注释已撤销「攒不满就直通」的错误结论",
      "攒不满 mInputSamplesNeeded 就一帧都不产" not in int_src)

# ---------------------------------------------------------------- ctypes
b = ctypes.CDLL(DLL)
b.auradsp_create.restype = ctypes.c_void_p
b.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
b.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                              ctypes.POINTER(ctypes.c_float), ctypes.c_int]
b.auradsp_set_param.restype = ctypes.c_int
b.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
b.auradsp_get_latency_ms.restype = ctypes.c_double
b.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]
b.auradsp_destroy.argtypes = [ctypes.c_void_p]


def set_int(h, pid, v):
    iv = ctypes.c_int32(v)
    return b.auradsp_set_param(h, pid.encode(), ctypes.byref(iv), 4)


def render(sr, blk, tf, fill, pulse_at=None, seconds=2.0):
    """跑一段音频，返回 (上报ms, 输入, 输出, 总样本数)。"""
    h = b.auradsp_create(ctypes.c_float(sr), blk)
    if not h:
        return None
    try:
        set_int(h, "comp.enable", 1)
        set_int(h, "comp.tfresolution", tf)
        rep = b.auradsp_get_latency_ms(h)
        blocks = max(500, int(sr * seconds) // blk)
        total = blk * blocks
        inp = (ctypes.c_float * (total * 2))()
        out = (ctypes.c_float * (total * 2))()
        if fill is not None:
            for i in range(total):
                inp[i * 2] = fill
                inp[i * 2 + 1] = fill
        if pulse_at is not None:
            inp[pulse_at * 2] = 0.9
            inp[pulse_at * 2 + 1] = 0.9
        pos = 0
        for _ in range(blocks):
            b.auradsp_process(h,
                              ctypes.cast(ctypes.byref(inp, pos * 8), ctypes.POINTER(ctypes.c_float)),
                              ctypes.cast(ctypes.byref(out, pos * 8), ctypes.POINTER(ctypes.c_float)),
                              blk)
            pos += blk
        return rep, inp, out, total
    finally:
        b.auradsp_destroy(h)


# ------------------------------------------------- [B] 启动段必须是静音
print("\n=== [B] 启动段原声直通（DC=0.5 输入，前 D 个输出必须精确 0） ===")
for blk in (128, 192, 256, 441, 480, 512):
    for tf in (0, 1, 2):
        hop = PROF[tf][1]
        D = deficit(hop, blk)
        r = render(48000, blk, tf, 0.5)
        if r is None:
            check(f"48k blk={blk} tf={tf} create", False)
            continue
        _rep, _inp, out, total = r
        if D == 0:
            # 无缺额时该层判定为空转，改用「首活位置不早于 frames/4」兜一层
            first = next((i for i in range(total) if abs(out[i * 2]) > 1e-7), -1)
            check(f"48k blk={blk} tf={tf} D=0（无缺额，跳过启动断言）", True,
                  f"首活={first}")
            continue
        peak = max(abs(out[i * 2]) for i in range(D))
        check(f"48k blk={blk} tf={tf} 启动段 {D} 样本为静音",
              peak == 0.0, f"峰值={peak:.6f}（缺陷版应 ≈0.5）")

# --------------------------------------------- [C] 稳态不得出现饥饿洞
print("\n=== [C] 稳态无饥饿（DC 输入下首活后不得再出现精确 0） ===")
for blk in (128, 192, 441, 480, 500, 512, 1024):
    hop = 512
    r = render(48000, blk, 1, 0.5)
    if r is None:
        check(f"48k blk={blk} create", False)
        continue
    _rep, _inp, out, total = r
    first = next((i for i in range(total) if abs(out[i * 2]) > 1e-7), -1)
    holes = sum(1 for i in range(first + 1, total) if out[i * 2] == 0.0)
    check(f"48k blk={blk} tf=1 首活后无静音洞", holes == 0,
          f"首活={first} 洞数={holes}")

# ------------------------------------------------- [D] 脉冲位移 == frames+D
print("\n=== [D] 脉冲位移 == fftLen-ovpLen + D（48k 逐帧精确） ===")
for blk in (128, 192, 256, 384, 441, 480, 512, 1024):
    for tf in (0, 1, 2):
        fftLen, hop, frames = PROF[tf]
        D = deficit(hop, blk)
        src = 60 * blk + 8
        r = render(48000, blk, tf, 0.0, pulse_at=src)
        if r is None:
            check(f"48k blk={blk} tf={tf} create", False)
            continue
        _rep, _inp, out, total = r
        peak, at = 0.0, -1
        for i in range(total):
            v = abs(out[i * 2])
            if v > peak:
                peak, at = v, i
        want = frames + D
        check(f"48k blk={blk} tf={tf} 位移={at - src}（期望 {want}）",
              at - src == want, f"实测={at - src}")

# ------------------------------------------------- [E] 上报 == 实测
print("\n=== [E] 上报延迟 == 实测延迟（ASRC 率按 ms 容差） ===")
CASES = [
    (48000, 128, 1), (48000, 256, 1), (48000, 441, 1), (48000, 480, 1),
    (48000, 512, 1), (48000, 1024, 1),
    (48000, 128, 0), (48000, 441, 0), (48000, 512, 2), (48000, 441, 2),
    (96000, 512, 1), (96000, 1024, 1), (192000, 2048, 1), (192000, 1024, 0),
]
worst = 0.0
for sr, blk, tf in CASES:
    fftLen, hop, frames = PROF[tf]
    ratio = 48000.0 / sr
    work = int(round(blk * ratio))
    D = deficit(hop, work)
    want_ms = (frames + D) * 1000.0 / 48000.0
    src = 60 * blk + 8
    r = render(sr, blk, tf, 0.0, pulse_at=src)
    if r is None:
        check(f"{sr}/{blk}/tf{tf} create", False)
        continue
    rep, _inp, out, total = r
    peak, at = 0.0, -1
    for i in range(total):
        v = abs(out[i * 2])
        if v > peak:
            peak, at = v, i
    meas_ms = (at - src) * 1000.0 / sr
    d = abs(rep - meas_ms)
    worst = max(worst, d)
    if sr == 48000:
        check(f"{sr}/blk={blk}/tf{tf} 上报==实测（且==(frames+D)/fs）",
              d < 1e-9 and abs(rep - want_ms) < 1e-6,
              f"rep={rep:.4f} meas={meas_ms:.4f} want={want_ms:.4f}")
    else:
        check(f"{sr}/blk={blk}/tf{tf} 上报==实测（ASRC 容差 0.15ms）",
              d < 0.15, f"rep={rep:.4f} meas={meas_ms:.4f} d={d:.4f}")
check("上报-实测最差偏差 < 0.15ms", worst < 0.15, f"worst={worst:.4f}ms")

print()
if fails:
    print(f"B1-d FAILURES ({len(fails)}): {fails}")
    sys.exit(1)
print(f"B1-d ALL PASSED ({passes} checks)")
