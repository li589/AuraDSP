"""smoke_ddc.py — VDC 空间校正验收。

验收标准：
  1. 未加载文件时使能 → 直通守卫（输出不变）。
  2. 加载真实 VDC（assets/ddc/Others/Butterworth.vdc）→ ready=1。
  3. 使能后输出相对旁通发生变化（校正滤波器生效）。
  4. set/get 回读对称。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'auradsp_engine.dll')
VDC = os.path.join(ROOT, 'assets', 'ddc', 'Others', 'Butterworth.vdc')

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


h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'


def set_i(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)


def set_str(pid, s):
    b = s.encode('utf-8')
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))


def get_i(pid):
    v = i32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def run_sine(freq, amp=0.2, blocks=24):
    n0 = 0
    outs = []
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            s = amp * math.sin(2 * math.pi * freq * (n0 + i) / SR)
            buf[i * 2] = s
            buf[i * 2 + 1] = s
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        n0 += BLOCK
        if b >= blocks - 2:
            outs.extend(out[i * 2] for i in range(BLOCK))
    return outs


expect = 0.2 / math.sqrt(2)

# 1. 未加载文件使能 → 允许使能并内部直通（输出不变）
rc = set_i('ddc.enable', 1)
check('enable w/o file accepted', rc == 0)
check('enable readback == 1', get_i('ddc.enable')[1] == 1)
outs = run_sine(1000.0)
rms = math.sqrt(sum(s * s for s in outs) / len(outs))
check('unloaded enable passes through', abs(rms - expect) / expect < 0.03, 'rms=%.5f' % rms)
set_i('ddc.enable', 0)

# 2/3. 加载真实 VDC（文件存在才跑，否则 SKIP 风格通过）
if not os.path.exists(VDC):
    print('SKIP file-dependent checks (no VDC)')
else:
    check('load real vdc', set_str('ddc.load', VDC) == 0)
    check('ready=1', get_i('ddc.ready') == (0, 1))
    set_i('ddc.enable', 1)
    outs_on = run_sine(500.0, blocks=32)
    set_i('ddc.enable', 0)
    outs_off = run_sine(500.0, blocks=32)
    diff = math.sqrt(sum((a - b) ** 2 for a, b in zip(outs_on, outs_off)) / len(outs_on))
    base = math.sqrt(sum(b * b for b in outs_off) / len(outs_off))
    check('enabled changes output (>1%)', diff > base * 0.01,
          'diff=%.5f base=%.4f' % (diff, base))

dll.auradsp_destroy(h)

print()
if FAIL:
    print('DDC FAILURES:', FAIL)
    sys.exit(1)
print('ddc: all checks passed')
