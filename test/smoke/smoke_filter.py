"""smoke_filter.py — 独立滤波器验收（RBJ HP/LP/BP）。

验收标准：
  1. 关闭时直通；type 越界钳位 0..2。
  2. HP@80Hz：30Hz 衰减 >10dB，1kHz 通过（±3%）。
  3. LP@200Hz：2kHz 衰减 >10dB，50Hz 通过（±3%）。
  4. BP@1kHz Q=1：1kHz 通过（-3dB 内），100Hz/10kHz 衰减明显。
  5. set/get 回读对称。
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


def run_sine(freq, amp=0.3, blocks=24):
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


expect = 0.3 / math.sqrt(2)

# 0. 回读 + 钳位
check('enable set/get', set_i('filter.enable', 1) == 0 and get_i('filter.enable') == (0, 1))
set_i('filter.type', 9)
check('type clamp 2', get_i('filter.type') == (0, 2))
check('freq set/get', set_f('filter.freq', 80.0) == 0 and abs(get_f('filter.freq')[1] - 80.0) < 1e-3)
check('q set/get', set_f('filter.q', 1.0) == 0 and abs(get_f('filter.q')[1] - 1.0) < 1e-6)

# 1. 关闭直通
set_i('filter.enable', 0)
r_off = run_sine(1000.0)
check('disabled passthrough', abs(r_off - expect) / expect < 0.02, 'rms=%.5f' % r_off)

# 2. HP@80：30Hz 衰减，1kHz 通过
set_i('filter.enable', 1)
set_i('filter.type', 0)
set_f('filter.freq', 80.0)
set_f('filter.q', 0.707)
r30 = run_sine(30.0)
r1k = run_sine(1000.0)
check('HP kills 30Hz (>-10dB)', r30 < expect * 0.32, 'rms=%.5f' % r30)
check('HP passes 1kHz (+-3%)', abs(r1k - expect) / expect < 0.03, 'rms=%.5f' % r1k)

# 3. LP@200：2kHz 衰减，50Hz 通过
set_i('filter.type', 1)
set_f('filter.freq', 200.0)
r2k = run_sine(2000.0)
r50 = run_sine(50.0)
check('LP kills 2kHz (>-10dB)', r2k < expect * 0.32, 'rms=%.5f' % r2k)
check('LP passes 50Hz (+-3%)', abs(r50 - expect) / expect < 0.03, 'rms=%.5f' % r50)

# 4. BP@1k Q=1：中心通过（-3dB 内），两翼衰减
set_i('filter.type', 2)
set_f('filter.freq', 1000.0)
set_f('filter.q', 1.0)
rc = run_sine(1000.0)
r100 = run_sine(100.0)
r10k = run_sine(10000.0)
check('BP passes center (>-3dB)', rc > expect * 0.707, 'rms=%.5f' % rc)
check('BP kills 100Hz', r100 < expect * 0.5, 'rms=%.5f' % r100)
check('BP kills 10kHz', r10k < expect * 0.5, 'rms=%.5f' % r10k)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('FILTER FAILURES:', FAIL)
    sys.exit(1)
print('filter: all checks passed')
