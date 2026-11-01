"""smoke_tube.py — 电子管模拟器验收。

验收标准：
  1. 关闭/增益 0dB 时直通（线性残差 <0.5%）。
  2. 增益 12dB 时产生可测谐波（相对线性拟合的残差 >2%）。
  3. 软削波：峰值小于线性预测（被压缩）。
  4. set/get 回读对称。
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


def run_sine(freq, amp, blocks=16):
    n0 = 0
    xs, ys = [], []
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
            for i in range(BLOCK):
                xs.append(buf[i * 2])
                ys.append(out[i * 2])
    return xs, ys


def linfit_residual(xs, ys):
    n = len(xs)
    dot_xy = sum(x * y for x, y in zip(xs, ys))
    dot_xx = sum(x * x for x in xs)
    g = dot_xy / dot_xx if dot_xx > 0 else 0.0
    res = math.sqrt(sum((y - g * x) ** 2 for x, y in zip(xs, ys)) / n)
    sig = math.sqrt(sum(y * y for y in ys) / n)
    peak = max(abs(y) for y in ys)
    return g, res, sig, peak


# 0. 回读
check('enable set/get', set_i('tube.enable', 1) == 0 and get_i('tube.enable') == (0, 1))
check('gain set/get', set_f('tube.gain', 6.0) == 0 and abs(get_f('tube.gain')[1] - 6.0) < 1e-6)
set_i('tube.enable', 0)

# 1. 关闭直通（线性）
xs, ys = run_sine(1000.0, 0.2)
_, res, sig, _ = linfit_residual(xs, ys)
check('disabled linear (<0.5% residual)', res < sig * 0.005,
      'res=%.6f sig=%.4f' % (res, sig))

# 2/3. 开启 12dB：有谐波 + 软削波
set_i('tube.enable', 1)
set_f('tube.gain', 12.0)
xs, ys = run_sine(1000.0, 0.2, blocks=24)
g, res, sig, peak = linfit_residual(xs, ys)
check('12dB harmonics present (>2%)', res > sig * 0.02,
      'res=%.5f sig=%.4f' % (res, sig))
linear_peak = 0.2 * (10.0 ** (12.0 / 20.0))
check('soft saturation (peak < linear)', peak < linear_peak * 0.98,
      'peak=%.4f linear=%.4f' % (peak, linear_peak))

# P-011: set/get 回读 + 钳位
check('style set/get', set_i('tube.style', 1) == 0 and get_i('tube.style') == (0, 1))
check('mix set/get', set_f('tube.mix', 0.5) == 0 and abs(get_f('tube.mix')[1] - 0.5) < 1e-6)
check('comp set/get', set_f('tube.compensation', 3.0) == 0 and abs(get_f('tube.compensation')[1] - 3.0) < 1e-6)
set_i('tube.style', 9)
check('style clamp 9->2', get_i('tube.style') == (0, 2))
set_f('tube.mix', 2.0)
check('mix clamp 2->1', abs(get_f('tube.mix')[1] - 1.0) < 1e-6)
set_f('tube.compensation', -20.0)
check('comp clamp -20->-12', abs(get_f('tube.compensation')[1] + 12.0) < 1e-6)
set_f('tube.mix', 1.0)
set_f('tube.compensation', 0.0)


def goertzel_power(ys, freq, sr=None):
    # 单频点 DFT 功率（稳态段）：线性拟合残差会被全通相移污染，谐波能量必须直测。
    n = len(ys)
    w = 2 * math.pi * freq / (SR if sr is None else sr)
    cw, sw = math.cos(w), math.sin(w)
    s0 = s1 = s2 = 0.0
    for y in ys:
        s0 = y + 2 * cw * s1 - s2
        s2 = s1
        s1 = s0
    real = cw * s1 - s2
    imag = sw * s1
    return (real * real + imag * imag) / (n * n)


def harmonic_profile(amp=0.2, freq=1000.0):
    _, ys = run_sine(freq, amp, blocks=40)
    fund = goertzel_power(ys, freq)
    harm = sum(goertzel_power(ys, freq * k) for k in (2, 3, 4, 5))
    rms = math.sqrt(sum(y * y for y in ys) / len(ys))
    return (harm / fund if fund > 0 else 0.0), rms, math.sqrt(fund)


# P-011: 三档音色谐波量有序（pentode > triode > tape），Goertzel 直测谐波功率。
# 条件必须落在分频器平方项有效区：1000Hz/0.2/+12dB（与上组 legacy 同条件）。
# 440Hz 处平方项只有 -36dB（ penny 1.48x）无分辨力；线性拟合残差则被全通相移污染。
#（实测比值：pen/tri≈3.3x，tri/tape≈4.4x；断言留足余量。）
set_i('tube.style', 0)
tri_h, tri_rms, tri_f = harmonic_profile()
set_i('tube.style', 1)
pen_h, pen_rms, pen_f = harmonic_profile()
set_i('tube.style', 2)
tape_h, tape_rms, tape_f = harmonic_profile()
print('  style harm-ratio: tri=%.5f pen=%.5f tape=%.5f' % (tri_h, pen_h, tape_h))
print('  style fund-rms: tri=%.5f pen=%.5f tape=%.5f' % (tri_f, pen_f, tape_f))
check('pentode hotter than triode', pen_h > tri_h * 2.0,
      'pen=%.5f tri=%.5f' % (pen_h, tri_h))
check('triode hotter than tape', tri_h > tape_h * 2.5,
      'tri=%.5f tape=%.5f' % (tape_h, tri_h))
for nm, a, b in (('pen/tri', pen_rms, tri_rms), ('tape/tri', tape_rms, tri_rms)):
    ratio = a / b if b > 0 else 0.0
    check('level-neutral %s (rms ratio <1.122)' % nm, 0.891 < ratio < 1.122,
          'ratio=%.4f' % ratio)

# P-011: mix=0 近似直通
set_i('tube.style', 0)
set_f('tube.mix', 0.0)
xs, ys = run_sine(1000.0, 0.2)
_, res, sig, _ = linfit_residual(xs, ys)
check('mix=0 passthrough (<0.5%)', res < sig * 0.005,
      'res=%.6f sig=%.4f' % (res, sig))

# P-011: compensation +6dB 精确命中（相对 0dB）
set_f('tube.mix', 1.0)
set_f('tube.compensation', 0.0)
_, ys0 = run_sine(1000.0, 0.2)
rms0 = math.sqrt(sum(y * y for y in ys0) / len(ys0))
set_f('tube.compensation', 6.0)
_, ys6 = run_sine(1000.0, 0.2)
rms6 = math.sqrt(sum(y * y for y in ys6) / len(ys6))
ratio = rms6 / rms0 if rms0 > 0 else 0.0
check('comp +6dB ~= x2 (5%)', abs(ratio - 2.0) < 0.10, 'ratio=%.4f' % ratio)
set_f('tube.compensation', 0.0)

# A-06: 2x 过采样低通必须把 20 kHz 留在通带内，且 44.1k/48k 工作域一致。
# 原实现按 0.89*Nyquist 设截止：44.1k 域截止 19.6k，20k 落进 16 阶
# Butterworth 过渡带，整链 20k 塌陷 -10.6 dB；48k 域仅 -0.46 dB。
# 现改为固定绝对截止 21 kHz（低采样率钳到 0.95*Nyquist）。
def tube_fund_db(sr, freq=20000.0, amp=10.0 ** (-24.0 / 20.0), blocks=40):
    hh = dll.auradsp_create(float(sr), BLOCK)
    assert hh, 'create failed for %d' % sr
    def si(pid, v):
        return dll.auradsp_set_param(hh, pid.encode(), ctypes.byref(i32(v)), 4)
    def sf(pid, v):
        return dll.auradsp_set_param(hh, pid.encode(), ctypes.byref(f32(v)), 4)
    si('limiter.enable', 0)
    si('post.enable', 0)
    si('tube.enable', 1)
    si('tube.style', 0)
    si('tube.oversample', 1)
    sf('tube.gain', 0.0)
    sf('tube.mix', 1.0)
    n0 = 0
    ys = []
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            s = amp * math.sin(2 * math.pi * freq * (n0 + i) / sr)
            buf[i * 2] = s
            buf[i * 2 + 1] = s
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(hh, buf, out, BLOCK)
        n0 += BLOCK
        if b >= blocks - 8:
            ys.extend(out[i * 2] for i in range(BLOCK))
    dll.auradsp_destroy(hh)
    w = 2.0 * math.pi * freq / sr
    re = sum(y * math.cos(w * i) for i, y in enumerate(ys))
    im = sum(y * math.sin(w * i) for i, y in enumerate(ys))
    fund = 2.0 * math.sqrt(re * re + im * im) / len(ys)
    return 20.0 * math.log10(max(fund, 1e-12) / amp)

db441, db48 = tube_fund_db(44100), tube_fund_db(48000)
print('  tube 20k passband: 44.1k=%+.2f dB  48k=%+.2f dB' % (db441, db48))
check('tube 44.1k 20k passband (>-1.5dB)', db441 > -1.5, '%.2f dB' % db441)
check('tube 48k 20k passband (>-1.5dB)', db48 > -1.5, '%.2f dB' % db48)
check('tube 20k 44.1k/48k match (<0.3dB)', abs(db441 - db48) < 0.3,
      '44.1k=%.2f 48k=%.2f' % (db441, db48))

dll.auradsp_destroy(h)

print()
if FAIL:
    print('TUBE FAILURES:', FAIL)
    sys.exit(1)
print('tube: all checks passed')
