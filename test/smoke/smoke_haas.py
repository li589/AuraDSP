"""smoke_haas.py — Haas 差分环绕验收（spec §1）。

验收标准：
  1. 脉冲实测右声道延迟 = 设定值 ±1 采样（12ms@48k = 576）。
  2. 左声道恒直通（脉冲在 0 处）。
  3. mix=0 与 bypass：右声道脉冲也在 0 处（干声）。
  4. 关闭时：右声道脉冲在 0 处。
  5. 改延迟 5ms → 240 采样。
  6. set/get 回读对称；越界钳位。
"""
import ctypes
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


def get_i(pid):
    v = i32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def get_f(pid):
    v = f32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def impulse_peak_ch1(nblocks=4):
    """首块 0 采样打 0.5 脉冲（L/R），返回右声道首个过阈采样下标 + 左声道下标。"""
    total = nblocks * BLOCK
    right = []
    left = []
    for b in range(nblocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        if b == 0:
            buf[0] = 0.5
            buf[1] = 0.5
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        for i in range(BLOCK):
            left.append(out[i * 2])
            right.append(out[i * 2 + 1])

    def first_over(xs, th=0.1):
        for i, v in enumerate(xs):
            if abs(v) > th:
                return i
        return -1

    return first_over(left), first_over(right), right


# 0. 回读对称 + 钳位
check('set enable/get', set_i('haas.enable', 1) == 0 and get_i('haas.enable') == (0, 1))
check('set delay/get', set_f('haas.delay', 12.0) == 0 and abs(get_f('haas.delay')[1] - 12.0) < 1e-9)
check('set mix/get', set_f('haas.mix', 0.6) == 0 and abs(get_f('haas.mix')[1] - 0.6) < 1e-6)
set_f('haas.delay', -3.0)
check('delay low clamp 0', abs(get_f('haas.delay')[1] - 0.0) < 1e-9)
set_f('haas.delay', 99.0)
check('delay high clamp 25', abs(get_f('haas.delay')[1] - 25.0) < 1e-9)
set_f('haas.mix', 2.0)
check('mix high clamp 1', abs(get_f('haas.mix')[1] - 1.0) < 1e-9)
set_f('haas.delay', 12.0)
set_f('haas.mix', 1.0)

# 1+2. 开启：左 0 处，右 576 处
li, ri, _ = impulse_peak_ch1()
check('enabled: left dry at 0', li == 0, 'left=%d' % li)
check('enabled: right delayed 576 +-1', abs(ri - 576) <= 1, 'right=%d' % ri)

# 3. mix=0：右回 0 处
set_f('haas.mix', 0.0)
_, ri0, _ = impulse_peak_ch1()
check('mix=0: right dry at 0', ri0 == 0, 'right=%d' % ri0)
set_f('haas.mix', 1.0)

# 4. 关闭：右回 0 处
set_i('haas.enable', 0)
_, ri_off, _ = impulse_peak_ch1()
check('disabled: right at 0', ri_off == 0, 'right=%d' % ri_off)

# 5. 改延迟 5ms → 240
set_i('haas.enable', 1)
set_f('haas.delay', 5.0)
_, ri5, _ = impulse_peak_ch1()
check('delay 5ms -> 240 +-1', abs(ri5 - 240) <= 1, 'right=%d' % ri5)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('HAAS FAILURES:', FAIL)
    sys.exit(1)
print('haas: all checks passed')
