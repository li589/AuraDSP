"""smoke_input.py — 输入增益 + 声道平衡验收。

验收标准：
  1. input.gain +6dB → 双声道 RMS ×2；-6dB → ×0.5。
  2. balance.1=0.5 → 左声道减半，右声道不动；balance.2=2.0 → 右翻倍。
  3. 越界钳位（gain ±15，balance 0..2）；set/get 对称。
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


def run_sine(freq=1000.0, amp=0.2, blocks=12):
    n0 = 0
    rl = rr = 0.0
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
            rl += math.sqrt(sum(out[i * 2] ** 2 for i in range(BLOCK)) / BLOCK)
            rr += math.sqrt(sum(out[i * 2 + 1] ** 2 for i in range(BLOCK)) / BLOCK)
    return rl / 4.0, rr / 4.0


expect = 0.2 / math.sqrt(2)

# 0. 回读 + 钳位
check('gain set/get', set_f('input.gain', 6.0) == 0 and abs(get_f('input.gain')[1] - 6.0) < 1e-6)
set_f('input.gain', 99.0)
check('gain high clamp 15', abs(get_f('input.gain')[1] - 15.0) < 1e-6)
set_f('input.gain', 0.0)
check('balance set/get', set_f('input.balance.1', 0.5) == 0 and abs(get_f('input.balance.1')[1] - 0.5) < 1e-6)
set_f('input.balance.1', 9.0)
check('balance high clamp 2', abs(get_f('input.balance.1')[1] - 2.0) < 1e-6)
set_f('input.balance.1', 1.0)

# 1. 增益倍率
set_f('input.gain', 6.0)
rl, rr = run_sine()
check('+6dB doubles both (+-3%)', abs(rl / expect - 2.0) / 2.0 < 0.03 and abs(rr / expect - 2.0) / 2.0 < 0.03,
      'l=%.4f r=%.4f' % (rl, rr))
set_f('input.gain', -6.0)
rl, _ = run_sine()
check('-6dB halves (+-3%)', abs(rl / expect - 0.5) / 0.5 < 0.03, 'l=%.4f' % rl)
set_f('input.gain', 0.0)

# 2. 声道平衡独立
set_f('input.balance.1', 0.5)
rl, rr = run_sine()
check('balance.1 halves L only', abs(rl / expect - 0.5) / 0.5 < 0.03 and abs(rr - expect) / expect < 0.03,
      'l=%.4f r=%.4f' % (rl, rr))
set_f('input.balance.1', 1.0)
set_f('input.balance.2', 2.0)
rl, rr = run_sine()
check('balance.2 doubles R only', abs(rr / expect - 2.0) / 2.0 < 0.03 and abs(rl - expect) / expect < 0.03,
      'l=%.4f r=%.4f' % (rl, rr))
set_f('input.balance.2', 1.0)

# 2b. balance.3..8 通道前缀分支 set/get 对称（声学由 1/2 代表覆盖）
for _c in range(3, 9):
    check('balance.%d set/get' % _c,
          set_f('input.balance.%d' % _c, 1.5) == 0 and
          abs(get_f('input.balance.%d' % _c)[1] - 1.5) < 1e-6)
    set_f('input.balance.%d' % _c, 1.0)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('INPUT FAILURES:', FAIL)
    sys.exit(1)
print('input: all checks passed')
