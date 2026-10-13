"""smoke_limiter.py — 输出限幅 + 后级增益验收。

验收标准：
  1. post.gain 精确缩放（+6dB → ×2，小信号不限幅时）。
  2. 热信号 + 限幅开：峰值被钳住（<=1.05）。
  3. set/get 回读对称。
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


h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'


def set_i(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)


def set_f(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)


def get_f(pid):
    v = f32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def get_i(pid):
    v = i32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def run_sine(freq, amp, blocks=16):
    n0 = 0
    rms = peak = 0.0
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            s = amp * math.sin(2 * math.pi * freq * (n0 + i) / SR)
            buf[i * 2] = s
            buf[i * 2 + 1] = s
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        n0 += BLOCK
        if b >= blocks - 4:
            acc = sum(out[i * 2] ** 2 for i in range(BLOCK)) / BLOCK
            rms += math.sqrt(acc)
            peak = max(peak, max(abs(out[i * 2]) for i in range(BLOCK)))
    return rms / 4.0, peak


# 0. 回读
check('postgain set/get', set_f('post.gain', 6.0) == 0 and abs(get_f('post.gain')[1] - 6.0) < 1e-6)
check('limiter set/get', set_i('limiter.enable', 1) == 0 and get_i('limiter.enable') == (0, 1))
set_f('post.gain', 0.0)
set_i('limiter.enable', 0)

# 1. post 精确缩放（小信号，限幅关）
set_f('post.gain', 6.0)
r, _ = run_sine(1000.0, 0.1)
expect = 0.1 / math.sqrt(2)
check('+6dB exact x2 (+-2%)', abs(r / expect - 2.0) / 2.0 < 0.02, 'ratio=%.4f' % (r / expect))
set_f('post.gain', 0.0)

# 2. 热信号 + 限幅
set_f('post.gain', 12.0)
set_i('limiter.enable', 1)
_, p = run_sine(1000.0, 0.5, blocks=24)
check('hot clamped (peak<=1.05)', p <= 1.05, 'peak=%.4f' % p)
set_i('limiter.enable', 0)
set_f('post.gain', 0.0)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('LIMITER FAILURES:', FAIL)
    sys.exit(1)
print('limiter: all checks passed')
