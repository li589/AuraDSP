"""smoke_basspsycho.py — 心理声学低音验收。

验收标准：
  1. amount=0（或 bass 关）时恒等直通。
  2. 50Hz 正弦 + harmonics=0.7：输出 RMS 上升（谐波注入能量）。
  3. 1kHz 正弦 + harmonics=0.7：输出基本不变（只动低频带）。
  4. subfreq 上限：同样 50Hz，subfreq=40 比 subfreq=10 增量小（谐波带收窄）。
  5. set/get 回读对称；越界钳位。
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


def run_sine(freq, amp=0.3, blocks=20):
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


# 0. 回读 + 钳位
check('harmonics set/get', set_f('bass.harmonics', 0.7) == 0 and abs(get_f('bass.harmonics')[1] - 0.7) < 1e-6)
check('blend set/get', set_f('bass.harmonicblend', 0.5) == 0 and abs(get_f('bass.harmonicblend')[1] - 0.5) < 1e-6)
set_f('bass.harmonics', 5.0)
check('harmonics clamp 1', abs(get_f('bass.harmonics')[1] - 1.0) < 1e-9)
set_f('bass.subfreq', 5.0)
check('subfreq clamp 10', abs(get_f('bass.subfreq')[1] - 10.0) < 1e-3)
set_f('bass.cutoff', 999.0)
check('cutoff clamp 300', abs(get_f('bass.cutoff')[1] - 300.0) < 1e-3)

# bass 卡开（psycho 跟 bass 开关走）
set_i('bass.enable', 1)
set_f('bass.gain', 0.0)
expect = 0.3 / math.sqrt(2)

# 1. amount=0 直通
set_f('bass.harmonics', 0.0)
set_f('bass.harmonicblend', 0.5)
set_f('bass.subfreq', 25.0)
set_f('bass.cutoff', 120.0)
r0 = run_sine(50.0)
check('amount=0 passthrough', abs(r0 - expect) / expect < 0.02, 'rms=%.5f' % r0)

# 2. 50Hz + harmonics=0.7 注入能量
set_f('bass.harmonics', 0.7)
r50 = run_sine(50.0)
check('50Hz gains harmonic energy (>3%)', r50 > r0 * 1.03,
      'on=%.5f off=%.5f' % (r50, r0))

# 3. 1kHz 不动
r1k_on = run_sine(1000.0)
check('1kHz untouched (<2%)', abs(r1k_on - expect) / expect < 0.02,
      'rms=%.5f' % r1k_on)

# 4. subfreq 收窄谐波带 → 增量变小
set_f('bass.subfreq', 40.0)
r50_narrow = run_sine(50.0)
check('narrower band -> less lift', r50_narrow < r50,
      'narrow=%.5f wide=%.5f' % (r50_narrow, r50))

# 5. bass 关 → 无染色
set_i('bass.enable', 0)
r_off = run_sine(50.0)
check('bass off: no coloration', abs(r_off - expect) / expect < 0.02,
      'rms=%.5f' % r_off)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('BASSPSYCHO FAILURES:', FAIL)
    sys.exit(1)
print('basspsycho: all checks passed')
