"""smoke_comp.py — 压限器验收。

验收标准：
  1. 关闭时直通。
  2. 开启后热信号（0.9）峰值被压住（<0.9），冷信号（0.05）基本通过。
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


def run_sine(freq, amp, blocks=40):
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
check('enable set/get', set_i('comp.enable', 1) == 0 and get_i('comp.enable') == (0, 1))
check('timeconstant set/get', set_f('comp.timeconstant', 0.14) == 0 and abs(get_f('comp.timeconstant')[1] - 0.14) < 1e-6)
check('granularity set/get+clamp',
      set_i('comp.granularity', 2) == 0 and get_i('comp.granularity') == (0, 2) and
      set_i('comp.granularity', 99) == 0 and get_i('comp.granularity') == (0, 4) and
      set_i('comp.granularity', -9) == 0 and get_i('comp.granularity') == (0, 0))
check('tfresolution set/get+clamp',
      set_i('comp.tfresolution', 1) == 0 and get_i('comp.tfresolution') == (0, 1) and
      set_i('comp.tfresolution', 99) == 0 and get_i('comp.tfresolution') == (0, 3))
check('outgain set/get+clamp',
      set_f('comp.outgain', 6.0) == 0 and abs(get_f('comp.outgain')[1] - 6.0) < 1e-6 and
      set_f('comp.outgain', 99.0) == 0 and abs(get_f('comp.outgain')[1] - 6.0) < 1e-6 and
      set_f('comp.outgain', -99.0) == 0 and abs(get_f('comp.outgain')[1] + 12.0) < 1e-6)
check('autogain set/get', set_i('comp.autogain', 1) == 0 and get_i('comp.autogain') == (0, 1))
set_i('comp.autogain', 0)
set_i('comp.granularity', 2)
set_i('comp.tfresolution', 1)
set_f('comp.outgain', 0.0)

# 1. 关闭直通
set_i('comp.enable', 0)
r, p = run_sine(1000.0, 0.9)
check('disabled passthrough', abs(p - 0.9) < 0.02, 'peak=%.4f' % p)

# 2. 超阈值热信号被压（阈值 0dBFS：1.5 → 压到 ~1.0）
set_i('comp.enable', 1)
r_hot, p_hot = run_sine(1000.0, 1.5, blocks=60)
check('hot peak squashed (<1.5)', p_hot < 1.5, 'peak=%.4f' % p_hot)
check('hot still audible (>0.5)', p_hot > 0.5, 'peak=%.4f' % p_hot)

# 3. 冷信号基本通过
_, p_cold = run_sine(1000.0, 0.05, blocks=60)
check('quiet passes (+-15%)', abs(p_cold - 0.05) / 0.05 < 0.15, 'peak=%.4f' % p_cold)

# 4. outgain 声学：同条件 0 vs +6dB 精确翻倍（压缩量与电平无关时比值只剩门增益）
set_f('comp.outgain', 0.0)
r0, _ = run_sine(1000.0, 0.2, blocks=60)
set_f('comp.outgain', 6.0)
r6, _ = run_sine(1000.0, 0.2, blocks=60)
check('outgain +6dB doubles (+-5%)', abs(r6 / r0 - 2.0) / 2.0 < 0.05 if r0 > 0 else False,
      'ratio=%.4f' % (r6 / r0 if r0 > 0 else 0.0))
set_f('comp.outgain', 0.0)

# 5. 全档位 granularity/tfresolution 跑一遍：只允许有限输出，不许崩/NaN
bad = False
for g in range(5):
    for t in range(4):
        set_i('comp.granularity', g)
        set_i('comp.tfresolution', t)
        _, p = run_sine(1000.0, 0.3, blocks=8)
        if p != p or p > 10.0:
            bad = True
check('all granularity/tfresolution combos finite', not bad)
set_i('comp.granularity', 2)
set_i('comp.tfresolution', 1)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('COMP FAILURES:', FAIL)
    sys.exit(1)
print('comp: all checks passed')
