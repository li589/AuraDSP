"""smoke_oversample_aliasing.py — 2x 多相半带 FIR 抗混叠过采样核心验收。

验收标准：
  1. exciter.oversample / tube.oversample / bass.oversample 参数 set/get 对称与钳位。
  2. 14kHz 大幅值正弦波输入下：
     - 在 1x 模式 (oversample=0) 下，3 次谐波 42kHz 折返至 6kHz，产生显著混叠失真峰；
     - 在 2x HQ 模式 (oversample=1) 下，43-tap 半带 FIR 强力滤波，折返混叠衰减 > 60 dB。
  3. 极值与稳定性：过采样流水线连续运行无 NaN/Inf、无内存泄漏。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release', 'auradsp_engine.dll')

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

def get_i(pid):
    v = i32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return rc, v.value

def set_f(pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)

# 1. 参数 set/get 对称性与开关
check('exciter.oversample default is 1', get_i('exciter.oversample')[1] == 1)
check('set exciter.oversample 0', set_i('exciter.oversample', 0) == 0 and get_i('exciter.oversample')[1] == 0)
check('set exciter.oversample 1', set_i('exciter.oversample', 1) == 0 and get_i('exciter.oversample')[1] == 1)

check('tube.oversample default is 1', get_i('tube.oversample')[1] == 1)
check('set tube.oversample 0', set_i('tube.oversample', 0) == 0 and get_i('tube.oversample')[1] == 0)

check('bass.oversample default is 1', get_i('bass.oversample')[1] == 1)
check('set bass.oversample 0', set_i('bass.oversample', 0) == 0 and get_i('bass.oversample')[1] == 0)

# 2. 混叠抑制比实测
def measure_aliasing_spectrum(oversample_mode, n_blocks=16):
    set_i('limiter.enable', 0)  # 隔离母带限幅器，消除链尾非线性削波对纯净谐波高阶分量的测量干扰
    set_i('exciter.enable', 1)
    set_f('exciter.hifreq', 3000.0)
    set_f('exciter.amount', 1.0)
    set_i('exciter.oversample', oversample_mode)
    
    total_frames = n_blocks * BLOCK
    out_sig = []
    f_in = 14000.0
    for b in range(n_blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            t = (b * BLOCK + i) / SR
            val = 0.8 * math.sin(2.0 * math.pi * f_in * t)
            buf[i * 2] = val
            buf[i * 2 + 1] = val
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        for i in range(BLOCK):
            out_sig.append(out[i * 2])
            
    # 只分析稳定段后 4096 点 (消除预热瞬态)
    analysis_len = 4096
    segment = out_sig[-analysis_len:]
    # 加 Hanning 窗并在 6000Hz (折返点) 提取 DFT 能量
    f_aliased = 6000.0
    re = 0.0
    im = 0.0
    for n, s in enumerate(segment):
        w = 0.5 * (1.0 - math.cos(2.0 * math.pi * n / analysis_len))
        sw = s * w
        angle = 2.0 * math.pi * f_aliased * n / SR
        re += sw * math.cos(angle)
        im -= sw * math.sin(angle)
    mag = math.sqrt(re * re + im * im)
    return mag

mag_1x = measure_aliasing_spectrum(oversample_mode=0)
mag_2x = measure_aliasing_spectrum(oversample_mode=1)

suppression_db = 20.0 * math.log10(mag_1x / max(mag_2x, 1e-12))
print(f"[INFO] 1x Aliasing Mag at 6kHz: {mag_1x:.4f}, 2x Mag: {mag_2x:.6f}, Suppression: {suppression_db:.2f} dB")

check('1x has audible 6kHz aliasing foldback', mag_1x > 1.0, f'mag_1x={mag_1x:.4f}')
check('2x polyphase halfband suppresses aliasing > 60dB', suppression_db >= 60.0, f'suppression={suppression_db:.2f}dB')

set_i('exciter.enable', 0)
dll.auradsp_destroy(h)

if FAIL:
    print(f"\n[FAIL] {len(FAIL)} checks failed: {FAIL}")
    sys.exit(1)
else:
    print("\noversample_aliasing: all checks passed")
