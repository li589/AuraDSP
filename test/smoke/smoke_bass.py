"""smoke_bass.py — vendor 低音增强验收。

验收标准：
  1. 关闭时直通。
  2. +10dB：60Hz RMS ≈ ×3.16（±10%）；2kHz 不变（±5%）。
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


def run_sine(freq, amp=0.2, blocks=20):
    n0 = 0
    rms = 0.0
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
    return rms / 4.0


expect = 0.2 / math.sqrt(2)

# 0. 回读
check('enable set/get', set_i('bass.enable', 1) == 0 and get_i('bass.enable') == (0, 1))
check('gain set/get', set_f('bass.gain', 10.0) == 0 and abs(get_f('bass.gain')[1] - 10.0) < 1e-6)

# 1. 关闭直通
set_i('bass.enable', 0)
r = run_sine(60.0)
check('disabled passthrough', abs(r - expect) / expect < 0.02, 'rms=%.5f' % r)

# 2. +10dB 低频
set_i('bass.enable', 1)
set_f('bass.gain', 10.0)
r60 = run_sine(60.0, blocks=28)
check('+10dB lifts 60Hz ~3.16x (+-10%)', abs(r60 / expect - 3.16) / 3.16 < 0.10,
      'ratio=%.3f' % (r60 / expect))
r2k = run_sine(2000.0)
check('2kHz untouched (+-5%)', abs(r2k - expect) / expect < 0.05, 'rms=%.5f' % r2k)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('BASS FAILURES:', FAIL)
    sys.exit(1)
print('bass: all checks passed')
