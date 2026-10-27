# -*- coding: utf-8 -*-
"""smoke_sr_rate_alignment.py — 采样率域一致性门禁（自研链 vs vendor 链）。

审查发现（多声道/采样率细审）：引擎内部存在**两个采样率域**：

  · 设备率 `h->sample_rate`   —— 驱动缓冲的实际速率，RT 链的自研模块处理的就是它
  · 工作率 `h->jdsp.fs`        —— ASRC 之后的 vendor 链速率（非常见率时恒 48k/44.1k）

vendor 链（`JamesDSPProcessMultiplexedStageSet`）整体被 ASRC 包裹
（jdspController.c:1283-1313：DoASRC_fwd → stage 循环 → DoASRC_bwd），
所以 vendor stage 用 `jdsp->fs` 算系数是**自洽**的。

但**自研链在 ASRC 之外**（engine_chain.cpp:1019-1022 `filter_process` 直接
处理设备率 `src`；MC 路径 engine_chain.cpp:800-822 同理），却用
`h->jdsp.fs`（工作率）算系数 —— 96k 设备上截止频率整体翻倍、192k 翻四倍。

本门禁三段：
  [A] 自研 filter 的 -3dB 频率必须与设备率无关（48k/96k/192k 同为 1000Hz）
  [B] vendor EQ 同一曲线在三种设备率下 -3dB 频率一致（ASRC 内自洽的对照组）
  [C] eq.enable=0 必须真的关闭 vendor EQ

pre-fix 行为：48k -3dB@1000 / 96k -3dB@2000 / 192k -3dB@4000 → [A] 判红。
"""
import ctypes
import math
import os
import sys

# ---- 仓库根：向上找 engine/auradsp_engine.h（不写 '..' 深度算术） ----
_here = os.path.dirname(os.path.abspath(__file__))
ROOT = _here
for _ in range(6):
    ROOT = os.path.dirname(ROOT)
    if os.path.exists(os.path.join(ROOT, "engine", "auradsp_engine.h")):
        break
else:
    print("SKIP（找不到仓库根 engine/auradsp_engine.h）")
    sys.exit(0)

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

lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_set_param.restype = ctypes.c_int
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p,
                                  ctypes.c_uint32]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]

BLOCK = 512
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


def set_i(h, pid, v):
    iv = ctypes.c_int32(v)
    return lib.auradsp_set_param(h, pid.encode(), ctypes.cast(ctypes.byref(iv), ctypes.c_void_p), 4)


def set_f(h, pid, v):
    fv = ctypes.c_float(v)
    return lib.auradsp_set_param(h, pid.encode(), ctypes.cast(ctypes.byref(fv), ctypes.c_void_p), 4)


def set_s(h, pid, s):
    raw = s.encode("utf-8")
    buf = ctypes.create_string_buffer(raw)
    return lib.auradsp_set_param(h, pid.encode(), ctypes.cast(buf, ctypes.c_void_p), len(raw) + 1)


def measure_db(h, sr, freq, warm=6, nblocks=10):
    """喂稳态正弦，测输出 RMS / 输入 RMS 的 dB 增益。"""
    n = BLOCK * 2
    inbuf = (ctypes.c_float * n)()
    outbuf = (ctypes.c_float * n)()
    step = 2.0 * math.pi * freq / float(sr)
    phase = 0.0
    acc = 0.0
    cnt = 0
    for b in range(nblocks):
        for i in range(BLOCK):
            v = 0.5 * math.sin(phase)
            phase += step
            inbuf[i * 2] = v
            inbuf[i * 2 + 1] = v
        lib.auradsp_process(h, inbuf, outbuf, BLOCK)
        if b >= warm:
            s = 0.0
            for i in range(n):
                s += outbuf[i] * outbuf[i]
            acc += s
            cnt += n
    in_rms = 0.5 / math.sqrt(2.0)
    out_rms = math.sqrt(acc / cnt) if cnt else 0.0
    if out_rms <= 1e-12:
        return -200.0
    return 20.0 * math.log10(out_rms / in_rms)


def find_cutoff(sr, freqs, gains, target_db=-3.0):
    """在 (freq, gain) 序列上找 target_db 的交点（线性插值）。"""
    prev_f, prev_g = None, None
    for f, g in zip(freqs, gains):
        if prev_g is not None and ((prev_g - target_db) * (g - target_db) <= 0) and prev_g != g:
            span = prev_g - g
            ratio = (prev_g - target_db) / span if span else 0.0
            return prev_f + ratio * (f - prev_f)
        prev_f, prev_g = f, g
    return None


def probe_filter(sr, f0=1000.0, q=0.70710678):
    """自研 filter（LP）：返回 (1000Hz 处增益 dB, -3dB 频率 Hz)。"""
    h = lib.auradsp_create(float(sr), BLOCK)
    if not h:
        return None, None
    try:
        set_i(h, "filter.enable", 1)
        set_i(h, "filter.type", 1)      # 1 = LP
        set_f(h, "filter.freq", f0)
        set_f(h, "filter.q", q)
        freqs = [400.0, 600.0, 800.0, 1000.0, 1400.0, 2000.0, 2800.0, 4000.0, 6000.0]
        gains = [measure_db(h, sr, f) for f in freqs]
        g1000 = gains[freqs.index(1000.0)]
        return g1000, find_cutoff(sr, freqs, gains)
    finally:
        lib.auradsp_destroy(h)


def probe_eq(sr, enable_after=None):
    """vendor EQ：曲线 20Hz:0dB / 1000Hz:-6dB / 20kHz:-6dB → 1000Hz 处应 -6dB。"""
    h = lib.auradsp_create(float(sr), BLOCK)
    if not h:
        return None
    try:
        set_i(h, "eq.enable", 1)
        set_s(h, "eq.curve", "eqm:0:0;20:0;1000:-6;20000:-6")
        g = measure_db(h, sr, 1000.0)
        if enable_after is not None:
            set_i(h, "eq.enable", enable_after)
            g2 = measure_db(h, sr, 1000.0)
            return g, g2
        return g, None
    finally:
        lib.auradsp_destroy(h)


print(f"DLL: {DLL}")
print("")

# ---- [A] 自研 filter：-3dB 频率必须与设备率无关 ----
print("[A] 自研 filter (LP f0=1000Hz) 的 -3dB 频率")
res = {}
for sr in (48000, 96000, 192000):
    g1000, cut = probe_filter(sr)
    res[sr] = (g1000, cut)
    print(f"    {sr:>6} Hz : gain@1000Hz = {g1000:+.2f} dB   -3dB @ {cut if cut else float('nan'):.0f} Hz")

base_cut = res[48000][1]
for sr in (48000, 96000, 192000):
    g1000, cut = res[sr]
    if cut is None:
        check(f"[A] filter @{sr}Hz 测得 -3dB 交点", False, "扫频未捕获交点")
        continue
    # 目标：-3dB 频率恒为 1000Hz（误差 <=12%）
    ok = abs(cut - 1000.0) <= 120.0
    ratio = cut / base_cut if base_cut else float("nan")
    check(f"[A] filter @{sr}Hz -3dB 频率 == 1000Hz", ok,
          f"实测 {cut:.0f} Hz（相对 48k = {ratio:.2f}x）")
print("")

# ---- [B] 对照组：vendor EQ（ASRC 内）在三种设备率下一致 ----
print("[B] 对照组 vendor EQ（曲线 1000Hz:-6dB）")
eqg = {}
for sr in (48000, 96000, 192000):
    g, _ = probe_eq(sr)
    eqg[sr] = g
    print(f"    {sr:>6} Hz : gain@1000Hz = {g:+.2f} dB")
for sr in (48000, 96000, 192000):
    g = eqg[sr]
    check(f"[B] vendor EQ @{sr}Hz gain@1000Hz ≈ -6dB", g is not None and abs(g + 6.0) <= 1.0,
          f"实测 {g:+.2f} dB")
print("")

# ---- [C] eq.enable=0 必须真的关闭 ----
print("[C] eq.enable=0 的关闭语义")
g_on, g_off = probe_eq(96000, enable_after=0)
print(f"    enable=1 -> {g_on:+.2f} dB ; enable=0 -> {g_off:+.2f} dB")
check("[C] eq.enable=0 后 EQ 停止作用", g_off is not None and abs(g_off) <= 1.0,
      f"关闭后仍为 {g_off:+.2f} dB（期望 ≈ 0 dB）")

# ---- [D] 多声道 IR 门卫：vendor 卷积器是立体声对实现，只支持 1/2/4 声道 ----
print("")
print("[D] 多声道 IR 门卫（3/5/6/7/8 声道必须被显式拒绝）")
import os as _os
import shutil as _shutil
import struct as _struct
import tempfile as _tempfile
import wave as _wave


def _write_wav(path, channels, frames=1024, rate=48000):
    # 非静音 IR（引擎有 "all-silent IR" 门卫，全零会被单独拒绝，
    # 那样就测不到声道数门卫本身了）。
    import math
    with _wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames_data = bytearray()
        for i in range(frames):
            env = math.exp(-4.0 * i / frames)
            for c in range(channels):
                v = int(12000.0 * env * math.sin(2.0 * math.pi * (440.0 + 110.0 * c) * i / rate))
                frames_data += _struct.pack("<h", v)
        w.writeframes(bytes(frames_data))


lib.auradsp_last_error.restype = ctypes.c_char_p
lib.auradsp_last_error.argtypes = [ctypes.c_void_p]
_tmp = _tempfile.mkdtemp(prefix="aura_ir_")
try:
    for ch in (2, 4, 6, 8):
        path = _os.path.join(_tmp, "ir_%dch.wav" % ch)
        _write_wav(path, ch)
        h = lib.auradsp_create(48000.0, BLOCK)
        try:
            rc = set_s(h, "convolver.ir.path", path)
            err = (lib.auradsp_last_error(h) or b"").decode("utf-8", "replace")
        finally:
            lib.auradsp_destroy(h)
        if ch in (2, 4):
            check(f"[D] {ch} 声道 IR 加载成功", rc == 0, f"rc={rc} err={err}")
        else:
            # 修复前：3/5/6/7/8 声道返回**成功**且 ir_ready=1，实际无卷积
            check(f"[D] {ch} 声道 IR 被显式拒绝", rc != 0 and "unsupported" in err,
                  f"rc={rc} err={err}")
finally:
    _shutil.rmtree(_tmp, ignore_errors=True)

print("")
print(f"passed={passes} failed={len(fails)}")
if fails:
    for f in fails:
        print(f"  FAIL {f}")
    sys.exit(1)
print("ALL PASS")