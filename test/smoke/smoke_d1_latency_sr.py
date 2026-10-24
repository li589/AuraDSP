# -*- coding: utf-8 -*-
"""smoke_d1_latency_sr.py — D1 门禁：延迟表口径（帧数 vs 毫秒）。

审查 D1：`kLatComp {2, 85.0f}` 的 85ms 是「FFTSIZE_DRS/2 = 4096 帧 @48k」的
换算结果，但表里当成了**与采样率无关的毫秒常量**：
  · 96k 下 comp 的真实附加延迟是 42.67ms，引擎却报 85ms（2 倍高估）；
  · 192k 下真实 21.33ms，报 85ms（4 倍）；
  · `kLatArbMag {2, 2.67f}` 更糟——arbmag 的分块卷积延迟等于**单块帧数**
    （由驱动块长决定，常见 512/1024），2.67ms 只是 128 帧 @48k 的巧合值。
同一 bug 在 Dart 侧已修（state.dart 明确「不再有预设延迟数值，全走 probe
实测」），但引擎 API 仍对外返回 48k 口径的名义值——任何第三方/自研调用方
读到就是错的。这两张皮必须合上。

修法：`LatencyItem` 加 `frames` 字段（frames>0 = 结构性帧数，按当前采样率
换算；frames=0 = 与采样率无关的名义毫秒），换算统一走 `LatencyMs()`。

本测试四层：
  [A] 源码不变式：LatencyItem 三字段；compute_latency 不得再直接累加 `.ms`；
      kLatComp 必须是 4096 帧而不是 85.0f
  [B] 行为（核心）：同一 comp 开关下，48k/96k/192k 的 get_latency_ms 必须
      按 1 : 1/2 : 1/4 缩放（pre-fix 三者全 85.0ms，比值恒 1:1:1 → 判红）
  [C] 名义值与采样率无关：limiter 的 2ms 在 96k 下仍是 2.0
  [D] 叠加口径自洽：48k comp+limiter = 85.33+2.0
"""
import ctypes
import os
import re
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
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


print("=== [A] 源码不变式 ===")
hdr = strip_comments(read(INTERNAL_H))
# LatencyItem 必须是三字段（tier / frames / ms）
m = re.search(r"struct\s+LatencyItem\s*\{([^}]*)\}", hdr)
body = m.group(1) if m else ""
check("LatencyItem has 3 fields (tier/frames/ms)",
      m is not None and "frames" in body and body.count(";") >= 3, body.strip()[:60])
# comp 必须是结构性帧数 4096，而不是 85.0f
comp = re.search(r"kLatComp\s*\{([^}]*)\}", hdr)
comp_args = [x.strip() for x in comp.group(1).split(",")] if comp else []
check("kLatComp is 4096 frames (not a ms constant)",
      len(comp_args) == 3 and comp_args[1].startswith("4096"),
      ",".join(comp_args))
# arbmag 必须彻底退出表（延迟=块长，写任何常量都错）。这里断言"条目不存在"，
# 而不是"没有 2.67 这个数字"——后者对"整条删掉"和"改成别的错值"都放行。
check("kLatArbMag absent from table (latency = block length)",
      "kLatArbMag" not in hdr)

chain = strip_comments(read(CHAIN_CPP))
check("compute_latency uses LatencyMs()", "LatencyMs(" in chain)
check("compute_latency no direct .ms accumulation",
      re.search(r"\+=\s*kLat\w+\.ms", chain) is None)
check("compute_latency converts arbmag by block length",
      "blockSize" in chain and "FramesToMs" in chain)

print("\n=== [B] 行为：comp 延迟必须随采样率缩放 ===")
b = ctypes.CDLL(DLL)
b.auradsp_create.restype = ctypes.c_void_p
b.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
b.auradsp_destroy.restype = None
b.auradsp_destroy.argtypes = [ctypes.c_void_p]
b.auradsp_set_param.restype = ctypes.c_int
b.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p,
                                ctypes.c_uint32]
b.auradsp_get_latency_ms.restype = ctypes.c_double
b.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]


def make(sr, blk=1024):
    h = b.auradsp_create(ctypes.c_float(sr), blk)
    return h if h else None


def set_bool(h, pid, v):
    iv = ctypes.c_int32(1 if v else 0)
    return b.auradsp_set_param(h, pid.encode(), ctypes.byref(iv), 4)


results = {}
for sr, want in ((48000, 85.33), (96000, 42.67), (192000, 21.33)):
    h = make(sr)
    if not h:
        check(f"create engine @{sr}", False)
        continue
    try:
        # 注意：limiter 默认开启（P-012 语义：总开关默认 1，关时只做 postGain），
        # 会固定贡献 2.0ms 名义值。用「基线差值」量 comp 的真实分量，
        # 否则 87.33 = 85.33+2 会被误判成"不随采样率缩放"。
        set_bool(h, "comp.enable", False)
        set_bool(h, "limiter.enable", False)
        base = b.auradsp_get_latency_ms(h)
        rc = set_bool(h, "comp.enable", True)
        ms = b.auradsp_get_latency_ms(h) - base
        results[sr] = ms
        # 4096 帧 / sr * 1000
        check(f"comp latency @{int(sr/1000)}k ≈ {want}ms", abs(ms - want) < 1.0,
              f"got {ms:.2f}ms (base={base:.2f}, rc={rc})")
    finally:
        b.auradsp_destroy(h)

if len(results) == 3:
    # pre-fix 时三者相等（全 85.0）→ 这两条必判红
    check("96k is half of 48k", abs(results[96000] * 2 - results[48000]) < 1.0,
          f"48k={results[48000]:.2f} 96k={results[96000]:.2f}")
    check("192k is quarter of 48k", abs(results[192000] * 4 - results[48000]) < 2.0,
          f"48k={results[48000]:.2f} 192k={results[192000]:.2f}")

print("\n=== [C] 名义值与采样率无关（limiter 2ms） ===")
for sr in (48000, 96000):
    h = make(sr)
    if not h:
        continue
    try:
        set_bool(h, "comp.enable", False)
        set_bool(h, "limiter.enable", True)
        ms = b.auradsp_get_latency_ms(h)
        check(f"limiter nominal 2ms @{int(sr/1000)}k", abs(ms - 2.0) < 0.01,
              f"got {ms:.3f}ms")
    finally:
        b.auradsp_destroy(h)

print("\n=== [D] 叠加口径自洽（48k comp+limiter） ===")
h = make(48000)
if h:
    try:
        set_bool(h, "comp.enable", True)
        set_bool(h, "limiter.enable", True)
        ms = b.auradsp_get_latency_ms(h)
        check("48k comp+limiter ≈ 87.33ms", abs(ms - 87.33) < 1.0, f"got {ms:.2f}ms")
    finally:
        b.auradsp_destroy(h)

print()
if fails:
    print(f"D1 FAILURES: {fails}")
    sys.exit(1)
print(f"D1 ALL PASSED ({passes} checks)")
