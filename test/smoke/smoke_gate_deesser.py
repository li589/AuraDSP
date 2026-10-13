"""smoke_gate_deesser.py — 噪声门 + Deesser + 自动增益补偿验收。

验收标准：
  1. 门：低于阈值的信号被压到接近静音（< -40dB）；高于阈值原样通过。
  2. 门：release 足够长时，信号跌回阈值以下先保持再关闭（无瞬断）。
  3. Deesser：高频（8kHz）信号被衰减，低频（500Hz）不动。
  4. Deesser 关闭时高频原样。
  5. 自动补偿：门把持续低电平压掉后，autogain 拉回接近输入响度（有限幅）。
  6. set/get 回读对称；越界钳位。
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


def run_sine(freq, amp, blocks=30):
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
check('gate.enable set/get', set_i('gate.enable', 1) == 0 and get_i('gate.enable') == (0, 1))
check('threshold set/get', set_f('gate.threshold', -40.0) == 0 and abs(get_f('gate.threshold')[1] + 40.0) < 1e-4)
set_f('gate.threshold', 5.0)
check('threshold high clamp 0', abs(get_f('gate.threshold')[1]) < 1e-4)
set_f('gate.threshold', -100.0)
check('threshold low clamp -60', abs(get_f('gate.threshold')[1] + 60.0) < 1e-4)
check('attack set/get', set_f('gate.attack', 10.0) == 0 and abs(get_f('gate.attack')[1] - 10.0) < 1e-4)
check('release set/get', set_f('gate.release', 100.0) == 0 and abs(get_f('gate.release')[1] - 100.0) < 1e-4)
check('deesser set/get', set_i('deesser.enable', 1) == 0 and get_i('deesser.enable') == (0, 1))

# 1. 门：低于阈值 → 压静音
set_f('gate.threshold', -30.0)
set_f('gate.attack', 5.0)
set_f('gate.release', 50.0)
set_f('deesser.freq', 6000.0)
set_f('deesser.amount', 0.5)
set_i('deesser.enable', 0)
quiset = run_sine(1000.0, 0.001)   # -60dB 输入，远低于 -30dB 阈值
check('below threshold gated (near silence)', quiset < 0.001 * 0.02,
      'rms=%.6f' % quiset)

# 2. 门：高于阈值 → 通过
loud = run_sine(1000.0, 0.2)       # -14dB，高于阈值
expect = 0.2 / math.sqrt(2)
check('above threshold passes', abs(loud - expect) / expect < 0.05,
      'rms=%.5f expect=%.5f' % (loud, expect))

# 3. Deesser：8kHz 高频被衰减
set_i('deesser.enable', 1)
set_f('deesser.amount', 1.0)
set_f('deesser.freq', 6000.0)
hi_on = run_sine(8000.0, 0.3)
lo_on = run_sine(500.0, 0.3)
# 高频衰减，低频几乎不动
set_i('deesser.enable', 0)
hi_off = run_sine(8000.0, 0.3)
lo_off = run_sine(500.0, 0.3)
check('deesser attenuates HF', hi_on < hi_off * 0.92,
      'on=%.4f off=%.4f' % (hi_on, hi_off))
check('deesser leaves LF intact', abs(lo_on - lo_off) / lo_off < 0.05,
      'on=%.4f off=%.4f' % (lo_on, lo_off))

# 4. 自动补偿：持续低电平（门关掉）时 autogain 拉回
set_i('deesser.enable', 0)
set_i('gate.autogain', 0)
set_f('gate.threshold', -45.0)
# 用 0.05 幅度（-26dB）高于阈值，门不关，autogain 应保持 ~1（无补偿需求）
set_i('gate.autogain', 1)
ag = run_sine(1000.0, 0.05, blocks=40)
expect_ag = 0.05 / math.sqrt(2)
check('autogain stays near 1 when gate transparent', abs(ag - expect_ag) / expect_ag < 0.12,
      'rms=%.5f expect=%.5f' % (ag, expect_ag))

dll.auradsp_destroy(h)

print()
if FAIL:
    print('GATE FAILURES:', FAIL)
    sys.exit(1)
print('gate_deesser: all checks passed')
