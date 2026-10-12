"""smoke_bassmono.py — BassMono 低频单声道化验收（spec §2）。

验收标准：
  1. 反相正弦（L=-R）低频段：开启后输出 ≈0（mono 抵消）。
  2. 反相正弦高频段：输出不变（高频直通）。
  3. -3dB 点 = 分频设定值（one-pole：|1-H| 在 w=1 处 -3dB）。
  4. 同相低频：电平不变（防实现把低频吃掉）。
  5. set/get 回读对称；越界值钳位不断言失败。
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
SETTLE_BLOCKS = 20

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


def run_sine(freq, amp=0.5, phase_r=0.0, blocks=SETTLE_BLOCKS + 1):
    """跑 blocks 块反相/同相正弦，返回最后一块左声道 RMS。"""
    out_rms = 0.0
    n0 = 0
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            t = (n0 + i) / SR
            s = amp * math.sin(2 * math.pi * freq * t)
            buf[i * 2] = s
            buf[i * 2 + 1] = amp * math.sin(2 * math.pi * freq * t + phase_r)
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        n0 += BLOCK
        if b == blocks - 1:
            acc = sum(out[i * 2] ** 2 for i in range(BLOCK)) / BLOCK
            out_rms = math.sqrt(acc)
    return out_rms


AMP_RMS = 0.5 / math.sqrt(2)  # 0.3536：直通时期望值

# 0. 回读对称 + 钳位
check('set enable/get', set_i('bassmono.enable', 1) == 0 and get_i('bassmono.enable') == (0, 1))
check('set freq/get', set_f('bassmono.freq', 200.0) == 0 and abs(get_f('bassmono.freq')[1] - 200.0) < 1e-6)
set_f('bassmono.freq', 5.0)
check('freq low clamp 20', abs(get_f('bassmono.freq')[1] - 20.0) < 1e-6)
set_f('bassmono.freq', 500.0)
check('freq high clamp 300', abs(get_f('bassmono.freq')[1] - 300.0) < 1e-6)
set_f('bassmono.freq', 120.0)

# 1. 关闭时反相低频直通（基线）
set_i('bassmono.enable', 0)
base_lo = run_sine(60.0, phase_r=math.pi)
check('disabled: antiphase LF passes', abs(base_lo - AMP_RMS) / AMP_RMS < 0.05,
      'rms=%.4f expect=%.4f' % (base_lo, AMP_RMS))

# 2. 开启后反相低频抵消（one-pole 在 f=fc/2 处理论值 0.447，10Hz 处 <-20dB）
set_i('bassmono.enable', 1)
off_lo = run_sine(60.0, phase_r=math.pi)
check('enabled: antiphase LF matches theory (0.447 +-10%)',
      abs(off_lo / AMP_RMS - 0.447) / 0.447 < 0.10,
      'ratio=%.4f' % (off_lo / AMP_RMS))
deep_lo = run_sine(10.0, phase_r=math.pi)
check('enabled: antiphase 10Hz deeply cancelled (<-17dB)',
      deep_lo < AMP_RMS * 0.15, 'rms=%.5f' % deep_lo)

# 3. 反相高频直通
off_hi = run_sine(1000.0, phase_r=math.pi)
check('enabled: antiphase HF passes', abs(off_hi - AMP_RMS) / AMP_RMS < 0.05,
      'rms=%.4f expect=%.4f' % (off_hi, AMP_RMS))

# 4. -3dB 点 = 120Hz（相对 2kHz 参考）
ref = run_sine(2000.0, phase_r=math.pi)
at_fc = run_sine(120.0, phase_r=math.pi)
ratio = at_fc / ref if ref > 0 else 0.0
check('-3dB point at fc (0.707 +-15%)', abs(ratio - 0.707) / 0.707 < 0.15,
      'ratio=%.3f' % ratio)

# 5. 同相低频电平不变
inphase = run_sine(60.0, phase_r=0.0)
check('enabled: inphase LF untouched', abs(inphase - AMP_RMS) / AMP_RMS < 0.05,
      'rms=%.4f expect=%.4f' % (inphase, AMP_RMS))

dll.auradsp_destroy(h)

print()
if FAIL:
    print('BASSMONO FAILURES:', FAIL)
    sys.exit(1)
print('bassmono: all checks passed')
