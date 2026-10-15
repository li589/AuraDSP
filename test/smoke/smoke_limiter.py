# -*- coding: utf-8 -*-
"""smoke_limiter.py — P-012 输出限幅器总开关验收。

验收标准：
  1. 出厂默认限幅开（与上游一致）：+6dB 热正弦被钳到 ~1.0。
  2. limiter.enable=0：同一热信号直通（峰值 ≈ 输入峰值，远超 1.0）。
  3. limiter.enable=1：恢复钳位；set/get 对称。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')
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

i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)


def set_i(h, pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)


def get_i(h, pid):
    v = ctypes.c_int32()
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def hot_peak(enable):
    """新句柄：post 0dB；enable True/False 下发，None=从不碰（出厂默认）。
    其余效果全默认关/中性，只跑 output 段。"""
    h = dll.auradsp_create(SR, BLOCK)
    if enable is not None:
        set_i(h, 'limiter.enable', 1 if enable else 0)
    buf = (ctypes.c_float * (BLOCK * 2))()
    out = (ctypes.c_float * (BLOCK * 2))()
    peak = 0.0
    for b in range(40):
        for n in range(BLOCK):
            s = 2.0 * math.sin(b * 0.11 + n * 0.05)
            buf[2 * n] = s
            buf[2 * n + 1] = s
        dll.auradsp_process(h, buf, out, BLOCK)
        for i in range(BLOCK * 2):
            a = abs(out[i])
            if a > peak:
                peak = a
    dll.auradsp_destroy(h)
    return peak


# 1. 出厂默认（从不下发）：限幅生效，与上游一致
p_default = hot_peak(None)
print('factory-default peak=%.4f' % p_default)
check('factory default clamps (~1.0)', p_default < 1.2, 'peak=%.4f' % p_default)
p_on = hot_peak(True)
check('explicit enable clamps (~1.0)', p_on < 1.2, 'peak=%.4f' % p_on)

# 2. 关：直通
p_off = hot_peak(False)
print('disabled peak=%.4f' % p_off)
check('disabled passes through (>1.5)', p_off > 1.5, 'peak=%.4f' % p_off)

# 3. set/get 对称
h = dll.auradsp_create(SR, BLOCK)
check('set/get roundtrip',
      set_i(h, 'limiter.enable', 0) == 0 and get_i(h, 'limiter.enable') == (0, 0) and
      set_i(h, 'limiter.enable', 1) == 0 and get_i(h, 'limiter.enable') == (0, 1))
dll.auradsp_destroy(h)

# 4. post.gain 精度（旧版覆盖项，保留：+6dB 精确 ×2 ±2%）
def get_f(h, pid):
    v = ctypes.c_float()
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


h = dll.auradsp_create(SR, BLOCK)
check('postgain set/get',
      dll.auradsp_set_param(h, b'post.gain', ctypes.byref(ctypes.c_float(6.0)), 4) == 0 and
      abs(get_f(h, 'post.gain')[1] - 6.0) < 1e-6)
N = BLOCK
bi = (ctypes.c_float * (N * 2))()
bo = (ctypes.c_float * (N * 2))()
for n in range(N):
    bi[2 * n] = 0.1
    bi[2 * n + 1] = 0.1
dll.auradsp_process(h, bi, bo, N)
r = bo[0] / 0.1 if bo[0] != 0 else 0.0
check('+6dB exact x2 (+-2%)', abs(r / 2.0 - 1.0) < 0.02 if r else False,
      'ratio=%.4f' % (r / 2.0 if r else 0.0))
dll.auradsp_destroy(h)

print()
if FAIL:
    print('LIMITER FAILURES:', FAIL)
    sys.exit(1)
print('limiter: all checks passed')
