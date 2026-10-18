"""smoke_exciter.py — 激励器验收（spec §3）。

验收标准：
  1. 关闭/amount=0 时直通（RMS 一致）。
  2. 分频点以下（1kHz vs 5kHz 取频）：输出基本不变（HP 挡住基频）。
  3. 分频点以上（6kHz）：amount=1 注入可测谐波能量（RMS 上升）。
  4. 取频点越高（10kHz），同输入谐波增量越小（频率选择性）。
  5. 峰值有界（tanh 限幅，开满不炸）。
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


def get_i(pid):
    v = i32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def get_f(pid):
    v = f32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value


def run_sine(freq, amp=0.1, blocks=12):
    """跑 blocks 块同相正弦，返回最后一块 (RMS, peak)。"""
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
        if b == blocks - 1:
            acc = sum(out[i * 2] ** 2 for i in range(BLOCK)) / BLOCK
            rms = math.sqrt(acc)
            peak = max(abs(out[i * 2]) for i in range(BLOCK))
    return rms, peak


# 0. 回读对称 + 钳位
check('set enable/get', set_i('exciter.enable', 1) == 0 and get_i('exciter.enable') == (0, 1))
check('set amount/get', set_f('exciter.amount', 0.3) == 0 and abs(get_f('exciter.amount')[1] - 0.3) < 1e-6)
check('set hifreq/get', set_f('exciter.hifreq', 5000.0) == 0 and abs(get_f('exciter.hifreq')[1] - 5000.0) < 1e-3)
set_f('exciter.amount', 5.0)
check('amount high clamp 1', abs(get_f('exciter.amount')[1] - 1.0) < 1e-9)
set_f('exciter.amount', -1.0)
check('amount low clamp 0', abs(get_f('exciter.amount')[1] - 0.0) < 1e-9)
set_f('exciter.hifreq', 1000.0)
check('hifreq low clamp 3000', abs(get_f('exciter.hifreq')[1] - 3000.0) < 1e-3)
set_f('exciter.hifreq', 44100.0)
check('hifreq high clamp 10000', abs(get_f('exciter.hifreq')[1] - 10000.0) < 1e-3)
set_f('exciter.hifreq', 5000.0)
set_f('exciter.amount', 1.0)

# 1. 关闭直通
set_i('exciter.enable', 0)
rms_off, _ = run_sine(6000.0)
set_i('exciter.enable', 1)
set_f('exciter.amount', 0.0)
rms_zero, _ = run_sine(6000.0)
expect = 0.1 / math.sqrt(2)
check('disabled passthrough', abs(rms_off - expect) / expect < 0.02,
      'rms=%.5f expect=%.5f' % (rms_off, expect))
check('amount=0 passthrough', abs(rms_zero - expect) / expect < 0.02,
      'rms=%.5f' % rms_zero)

# 2. 分频点以下近直通（one-pole 非砖墙：1kHz@5k 分频 HP 放过 19.6%，
#    amount=1 时给 +3.3% RMS 属模拟器正常行为，故容差放宽到 6%）
#    谐波能量测量在 oversample=0（1x）模式下执行，以便 tanhf 谐波直接叠加在信号上
#    而不被 FIR 截止；2x 过采样抗混叠验证由 smoke_oversample_aliasing.py 覆盖。
set_f('exciter.amount', 1.0)
set_i('exciter.oversample', 0)   # 功能验证：1x 模式，保持原有谐波注入语义
rms_1k, _ = run_sine(1000.0)
check('1kHz below crossover near-untouched (<6% lift)', rms_1k < rms_zero * 1.06,
      'rms=%.5f' % rms_1k)

# 3. 分频点以上注入谐波能量（且明显强于分频点以下）
rms_6k, peak_6k = run_sine(6000.0)
check('6kHz gains harmonic energy (>5%)', rms_6k > rms_zero * 1.05,
      'on=%.5f off=%.5f' % (rms_6k, rms_zero))
check('6kHz lift > 1kHz lift (frequency selective)', (rms_6k - rms_zero) > (rms_1k - rms_zero),
      '6k=%.5f 1k=%.5f' % (rms_6k, rms_1k))
check('peak bounded (<0.3 at 0.1 in)', peak_6k < 0.3, 'peak=%.4f' % peak_6k)

# 4. 取频点越高，同输入增量越小
set_f('exciter.hifreq', 10000.0)
rms_6k_hi, _ = run_sine(6000.0)
check('higher crossover -> less lift', rms_6k_hi < rms_6k,
      'hi=%.5f lo=%.5f' % (rms_6k_hi, rms_6k))
set_i('exciter.oversample', 1)   # 恢复默认 2x HQ 模式

dll.auradsp_destroy(h)

print()
if FAIL:
    print('EXCITER FAILURES:', FAIL)
    sys.exit(1)
print('exciter: all checks passed')
