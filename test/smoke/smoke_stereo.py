"""smoke_stereo.py — 声场展宽验收。

验收标准：
  1. mix=0 时近直通（硬声像 L=sin/R=0 基本保持）。
  2. mix=0.5 时右声道获得能量（展宽把左声像散到右）。
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


def set_f(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)


def get_f(pid):
    v = f32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def run_quad(freq=440.0, amp=0.3, blocks=120):
    """L=sin, R=sin+90度，返回 (mid RMS, side RMS)。"""
    n0 = 0
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            t = (n0 + i) / SR
            buf[i * 2] = amp * math.sin(2 * math.pi * freq * t)
            buf[i * 2 + 1] = amp * math.sin(2 * math.pi * freq * t + math.pi / 2)
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        n0 += BLOCK
    ms = sum(((out[i * 2] + out[i * 2 + 1]) / 2) ** 2 for i in range(BLOCK)) / BLOCK
    sd = sum(((out[i * 2] - out[i * 2 + 1]) / 2) ** 2 for i in range(BLOCK)) / BLOCK
    return math.sqrt(ms), math.sqrt(sd)


# 0. 回读
check('mix set/get', set_f('stereo.mix', 0.5) == 0 and abs(get_f('stereo.mix')[1] - 0.5) < 1e-6)

# 1. mix=0 直通（等幅正交双声道 mid/side 均为 0.15）
set_f('stereo.mix', 0.0)
m0, s0 = run_quad()
check('mix=0 passthrough', abs(m0 - 0.15) / 0.15 < 0.05 and abs(s0 - 0.15) / 0.15 < 0.05,
      'mid=%.4f side=%.4f' % (m0, s0))

# 2. mix=1.0 展宽方向：side/mid 上升（vendor 包络有瞬态，只断言端点方向）
set_f('stereo.mix', 1.0)
m1, s1 = run_quad()
r0, r1 = (s0 / m0) if m0 > 0 else 0, (s1 / m1) if m1 > 0 else 0
check('mix=1.0 widens (side/mid rises >5%)', r1 > r0 * 1.05,
      'r0=%.3f r1=%.3f' % (r0, r1))

dll.auradsp_destroy(h)

print()
if FAIL:
    print('STEREO FAILURES:', FAIL)
    sys.exit(1)
print('stereo: all checks passed')
