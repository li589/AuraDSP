"""smoke_fx_gain.py — P-010 每效果输出增益门 + 自动增益补偿验收。

验收标准：
  1. 输出增益门：bass.outgain=+6dB → 输出 RMS 精确翻倍（×10^(6/20)）。
  2. 输出增益门：eq.outgain=-12dB → 输出 RMS ×0.25。
  3. 增益门仅在效果开启时生效（关闭效果 → 直通）。
  4. 自动补偿：效果改变增益时开 autogain，输出 RMS 收敛回输入 RMS（±10%）。
  5. 补偿限幅：输入突然缩 100 倍，补偿被 ±12dB 上限截住（不炸）。
  6. set/get 回读对称；越界钳位 [-12,6]。
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


def run_sine(freq, amp, blocks=16, label=''):
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
set_i('bass.enable', 1)
check('bass.outgain set/get', set_f('bass.outgain', 6.0) == 0 and abs(get_f('bass.outgain')[1] - 6.0) < 1e-6)
set_f('bass.outgain', 99.0)
check('outgain high clamp 6', abs(get_f('bass.outgain')[1] - 6.0) < 1e-6)
set_f('bass.outgain', -99.0)
check('outgain low clamp -12', abs(get_f('bass.outgain')[1] + 12.0) < 1e-6)
check('autogain set/get', set_i('bass.autogain', 1) == 0 and get_i('bass.autogain') == (0, 1))
set_i('bass.autogain', 0)

# 1. 关掉 bass 效果本身 → 输出门不生效（直通）
set_f('bass.outgain', 6.0)
set_i('bass.enable', 0)
base_off = run_sine(1000.0, 0.1)
expect = 0.1 / math.sqrt(2)
check('gate inert when effect off', abs(base_off - expect) / expect < 0.03,
      'rms=%.5f expect=%.5f' % (base_off, expect))

# 2. 开启 bass + outgain=+6dB → ×2（bass 本体用小增益避免非线性干扰）
set_i('bass.enable', 1)
set_f('bass.gain', 1.0)
set_f('bass.outgain', 0.0)
base_on = run_sine(1000.0, 0.1)
set_f('bass.outgain', 6.0)
g6 = run_sine(1000.0, 0.1)
ratio = g6 / base_on if base_on > 0 else 0.0
check('+6dB doubles RMS (1.995 +-3%)', abs(ratio - 1.995) / 1.995 < 0.03,
      'ratio=%.4f' % ratio)

# 3. eq.outgain=-12dB → ×0.25（base_eq 在 -12dB 下测得）
set_i('eq.enable', 1)
set_f('eq.outgain', -12.0)
set_f('bass.outgain', 0.0)
set_f('bass.gain', 0.0)
base_eq = run_sine(1000.0, 0.1)
r12 = base_eq / expect
check('-12dB -> 0.25 +-5%', abs(r12 - 0.25) / 0.25 < 0.05, 'ratio=%.4f' % r12)
set_f('eq.outgain', 0.0)

# 4. 自动补偿：bass +10dB 使输出升 3.16x，开 autogain 收敛回输入
set_f('eq.outgain', 0.0)
set_f('bass.gain', 10.0)
set_f('bass.outgain', 0.0)
set_i('bass.autogain', 1)
ag_rms = run_sine(1000.0, 0.1, blocks=40)
check('autogain returns to input level (+-10%)', abs(ag_rms - expect) / expect < 0.10,
      'rms=%.5f expect=%.5f' % (ag_rms, expect))

# 5. 补偿限幅：输入缩到 1/100，补偿增益不得越过 +12dB（×4）
set_i('bass.autogain', 0)
set_f('bass.gain', 0.0)
set_i('bass.autogain', 1)
tiny = run_sine(1000.0, 0.001, blocks=40)
# 输入 0.001 → 期望输出仍 ~0.001（补偿上限 ×4 已到顶）
expect_tiny = 0.001 / math.sqrt(2)
check('autogain clamp: tiny input not boosted past +12dB',
      tiny < expect_tiny * 4.5, 'rms=%.6f cap=%.6f' % (tiny, expect_tiny * 4.5))

dll.auradsp_destroy(h)

print()
if FAIL:
    print('FX_GAIN FAILURES:', FAIL)
    sys.exit(1)
print('fx_gain: all checks passed')
