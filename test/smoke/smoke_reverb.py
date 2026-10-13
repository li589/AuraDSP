"""smoke_reverb.py — Freeverb 混响验收。

验收标准：
  1. 关闭时脉冲直通（首采样在 0，能量集中）。
  2. 开启（dry=0/wet=1）后：脉冲尾部（2000~8000 采样）有可测能量。
  3. freeverb 参数 set/get 对称；reverb.preset 下发成功。
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


def impulse_tail(nblocks=24):
    """首块 0 采样打脉冲，返回全程左声道 + 尾部能量占比。"""
    sig = []
    for b in range(nblocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        if b == 0:
            buf[0] = 0.5
            buf[1] = 0.5
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        for i in range(BLOCK):
            sig.append(out[i * 2])
    total = sum(s * s for s in sig)
    tail = sum(s * s for s in sig[2000:8000])
    first = next((i for i, s in enumerate(sig) if abs(s) > 0.01), -1)
    return first, (tail / total) if total > 0 else 0.0


# 0. 参数（reverb.preset=-1 为关闭，0 起为有效预设）
check('preset -1 (off) ok', set_i('reverb.preset', -1) == 0)
check('fv enable set', set_i('freeverb.enable', 0) == 0)
check('decay set/get', set_f('freeverb.decay', 0.5) == 0 and abs(get_f('freeverb.decay')[1] - 0.5) < 1e-6)
set_f('freeverb.decay', 0.7)
set_f('freeverb.damp', 0.4)
set_f('freeverb.wet', 1.0)
set_f('freeverb.dry', 0.0)

# 1. 全关：脉冲在 0，几乎无尾
set_i('freeverb.enable', 0)
first_off, tail_off = impulse_tail()
check('disabled: impulse at 0', first_off == 0, 'first=%d' % first_off)
check('disabled: no tail', tail_off < 0.01, 'tail=%.4f' % tail_off)

# 2. Freeverb 开启：尾部有能量
set_i('freeverb.enable', 1)
first_on, tail_on = impulse_tail(nblocks=32)
check('enabled: audible tail (>5%)', tail_on > 0.05, 'tail=%.4f' % tail_on)
set_i('freeverb.enable', 0)

# 3. vendor reverb preset=0：也有尾（另一条混响路径活着）
set_i('reverb.preset', 0)
_, tail_vendor = impulse_tail(nblocks=32)
check('vendor preset=0 audible tail', tail_vendor > 0.01, 'tail=%.4f' % tail_vendor)
set_i('reverb.preset', -1)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('REVERB FAILURES:', FAIL)
    sys.exit(1)
print('reverb: all checks passed')
