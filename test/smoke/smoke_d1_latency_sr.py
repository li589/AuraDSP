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
# comp 不得再以「固定 4096 帧」的形态留在表里：D7 实测该数字与运行时无关
# （fftLen-ovpLen 随 tfresolution 变），已改为 kCompLatProfile 查表。
# 这里断言"表里不再有 kLatComp"，而不是断言某个新数值——数值标定归 D7 门禁。
check("kLatComp retired from table (comp -> kCompLatProfile)",
      "kLatComp" not in hdr and "kCompLatProfile" in hdr)
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

print("\n=== [B] 行为：结构性帧数按换算基准走（不是写死的毫秒常量） ===")
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


def make(sr, blk=None):
    # D7：comp 只在「一块的工作域长度 ≥ ovpLen(512)」时才真正处理；ASRC 采样率
    # 下工作块 = blk·48k/sr，故块长必须按 sr 等比放大，否则测到的是"未生效"的 0。
    if blk is None:
        blk = 512 * max(1, int(sr // 48000))
    h = b.auradsp_create(ctypes.c_float(sr), blk)
    return h if h else None


def set_bool(h, pid, v):
    iv = ctypes.c_int32(1 if v else 0)
    return b.auradsp_set_param(h, pid.encode(), ctypes.byref(iv), 4)


results = {}
# D7 更正：comp 的帧数属于**工作采样率域**，ASRC 启用时工作率恒 48k，
# 故三种设备采样率下的毫秒值应当相同（都是 3584/48000 = 74.67ms）。
# pre-D7 的两条断言要求 1:1/2:1/4 缩放，前提是"DSP 跑在设备域"——实测不成立。
for sr in (48000, 96000, 192000):
    h = make(sr)
    if not h:
        check(f"create engine @{sr}", False)
        continue
    try:
        # limiter 默认 lookahead=0（0ms）、reverb 默认关，故基线为 0。
        set_bool(h, "comp.enable", False)
        set_bool(h, "limiter.enable", False)
        base = b.auradsp_get_latency_ms(h)
        rc = set_bool(h, "comp.enable", True)
        ms = b.auradsp_get_latency_ms(h) - base
        results[sr] = ms
        check(f"comp latency @{int(sr/1000)}k ≈ 74.67ms (工作域 3584 帧)",
              abs(ms - 74.67) < 0.5,
              f"got {ms:.2f}ms (base={base:.2f}, rc={rc})")
    finally:
        b.auradsp_destroy(h)

if len(results) == 3:
    # 仍是「帧数 vs 写死毫秒」的判别：写死 85.0f 时三者相等但值不对；
    # 按设备率换算时三者呈 1:1/2:1/4（96k=37.33）→ 下面两条必红。
    check("comp latency is device-rate independent (ASRC work domain)",
          max(results.values()) - min(results.values()) < 0.5,
          f"48k={results[48000]:.2f} 96k={results[96000]:.2f} 192k={results[192000]:.2f}")

print("\n=== [C] 名义值与采样率无关（reverb 30ms） ===")
# D7 起 limiter 不再是固定 2ms 名义值（默认 lookahead=0 → 0ms；开前瞻 → 1.5ms），
# 改用真正"与采样率无关的名义值"项来测这一性质。
for sr in (48000, 96000):
    h = make(sr)
    if not h:
        continue
    try:
        set_bool(h, "comp.enable", False)
        mv = ctypes.c_int32(0)
        b.auradsp_set_param(h, b"reverb.preset", ctypes.byref(mv), 4)
        ms = b.auradsp_get_latency_ms(h)
        # 容差 0.05ms 而非 0.01：ASRC 启用时另计环形缓冲 ceil(inFs/fs) 个输入
        # 样本（96k→48k = 0.021ms），这是 D7 如实计入的真实分量。
        check(f"reverb nominal 30ms @{int(sr/1000)}k", abs(ms - 30.0) < 0.05,
              f"got {ms:.3f}ms")
    finally:
        b.auradsp_destroy(h)

print("\n=== [D] 叠加口径自洽（48k comp+reverb） ===")
h = make(48000)
if h:
    try:
        set_bool(h, "comp.enable", True)
        mv = ctypes.c_int32(0)
        b.auradsp_set_param(h, b"reverb.preset", ctypes.byref(mv), 4)
        ms = b.auradsp_get_latency_ms(h)
        check("48k comp(74.67)+reverb(30) ≈ 104.67ms", abs(ms - 104.67) < 0.5,
              f"got {ms:.2f}ms")
    finally:
        b.auradsp_destroy(h)

print()
if fails:
    print(f"D1 FAILURES: {fails}")
    sys.exit(1)
print(f"D1 ALL PASSED ({passes} checks)")
