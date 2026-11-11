# -*- coding: utf-8 -*-
# 多声道 EEL 范例脚本实测（方案 B）：四个可直接投产的多声道脚本，
# 逐个加载到引擎并断言数值行为——增益矩阵 / 环绕延迟填充 /
# 中置增强 / LFE 低通保护。脚本全文即用户可复制使用的范例。
import ctypes, math, sys

import os as _os, sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
from engine_artifact import engine_lib_path as _elp  # noqa: E402

dll = ctypes.CDLL(_elp())
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]

h = dll.auradsp_create(48000.0, 480)
assert h
i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)

def set_i(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)
def set_f(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)
def set_str(pid, s):
    b = s.encode("utf-8")
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))
def get_i(pid):
    v = ctypes.c_int32()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value

N = 480

def set_channels(ch):
    assert set_i("channels.count", ch) == 0
    assert set_i("channels.mode", 1) == 0

def load(code):
    assert set_str("liveprogmc.code", code) == 0, "example load failed"
    assert get_i("liveprogmc.status") == 1
    assert set_i("liveprogmc.enable", 1) == 0

# ============ 范例 1：逐声道增益矩阵（slider1..8 分别控制 8 声道） ============
EX1 = """/* 范例：逐声道增益矩阵
 * slider1..8 分别控制 spl0..spl7 增益（1.0 = 原样）。 */
@init
// 增益在 @sample 实时读取 slider，无初始化动作
@sample
spl0 = spl0 * slider1;
spl1 = spl1 * slider2;
spl2 = spl2 * slider3;
spl3 = spl3 * slider4;
spl4 = spl4 * slider5;
spl5 = spl5 * slider6;
spl6 = spl6 * slider7;
spl7 = spl7 * slider8;
"""
set_channels(8)
gains = [0.5, 0.25, 1.0, 0.0, 0.75, 0.5, 0.25, 1.0]
for i, g in enumerate(gains):
    assert set_f(f"liveprogmc.param{i + 1}", g) == 0
load(EX1)
buf = (ctypes.c_float * (N * 8))()
out = (ctypes.c_float * (N * 8))()
for n in range(N):
    for c in range(8):
        buf[n * 8 + c] = 0.08 * (c + 1)
for _ in range(4):
    dll.auradsp_process(h, buf, out, N)
for c in range(8):
    want = 0.08 * (c + 1) * gains[c]
    for n in range(0, N, 41):
        assert abs(out[n * 8 + c] - want) < 1e-5, f"EX1 ch{c}: {out[n * 8 + c]} != {want}"
print("EX1 per-channel gains: ok")

# ============ 范例 2：环绕填充（侧环绕延迟 256 采样 ×0.7 喂后环绕） ============
EX2 = """/* 范例：7.1 环绕填充
 * 后环绕 BL/BR 取侧环绕 SL/SR 经 256 采样延迟、衰减 0.7。
 * gmem 环形缓冲：[0,8192) 存 SL，[8192,16384) 存 SR。 */
@init
dpos = 0;
@sample
gmem[dpos] = spl4;
gmem[8192 + dpos] = spl5;
rpos = (dpos + 8192 - 256) % 8192;
spl6 = gmem[rpos] * 0.7;
spl7 = gmem[8192 + rpos] * 0.7;
dpos = (dpos + 1) % 8192;
"""
load(EX2)
total = N * 3
buf = (ctypes.c_float * (N * 8))()
out = (ctypes.c_float * (N * 8))()
history4, history5, got6, got7 = [], [], [], []
for blk in range(3):
    for n in range(N):
        g = blk * N + n
        buf[n * 8 + 4] = 0.001 * (g % 512) - 0.25
        buf[n * 8 + 5] = 0.25 - 0.001 * (g % 512)
    dll.auradsp_process(h, buf, out, N)
    for n in range(N):
        g = blk * N + n
        history4.append(0.001 * (g % 512) - 0.25)
        history5.append(0.25 - 0.001 * (g % 512))
        got6.append(out[n * 8 + 6])
        got7.append(out[n * 8 + 7])
for g in range(256, total):
    assert abs(got6[g] - history4[g - 256] * 0.7) < 1e-5, f"EX2 BL delay @{g}"
    assert abs(got7[g] - history5[g - 256] * 0.7) < 1e-5, f"EX2 BR delay @{g}"
print("EX2 surround fill (256-sample delay, x0.7): ok")

# ============ 范例 3：中置增强（5.1/7.1 的 C 加强并混入 L+R 相关分量） ============
EX3 = """/* 范例：中置增强
 * C = C*1.25 + (L+R)*0.1，对白更靠前；其余声道不动。 */
@init
// 无状态，无初始化动作
@sample
spl2 = spl2 * 1.25 + (spl0 + spl1) * 0.1;
"""
set_channels(6)
load(EX3)
buf = (ctypes.c_float * (N * 6))()
out = (ctypes.c_float * (N * 6))()
for n in range(N):
    for c in range(6):
        buf[n * 6 + c] = 0.08 * (c + 1)
for _ in range(4):
    dll.auradsp_process(h, buf, out, N)
want_c = 0.24 * 1.25 + (0.08 + 0.16) * 0.1
for n in range(0, N, 41):
    assert abs(out[n * 6 + 2] - want_c) < 1e-5, f"EX3 center: {out[n * 6 + 2]} != {want_c}"
    for c in (0, 1, 3, 4, 5):
        assert abs(out[n * 6 + c] - 0.08 * (c + 1)) < 1e-5, f"EX3 ch{c} untouched"
print("EX3 center enhance: ok")

# ============ 范例 4：LFE 保护（一阶低通 + 限幅） ============
EX4 = """/* 范例：LFE 保护
 * spl3 一阶低通（系数 0.1）压掉高频成分，再限幅到 ±0.5。 */
@init
lp = 0;
@sample
lp += 0.1 * (spl3 - lp);
spl3 = lp;
spl3 = max(-0.5, min(0.5, spl3));
"""
set_channels(8)
load(EX4)
buf = (ctypes.c_float * (N * 8))()
out = (ctypes.c_float * (N * 8))()
# 相位 A：±0.64 逐采样方波——低通后幅度应远小于输入
for n in range(N):
    buf[n * 8 + 3] = 0.64 if n % 2 == 0 else -0.64
for _ in range(6):
    dll.auradsp_process(h, buf, out, N)
peak = max(abs(out[n * 8 + 3]) for n in range(N))
assert peak < 0.2, f"EX4 square-wave leak: peak {peak}"
# 相位 B：恒定 0.64 输入——低通收敛后被限幅钳在 0.5
for n in range(N):
    buf[n * 8 + 3] = 0.64
for _ in range(10):
    dll.auradsp_process(h, buf, out, N)
for n in range(0, N, 41):
    assert abs(out[n * 8 + 3] - 0.5) < 1e-4, f"EX4 clamp: {out[n * 8 + 3]}"
print("EX4 LFE guard (one-pole LP + clamp): ok")

print("smoke_liveprog_mc_examples: PASS (4 production examples verified)")
sys.exit(0)
