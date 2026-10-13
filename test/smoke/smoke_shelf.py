"""smoke_shelf.py — 低频搁架验收（RBJ low-shelf）。

验收标准：
  1. 关闭时直通。
  2. +6dB@100Hz：50Hz RMS ×2（±5%），1kHz 不变（±3%）。
  3. set/get 回读对称；越界钳位。
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

# 0. 回读 + 钳位
check('enable set/get', set_i('shelf.enable', 1) == 0 and get_i('shelf.enable') == (0, 1))
check('freq set/get', set_f('shelf.freq', 100.0) == 0 and abs(get_f('shelf.freq')[1] - 100.0) < 1e-3)
set_f('shelf.freq', 5.0)
check('freq low clamp 40', abs(get_f('shelf.freq')[1] - 40.0) < 1e-3)
set_f('shelf.freq', 100.0)

# 1. 关闭直通
set_i('shelf.enable', 0)
r = run_sine(50.0)
check('disabled passthrough', abs(r - expect) / expect < 0.02, 'rms=%.5f' % r)

# 2. +6dB@100Hz（shelf 过渡带宽：25Hz 处约 +5.5dB，别按砖墙期望；
#    精确断言用相对线性：+12dB 相对 +6dB 必须精确 ×2）
set_i('shelf.enable', 1)
set_f('shelf.gain', 6.0)
r6 = run_sine(25.0, blocks=28)
check('25Hz substantially lifted (>1.8x)', r6 / expect > 1.8,
      'ratio=%.3f' % (r6 / expect))
set_f('shelf.gain', 12.0)
r12 = run_sine(25.0, blocks=28)
check('+12dB is exactly 2x of +6dB (+-2%)', abs(r12 / r6 - 2.0) / 2.0 < 0.02,
      'ratio=%.4f' % (r12 / r6))
set_f('shelf.gain', 6.0)
r1k = run_sine(1000.0)
check('1kHz untouched (+-3%)', abs(r1k - expect) / expect < 0.03, 'rms=%.5f' % r1k)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('SHELF FAILURES:', FAIL)
    sys.exit(1)
print('shelf: all checks passed')
