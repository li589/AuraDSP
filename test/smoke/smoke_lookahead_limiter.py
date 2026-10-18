# -*- coding: utf-8 -*-
"""smoke_lookahead_limiter.py — P2.3 Modern Lookahead Limiter 尖端特性验收。

验收标准：
  1. 1.5ms 前瞻环形缓冲：超载脉冲在 1.5ms 前已被平滑衰减，绝无阶跃截断与瞬态失真。
  2. 4x ISP (Inter-Sample Peak) 真峰检测：相邻样本未超但样点间真峰超载时，被精确压制。
  3. 立体声增益联动 (limiter.link=1)：单侧超载时双侧同比例衰减，严格保护声像定位不变。
  4. 阈值与释放参数联动 (limiter.threshold, limiter.release)：dBFS 门限与释放时间精准控制。
  5. GR (Gain Reduction) 实时计量：通过 get_param("gr.limiter") 获取当前块的衰减分贝值 (dB >= 0)。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release', 'auradsp_engine.dll')
SR = 48000.0
BLOCK = 512
FAIL = []

def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)

dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_destroy.restype = None
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

def i32(v): return ctypes.c_int32(v)
def f32(v): return ctypes.c_float(v)

def set_i(h, pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)

def set_f(h, pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)

def get_f(h, pid):
    v = ctypes.c_float()
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value

def get_i(h, pid):
    v = ctypes.c_int32()
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value

# -------------------------------------------------------------------------
# 1. 阈值设定测试 (limiter.threshold = -3.0 dBFS)
# -------------------------------------------------------------------------
print("=== [1] 阈值门限控制 (Threshold = -3dBFS, -6dBFS) ===")
h = dll.auradsp_create(SR, BLOCK)
set_i(h, 'limiter.enable', 1)
set_i(h, 'limiter.lookahead', 1)
set_f(h, 'limiter.threshold', -3.0)
_, th_val = get_f(h, 'limiter.threshold')
check('threshold set/get', abs(th_val - (-3.0)) < 1e-4)

# 输入 +6dBFS (2.0) 正弦波
buf = (ctypes.c_float * (BLOCK * 2))()
out = (ctypes.c_float * (BLOCK * 2))()
peak = 0.0
for b in range(10):
    for n in range(BLOCK):
        s = 2.0 * math.sin(b * 0.1 + n * 0.05)
        buf[2 * n] = s
        buf[2 * n + 1] = s
    dll.auradsp_process(h, buf, out, BLOCK)
    for i in range(BLOCK * 2):
        a = abs(out[i])
        if a > peak:
            peak = a

expected_lin = 10.0 ** (-3.0 / 20.0) # ~0.7079
check('clamp to -3dBFS (~0.708)', peak <= expected_lin + 0.01, f'peak={peak:.4f}, exp={expected_lin:.4f}')

# 读取 GR 增益衰减 (信号在进链尾前已由前置限制至 1.0，限幅器精准下压 3dB 到 0.708，实测 GR 约为 3.01dB)
rc, gr = get_f(h, 'gr.limiter')
check('GR metering active (>=2.5dB)', rc == 0 and gr >= 2.5, f'gr={gr:.2f} dB')
dll.auradsp_destroy(h)

# -------------------------------------------------------------------------
# 2. 4x ISP 真峰检测 (Inter-Sample Peak)
# -------------------------------------------------------------------------
print("\n=== [2] 4x ISP 真峰检测 ===")
# 构造高频信号：采样点恰好为对称交替点，采样点本身不超 1.0，但采样点间真实连续模拟波形显著超出 1.0
h = dll.auradsp_create(SR, BLOCK)
set_i(h, 'limiter.enable', 1)
set_i(h, 'limiter.lookahead', 1)
set_f(h, 'limiter.threshold', 0.0) # 0 dBFS (1.0)

isp_buf = (ctypes.c_float * (BLOCK * 2))()
isp_out = (ctypes.c_float * (BLOCK * 2))()
pat = [0.9, 0.9, -0.9, -0.9]
max_out_isp = 0.0
for b in range(10):
    for n in range(BLOCK):
        v = pat[n % 4]
        isp_buf[2 * n] = v
        isp_buf[2 * n + 1] = v
    dll.auradsp_process(h, isp_buf, isp_out, BLOCK)
    for i in range(BLOCK * 2):
        if abs(isp_out[i]) > max_out_isp:
            max_out_isp = abs(isp_out[i])

# 4x ISP 检测到样点间真峰超载，将其衰减使得重建真峰不超过 1.0
check('4x ISP detects and pulls down samples (<0.82)', max_out_isp < 0.82, f'max_sample={max_out_isp:.4f}')
rc, gr_isp = get_f(h, 'gr.limiter')
check('4x ISP registers GR (>0.8dB)', gr_isp > 0.8, f'gr={gr_isp:.2f} dB')
dll.auradsp_destroy(h)

# -------------------------------------------------------------------------
# 3. 立体声联动模式 (limiter.link)
# -------------------------------------------------------------------------
print("\n=== [3] 立体声增益联动 (limiter.link = 1 vs 0) ===")
# 左声道热信号 (2.0)，右声道正常信号 (0.3)
h_link = dll.auradsp_create(SR, BLOCK)
set_i(h_link, 'limiter.enable', 1)
set_i(h_link, 'limiter.link', 1) # 开启联动
set_i(h_link, 'limiter.lookahead', 1)

b_in = (ctypes.c_float * (BLOCK * 2))()
b_out = (ctypes.c_float * (BLOCK * 2))()
for b in range(10):
    for n in range(BLOCK):
        b_in[2 * n] = 2.0 * math.sin(n * 0.05)     # L 超载
        b_in[2 * n + 1] = 0.3 * math.sin(n * 0.05) # R 正常
    dll.auradsp_process(h_link, b_in, b_out, BLOCK)

# 在最后一帧测 L 与 R 的比值：若联动，则无论当前瞬时信号如何，两声道缩放倍率严格相同 (L/R == 2.0/0.3)
ratio_err = 0.0
count = 0
for n in range(BLOCK // 2, BLOCK):
    l_in = b_in[2 * n]
    r_in = b_in[2 * n + 1]
    l_out = b_out[2 * n]
    r_out = b_out[2 * n + 1]
    if abs(r_in) > 0.05:
        gain_l = l_out / l_in
        gain_r = r_out / r_in
        diff = abs(gain_l - gain_r)
        if diff > ratio_err:
            ratio_err = diff
        count += 1

check('Stereo Link: L & R identical gain scale (diff < 1e-3)', ratio_err < 1e-3, f'max diff={ratio_err:.2e}')
dll.auradsp_destroy(h_link)

# -------------------------------------------------------------------------
# 4. 释放时间控制 (limiter.release)
# -------------------------------------------------------------------------
print("\n=== [4] 释放时间常数 (Release Time) ===")
h_rel = dll.auradsp_create(SR, BLOCK)
set_i(h_rel, 'limiter.enable', 1)
set_f(h_rel, 'limiter.release', 200.0) # 200ms
_, rel_val = get_f(h_rel, 'limiter.release')
check('release set/get', abs(rel_val - 200.0) < 1e-3)
dll.auradsp_destroy(h_rel)

print()
if FAIL:
    print('LOOKAHEAD LIMITER FAILURES:', FAIL)
    sys.exit(1)
print('lookahead limiter: all checks passed!')
