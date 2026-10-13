"""smoke_loudness.py — 响度补偿验收。

验收标准：
  1. 关闭时直通。
  2. 安静低频（-40dBFS 60Hz）+ amount=1：输出 RMS 明显上升（低频补偿）。
  3. 响亮低频（-6dBFS 60Hz）：基本直通（q≈0）。
  4. 安静中频（-40dBFS 1kHz）：基本直通（无可补成分）。
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


def get_i(pid):
    v = i32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def run_sine(freq, amp, blocks=140):
    # 电平跟随慢（~0.5s），多跑让它收敛
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
check('enable set/get', set_i('loudness.enable', 1) == 0 and get_i('loudness.enable') == (0, 1))
check('amount set/get', set_f('loudness.amount', 0.5) == 0 and abs(get_f('loudness.amount')[1] - 0.5) < 1e-6)
set_f('loudness.amount', 9.0)
check('amount clamp 1', abs(get_f('loudness.amount')[1] - 1.0) < 1e-9)
set_f('loudness.amount', 1.0)

# 1. 关闭直通
set_i('loudness.enable', 0)
r_off = run_sine(60.0, 0.01)
expect_q = 0.01 / math.sqrt(2)
check('disabled passthrough', abs(r_off - expect_q) / expect_q < 0.05, 'rms=%.6f' % r_off)

# 2. 安静低频被补偿
set_i('loudness.enable', 1)
r_quiet_lo = run_sine(60.0, 0.01)
check('quiet LF lifted (>20%)', r_quiet_lo > expect_q * 1.2,
      'on=%.6f in=%.6f' % (r_quiet_lo, expect_q))

# 3. 响亮低频直通
r_loud_lo = run_sine(60.0, 0.5)
expect_loud = 0.5 / math.sqrt(2)
check('loud LF transparent (+-5%)', abs(r_loud_lo - expect_loud) / expect_loud < 0.05,
      'rms=%.5f' % r_loud_lo)

# 4. 安静中频直通（无可补成分）
r_quiet_mid = run_sine(1000.0, 0.01)
check('quiet mid transparent (+-10%)', abs(r_quiet_mid - expect_q) / expect_q < 0.10,
      'rms=%.6f' % r_quiet_mid)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('LOUDNESS FAILURES:', FAIL)
    sys.exit(1)
print('loudness: all checks passed')
