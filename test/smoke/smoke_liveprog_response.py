"""smoke_liveprog_response.py — Liveprog（立体声 / 多声道 MC）频率响应探针契约测试。

验证 `auradsp_probe_liveprog_response` 在独立隔离宿主中真实执行 EEL2 脚本
（含 @init / @slider / @sample、滑块参数注入、STFT/FIR 高延迟脚本、发生器
识别与 8 声道 MC 独立通道探测）：
  1. 直通脚本（spl0 = spl0）各频点接近 0 dB；
  2. 增益衰减脚本（spl0 *= gain）测出精确 -6.02 dB 增益；
  3. EqualizerAPO 生成的 RBJ Peaking EQ + Preamp 测出真实钟形增益；
  4. 内置 `peaking_eq` 模板随 slider1(freq)/slider2(gain)/slider3(Q) 动态变化；
  5. 高延迟 `stftFilter.eel` 与 `firFilter.eel` 测出真实阻带/低通衰减；
  6. 发生器脚本（pink_noise）诚实返回 0 dB 而非造假曲线；
  7. MC 宿主（multichannel=1）独立探测单声道 C (channel=2)，互不干扰 FL/FR；
  8. 同输入重复调用结果恒定，非法参数 / 语法错误安全返回非 0。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
DLL = os.path.join(
    ROOT, 'core', 'desktop', 'windows', 'out', 'Release', 'auradsp_engine.dll'
)

lib = ctypes.CDLL(DLL)
lib.auradsp_probe_liveprog_response.restype = ctypes.c_int
lib.auradsp_probe_liveprog_response.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_float),
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_double,
    ctypes.POINTER(ctypes.c_float),
]

F_MIN, F_MAX = 20.0, 20000.0
N = 129
FAIL = []


def probe(code, params=(), channel=-1, mc=False, sr=48000, n=N, fmax=F_MAX):
    buf = (ctypes.c_float * n)()
    n_params = len(params)
    if n_params > 0:
        p_arr = (ctypes.c_float * n_params)(*[float(v) for v in params])
    else:
        p_arr = ctypes.POINTER(ctypes.c_float)()
    rc = lib.auradsp_probe_liveprog_response(
        sr,
        code.encode('utf-8') if code is not None else None,
        p_arr,
        n_params,
        channel,
        1 if mc else 0,
        n,
        fmax,
        buf,
    )
    return rc, list(buf)


def sample_at(db_list, freqs):
    lf0, lf1 = math.log(F_MIN), math.log(F_MAX)
    xs = [math.exp(lf0 + i / (N - 1) * (lf1 - lf0)) for i in range(N)]
    out = []
    for f in freqs:
        if f <= xs[0]:
            out.append(db_list[0])
            continue
        if f >= xs[-1]:
            out.append(db_list[-1])
            continue
        i = max(j for j in range(N - 1) if xs[j] <= f)
        t = (f - xs[i]) / (xs[i + 1] - xs[i])
        out.append(db_list[i] + t * (db_list[i + 1] - db_list[i]))
    return out


def check(name, cond, detail=''):
    if cond:
        print('  [PASS] %s' % name)
    else:
        print('  [FAIL] %s  %s' % (name, detail))
        FAIL.append(name)


print('=== Liveprog 响应探针测试 ===')

# 1) 直通脚本
PASS_EEL = """
@init
x = 0;
@sample
spl0 = spl0;
spl1 = spl1;
"""
rc, raw_pass = probe(PASS_EEL)
check('直通脚本返回成功', rc == 0, 'rc=%d' % rc)
if rc == 0:
    vals = sample_at(raw_pass, [20, 100, 1000, 10000, 20000])
    worst = max(abs(v) for v in vals)
    check('直通脚本全频段 <= 0.05 dB', worst < 0.05,
          'worst=%.4f %s' % (worst, vals))

# 2) -6.02 dB 增益衰减脚本
GAIN_EEL = """
slider1:-6.0<-24,12,0.5>Gain (dB)
@init
g = 1.0;
@slider
g = 10 ^ (slider1 / 20);
@sample
spl0 *= g;
spl1 *= g;
"""
rc, raw_gain = probe(GAIN_EEL, params=[-6.0])
check('增益脚本返回成功', rc == 0, 'rc=%d' % rc)
if rc == 0:
    vals = sample_at(raw_gain, [50, 1000, 15000])
    err = max(abs(v - (-6.0)) for v in vals)
    check('-6dB 滑块准确反映在全频段', err < 0.15,
          'vals=%s err=%.3f' % (vals, err))

# 3) EqualizerAPO 风格 RBJ Peaking EQ + Preamp
APO_RBJ_EEL = """
@init
PI = 3.141592653589793;
g_pre = 10 ^ (-3.0 / 20);
w0 = 2 * PI * 1000 / srate;
alpha = sin(w0) / (2 * 2.0);
A = 10 ^ (6.0 / 40);
a0 = 1 + alpha / A;
b0 = (1 + alpha * A) / a0;
b1 = (-2 * cos(w0)) / a0;
b2 = (1 - alpha * A) / a0;
a1 = (-2 * cos(w0)) / a0;
a2 = (1 - alpha / A) / a0;
xl1=xl2=yl1=yl2=xr1=xr2=yr1=yr2=0;
@sample
ynl = b0*spl0 + b1*xl1 + b2*xl2 - a1*yl1 - a2*yl2;
xl2=xl1; xl1=spl0; yl2=yl1; yl1=ynl; spl0 = ynl * g_pre;
ynr = b0*spl1 + b1*xr1 + b2*xr2 - a1*yr1 - a2*yr2;
xr2=xr1; xr1=spl1; yr2=yr1; yr1=ynr; spl1 = ynr * g_pre;
"""
rc, raw_apo = probe(APO_RBJ_EEL)
check('EqualizerAPO RBJ 脚本返回成功', rc == 0, 'rc=%d' % rc)
if rc == 0:
    v50, v1k, v15k = sample_at(raw_apo, [50, 1000, 15000])
    check('Preamp -3dB + 1kHz +6dB 在 1kHz 接近 +3dB、两端接近 -3dB',
          abs(v1k - 3.0) < 0.35 and abs(v50 - (-3.0)) < 0.35
          and abs(v15k - (-3.0)) < 0.35,
          '50=%.2f 1k=%.2f 15k=%.2f' % (v50, v1k, v15k))

# 4) 模板类 slider1/2/3 Peaking 交互与可重复性
PEAK_EEL = """
slider1:1000<100,10000,10>Frequency (Hz)
slider2:0.0<-18,18,0.5>Gain (dB)
slider3:1.41<0.1,10,0.05>Q Factor
@init
PI = 3.141592653589793;
b0=1; b1=0; b2=0; a1=0; a2=0; x1=x2=y1=y2=r1=r2=z1=z2=0;
@slider
w0 = 2 * PI * slider1 / srate;
alpha = sin(w0) / (2 * slider3);
A = 10 ^ (slider2 / 40);
a0 = 1 + alpha / A;
b0 = (1 + alpha * A) / a0;
b1 = (-2 * cos(w0)) / a0;
b2 = (1 - alpha * A) / a0;
a1 = (-2 * cos(w0)) / a0;
a2 = (1 - alpha / A) / a0;
@sample
yl = b0*spl0 + b1*x1 + b2*x2 - a1*y1 - a2*y2;
x2=x1; x1=spl0; y2=y1; y1=yl; spl0=yl;
yr = b0*spl1 + b1*r1 + b2*r2 - a1*z1 - a2*z2;
r2=r1; r1=spl1; z2=z1; z1=yr; spl1=yr;
"""
rc_a, raw_peak_a = probe(PEAK_EEL, params=[2500.0, 8.0, 2.0])
rc_b, raw_peak_b = probe(PEAK_EEL, params=[2500.0, 8.0, 2.0])
check('滑块峰值脚本双次结果一致（确定性）', rc_a == 0 and rc_b == 0 and raw_peak_a == raw_peak_b)
if rc_a == 0:
    v100, v2k5, v16k = sample_at(raw_peak_a, [100, 2500, 16000])
    check('2.5kHz +8dB 峰值准确且旁带归零',
          7.3 < v2k5 < 8.5 and abs(v100) < 0.2 and abs(v16k) < 0.4,
          '100=%.2f 2.5k=%.2f 16k=%.2f' % (v100, v2k5, v16k))

# 5) 高延迟 STFT & FIR 实脚本验证
stft_path = os.path.join(ROOT, 'assets', 'liveprog', 'filters_eq', 'stftFilter.eel')
fir_path = os.path.join(ROOT, 'assets', 'liveprog', 'filters_eq', 'firFilter.eel')
with open(stft_path, encoding='utf-8') as f:
    stft_code = f.read()
with open(fir_path, encoding='utf-8') as f:
    fir_code = f.read()

rc_stft, raw_stft = probe(stft_code)
check('stftFilter.eel 探针返回成功', rc_stft == 0, 'rc=%d' % rc_stft)
if rc_stft == 0:
    vs_lo, vs_hi = sample_at(raw_stft, [500, 8000])
    check('STFT 高频阻带深衰减且低频通带不失真',
          abs(vs_lo) < 1.5 and vs_hi < -40.0,
          '500Hz=%.2f 8kHz=%.2f' % (vs_lo, vs_hi))

rc_fir, raw_fir = probe(fir_code)
check('firFilter.eel 探针返回成功', rc_fir == 0, 'rc=%d' % rc_fir)
if rc_fir == 0:
    vf_lo, vf_mid, vf_hi = sample_at(raw_fir, [200, 10000, 18000])
    check('FIR 低通高频滚降准确',
          abs(vf_lo) < 1.5 and vf_mid < -15.0 and vf_hi < -45.0,
          '200=%.2f 10k=%.2f 18k=%.2f' % (vf_lo, vf_mid, vf_hi))

# 6) 粉红噪声发生器不误报增益或噪声尖峰
PINK_EEL = """
slider1:-20<-60,0,1>Noise Level (dBFS)
@init
mem = 0;
InitPinkNoise(mem, 16);
@slider
vol = 10 ^ (slider1 / 20);
@sample
noise = GeneratePinkNoise(mem, 1.0) * vol;
spl0 = noise;
spl1 = noise;
"""
rc_pink, raw_pink = probe(PINK_EEL, params=[-20.0])
check('发生器脚本返回成功且诚实归零',
      rc_pink == 0 and max(abs(v) for v in raw_pink) < 0.05,
      'rc=%d max=%.4f' % (rc_pink, max(abs(v) for v in raw_pink) if rc_pink == 0 else -1))

# 7) 多声道 MC 宿主单声道独立响应 (spl2 = C 声道 -6 dB, 其余直通)
MC_EEL = """
slider1:-6<-24,12,1>Center Gain (dB)
@init
gc = 1.0;
@slider
gc = 10 ^ (slider1 / 20);
@sample
spl2 *= gc;
"""
rc_mc0, raw_mc0 = probe(MC_EEL, params=[-6.0], channel=0, mc=True)
rc_mc2, raw_mc2 = probe(MC_EEL, params=[-6.0], channel=2, mc=True)
check('MC 宿主单独探测 C(2) vs FL(0) 独立无串扰',
      rc_mc0 == 0 and rc_mc2 == 0
      and max(abs(v) for v in sample_at(raw_mc0, [100, 1000, 10000])) < 0.05
      and max(abs(v - (-6.0)) for v in sample_at(raw_mc2, [100, 1000, 10000])) < 0.15,
      'FL[1k]=%.2f C[1k]=%.2f' % (sample_at(raw_mc0, [1000])[0], sample_at(raw_mc2, [1000])[0]))

# 8) 非法输入安全拒绝
rc_empty, _ = probe('   ')
rc_bad, _ = probe('@sample\n invalid(((')
rc_ch_bad, _ = probe(PASS_EEL, channel=2, mc=False)
check('空代码/语法错误/声道越界全部返回非0',
      rc_empty != 0 and rc_bad != 0 and rc_ch_bad != 0,
      'empty=%d bad=%d ch=%d' % (rc_empty, rc_bad, rc_ch_bad))

print('\n=== Liveprog 探针检查完成，失败数: %d ===' % len(FAIL))
sys.exit(1 if FAIL else 0)
