"""smoke_tube.py — 电子管模拟器验收。

验收标准：
  1. 关闭/增益 0dB 时直通（线性残差 <0.5%）。
  2. 增益 12dB 时产生可测谐波（相对线性拟合的残差 >2%）。
  3. 软削波：峰值小于线性预测（被压缩）。
  4. set/get 回读对称。
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
    xs, ys = [], []
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
            for i in range(BLOCK):
                xs.append(buf[i * 2])
                ys.append(out[i * 2])
    return xs, ys


def linfit_residual(xs, ys):
    n = len(xs)
    dot_xy = sum(x * y for x, y in zip(xs, ys))
    dot_xx = sum(x * x for x in xs)
    g = dot_xy / dot_xx if dot_xx > 0 else 0.0
    res = math.sqrt(sum((y - g * x) ** 2 for x, y in zip(xs, ys)) / n)
    sig = math.sqrt(sum(y * y for y in ys) / n)
    peak = max(abs(y) for y in ys)
    return g, res, sig, peak


# 0. 回读
check('enable set/get', set_i('tube.enable', 1) == 0 and get_i('tube.enable') == (0, 1))
check('gain set/get', set_f('tube.gain', 6.0) == 0 and abs(get_f('tube.gain')[1] - 6.0) < 1e-6)
set_i('tube.enable', 0)

# 1. 关闭直通（线性）
xs, ys = run_sine(1000.0, 0.2)
_, res, sig, _ = linfit_residual(xs, ys)
check('disabled linear (<0.5% residual)', res < sig * 0.005,
      'res=%.6f sig=%.4f' % (res, sig))

# 2/3. 开启 12dB：有谐波 + 软削波
set_i('tube.enable', 1)
set_f('tube.gain', 12.0)
xs, ys = run_sine(1000.0, 0.2, blocks=24)
g, res, sig, peak = linfit_residual(xs, ys)
check('12dB harmonics present (>2%)', res > sig * 0.02,
      'res=%.5f sig=%.4f' % (res, sig))
linear_peak = 0.2 * (10.0 ** (12.0 / 20.0))
check('soft saturation (peak < linear)', peak < linear_peak * 0.98,
      'peak=%.4f linear=%.4f' % (peak, linear_peak))

dll.auradsp_destroy(h)

print()
if FAIL:
    print('TUBE FAILURES:', FAIL)
    sys.exit(1)
print('tube: all checks passed')
