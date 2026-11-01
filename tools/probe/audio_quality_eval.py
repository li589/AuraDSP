# -*- coding: utf-8 -*-
"""audio_quality_eval.py — 专业音频质量与出厂预设数据评估探针（非门禁）。

用途：以真实引擎 DLL 为被测对象，输出可复现的客观数据，供
`docs/30-审查/高性能专业音频系统评估-2026-11-01.md` 引用。

覆盖：
  1. 静默 / 直通基线：噪声底、THD+N、输出峰值、延迟；
  2. 出厂预设：频响（脉冲响应直通段）、THD+N、噪声底、最大输出、
     限幅余量、混响 RT60、CPU 成本；
  3. 采样率 44.1/48/96/192k 的频响与延迟一致性；
  4. 多声道 2/6/8ch 离散与矩阵模式的串音 / 通道独立性；
  5. 限幅器压力：0 dBFS 正弦、宽带噪声、lookahead 开/关；
  6. 现有 bench 未覆盖的预设级数据（预设即链路）。

不修改仓库、不写持久化状态；中间 JSON 写到 build/ 下。

运行：
  python tools/probe/audio_quality_eval.py
  python tools/probe/audio_quality_eval.py --quick
"""
import ctypes
import json
import math
import os
import sys
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release', 'auradsp_engine.dll')
PRESET_DIR = os.path.join(ROOT, 'app', 'auradsp_app', 'assets', 'presets', 'factory')
OUT_JSON = os.path.join(ROOT, 'build', 'audio_quality_eval.json')

SR = 48000
BLOCK = 480

lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p,
                                np.ctypeslib.ndpointer(dtype=np.float32, flags='C_CONTIGUOUS'),
                                np.ctypeslib.ndpointer(dtype=np.float32, flags='C_CONTIGUOUS'),
                                ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_get_param.restype = ctypes.c_int32
lib.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_get_latency_ms.restype = ctypes.c_double
lib.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]
lib.auradsp_version.restype = ctypes.c_char_p
lib.auradsp_abi.restype = ctypes.c_uint32

ALL_ENABLE = [
    'tube.enable', 'comp.enable', 'convolver.enable', 'ddc.enable', 'arbmag.enable',
    'bass.enable', 'eq.enable', 'freeverb.enable', 'dyneq.enable', 'stereo.enable',
    'haas.enable', 'crossfeed.enable', 'spatial.enable', 'bassmono.enable',
    'shelf.enable', 'filter.enable', 'exciter.enable', 'gate.enable',
    'deesser.enable', 'loudness.enable', 'liveprog.enable', 'limiter.enable',
]


def f32(v):
    return ctypes.c_float(float(v))


def i32(v):
    return ctypes.c_int32(int(v))


class Engine:
    def __init__(self, sr=SR, block=BLOCK, channels=2):
        self.sr = float(sr)
        self.block = int(block)
        self.channels = int(channels)
        self.h = lib.auradsp_create(self.sr, self.block)
        if not self.h:
            raise RuntimeError('auradsp_create failed')
        self._buf_in = np.zeros(self.block * self.channels, dtype=np.float32)
        self._buf_out = np.zeros(self.block * self.channels, dtype=np.float32)

    def close(self):
        if self.h:
            lib.auradsp_destroy(self.h)
            self.h = None

    def set_f(self, key, val):
        return lib.auradsp_set_param(self.h, key.encode(), ctypes.byref(f32(val)), 4)

    def set_i(self, key, val):
        return lib.auradsp_set_param(self.h, key.encode(), ctypes.byref(i32(val)), 4)

    def set_s(self, key, text):
        b = text.encode('utf-8')
        buf = (ctypes.c_char * max(1, len(b))).from_buffer_copy(b or b'\0')
        return lib.auradsp_set_param(self.h, key.encode(), buf, len(b))

    def get_f(self, key):
        v = ctypes.c_float()
        rc = lib.auradsp_get_param(self.h, key.encode(), ctypes.byref(v), 4)
        return rc, float(v.value)

    def get_i(self, key):
        v = ctypes.c_int32()
        rc = lib.auradsp_get_param(self.h, key.encode(), ctypes.byref(v), 4)
        return rc, int(v.value)

    def process(self, x):
        """x: (frames, channels) float32; returns same shape."""
        n = x.shape[0]
        assert n == self.block, 'block size must match create()'
        assert x.shape[1] == self.channels, 'channel count must match create()'
        self._buf_in[:] = x.reshape(-1)
        lib.auradsp_process(self.h, self._buf_in, self._buf_out, self.block)
        return self._buf_out.reshape(-1, self.channels).copy()

    def render(self, x):
        """Render arbitrary length by block chunks. x: (N, channels)."""
        n = x.shape[0]
        c = self.channels
        out = np.empty((n, c), dtype=np.float32)
        i = 0
        while i < n:
            m = min(self.block, n - i)
            if m < self.block:
                pad = np.zeros((self.block - m, c), dtype=np.float32)
                chunk = np.vstack([x[i:i + m], pad])
            else:
                chunk = x[i:i + m]
            y = self.process(chunk)
            out[i:i + m] = y[:m]
            i += m
        return out

    def disable_all(self):
        for key in ALL_ENABLE:
            self.set_i(key, 0)
        self.set_i('limiter.enable', 0)

    def latency_ms(self):
        return float(lib.auradsp_get_latency_ms(self.h))


# ---------------------------------------------------------------- EQ / preset

def eq_peaking_db(f, center, gain_db, q, sr):
    if abs(gain_db) < 1e-9 or center <= 0 or sr <= 0:
        return np.zeros_like(np.asarray(f, dtype=float))
    q = min(max(q, 0.3), 10.0)
    a = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * center / sr
    alpha = math.sin(w0) / (2.0 * q)
    cw = math.cos(w0)
    b0 = 1.0 + alpha * a
    b1 = -2.0 * cw
    b2 = 1.0 - alpha * a
    a0 = 1.0 + alpha / a
    a1 = -2.0 * cw
    a2 = 1.0 - alpha / a
    w = 2.0 * math.pi * np.asarray(f, dtype=float) / sr
    cw = np.cos(w)
    c2w = np.cos(2 * w)
    sw = np.sin(w)
    s2w = np.sin(2 * w)
    num_re = b0 + b1 * cw + b2 * c2w
    num_im = -(b1 * sw + b2 * s2w)
    den_re = a0 + a1 * cw + a2 * c2w
    den_im = -(a1 * sw + a2 * s2w)
    mag_sq = (num_re ** 2 + num_im ** 2) / np.maximum(den_re ** 2 + den_im ** 2, 1e-30)
    return 10.0 * np.log10(np.maximum(mag_sq, 1e-30))


def build_eq_curve(eq, sr=SR):
    freqs = list(eq.get('frequencies') or [])
    gains = list(eq.get('gains') or [])
    qs = list(eq.get('qs') or [eq.get('q', 1.414)] * len(freqs))
    nyq = min(20000.0, sr / 2.0)
    axis = []
    if freqs and freqs[0] > 20:
        axis.append(20.0)
    for f in freqs:
        axis.append(min(float(f), nyq))
    if freqs and freqs[-1] < nyq:
        axis.append(nyq)
    axis = np.array(axis, dtype=float)
    total = np.zeros_like(axis)
    for c, g, q in zip(freqs, gains, qs):
        total += eq_peaking_db(axis, float(c), float(g), float(q), sr)
    total = np.clip(total, -18.0, 18.0)
    interp = int(eq.get('interp', 1))
    opmode = {1: 2, 2: 5}.get(int(eq.get('filter', 0)), 0)
    body = ';'.join('%.1f:%.1f' % (f, g) for f, g in zip(axis, total))
    return 'eqm:%d:%d;%s' % (interp, opmode, body), axis, total


def apply_preset(engine, preset):
    p = preset['params']
    engine.disable_all()
    inp = p.get('input', {})
    engine.set_f('input.gain', inp.get('gain', 0.0))
    engine.set_f('input.balance.1', inp.get('balanceL', 1.0))
    engine.set_f('input.balance.2', inp.get('balanceR', 1.0))

    b = p.get('bass', {})
    if b.get('enable'):
        engine.set_f('bass.gain', min(15.0, max(0.0, float(b.get('intensity', 0.0)) * 15.0)))
        engine.set_i('bass.mode', b.get('mode', 0))
        engine.set_f('bass.cutoff', b.get('cutoff', 120.0))
        engine.set_f('bass.harmonics', b.get('harmonics', 0.0))
        engine.set_f('bass.harmonicblend', b.get('harmonicBlend', 0.5))
        engine.set_f('bass.subfreq', b.get('subFloor', 25.0))
        engine.set_f('bass.outgain', b.get('outputGain', 0.0))
        engine.set_i('bass.autogain', 1 if b.get('autoGain') else 0)
        engine.set_i('bass.enable', 1)

    t = p.get('tube', {})
    if t.get('enable'):
        engine.set_f('tube.gain', t.get('gain', 0.0))
        engine.set_i('tube.style', t.get('style', 0))
        engine.set_f('tube.compensation', t.get('compensation', 0.0))
        engine.set_f('tube.mix', t.get('mix', 1.0))
        engine.set_f('tube.outgain', t.get('outputGain', 0.0))
        engine.set_i('tube.autogain', 1 if t.get('autoGain') else 0)
        engine.set_i('tube.oversample', 1 if t.get('oversample') else 0)
        engine.set_i('tube.enable', 1)

    eq = p.get('eq', {})
    if eq.get('enable') and not eq.get('bypass', False):
        curve, _, _ = build_eq_curve(eq, engine.sr)
        engine.set_s('eq.curve', curve)
        engine.set_f('eq.outgain', eq.get('outputGain', 0.0))
        engine.set_i('eq.autogain', 1 if eq.get('autoGain') else 0)
        engine.set_i('eq.enable', 1)

    rv = p.get('reverb', {})
    if rv.get('enable'):
        preset_id = int(rv.get('preset', -1))
        if preset_id >= 0:
            engine.set_i('reverb.preset', preset_id)
        elif preset_id == -2:
            for k, v in [('freeverb.decay', rv.get('decay', 0.5)),
                         ('freeverb.damp', rv.get('damp', 0.5)),
                         ('freeverb.wet', rv.get('wet', 0.35)),
                         ('freeverb.dry', rv.get('dry', 1.0)),
                         ('freeverb.roomsize', rv.get('roomSize', 1.2)),
                         ('freeverb.width', rv.get('stereoWidth', 1.0))]:
                engine.set_f(k, v)
            engine.set_i('reverb.preset', -2)
        engine.set_f('reverb.predelay', rv.get('predelay', 0.0))
        engine.set_i('reverb.lfe', 1 if rv.get('lfe') else 0)
        engine.set_f('reverb.outgain', rv.get('outputGain', 0.0))
        engine.set_i('reverb.autogain', 1 if rv.get('autoGain') else 0)
    else:
        engine.set_i('reverb.preset', -1)

    sh = p.get('shelf', {})
    if sh.get('enable') and abs(float(sh.get('gain', 0.0))) > 1e-9:
        engine.set_f('shelf.freq', sh.get('freq', 100.0))
        engine.set_f('shelf.gain', sh.get('gain', 0.0))
        engine.set_i('shelf.enable', 1)

    if p.get('stereo', {}).get('on'):
        engine.set_f('stereo.mix', p['stereo'].get('mix', 0.0))
        engine.set_i('stereo.bandUsed', 1 if p['stereo'].get('bandUsed') else 0)
        engine.set_i('stereo.enable', 1)

    sp = p.get('spatial', {})
    if sp.get('enable'):
        for k in ('style', 'room', 'width', 'center', 'outgain', 'mix', 'elevation', 'headazim'):
            if k in sp:
                engine.set_f('spatial.' + k, sp[k])
        engine.set_i('spatial.binaural', 1 if sp.get('binaural') else 0)
        engine.set_i('spatial.headtrack', 1 if sp.get('headTrack') else 0)
        engine.set_i('spatial.enable', 1)

    for prefix, keys in {
        'gate': ['threshold', 'attack', 'release', 'hysteresis', 'range', 'hold'],
        'deesser': ['freq', 'amount'],
        'loudness': ['amount'],
        'exciter': ['amount', 'hifreq'],
        'haas': ['delay', 'mix', 'side'],
        'bassmono': ['freq', 'pairs', 'merge'],
        'filter': ['type', 'freq', 'q'],
        'crossfeed': ['fcut', 'feed', 'mode'],
    }.items():
        sec = p.get(prefix, {})
        if sec.get('enable'):
            for k in keys:
                if k in sec:
                    key = 'haas.' + k if prefix == 'haas' and k == 'delay' else prefix + '.' + k
                    if isinstance(sec[k], bool):
                        engine.set_i(key, 1 if sec[k] else 0)
                    elif isinstance(sec[k], int) and k in ('side', 'pairs', 'merge', 'type', 'mode'):
                        engine.set_i(key, sec[k])
                    else:
                        engine.set_f(key, sec[k])
            engine.set_i(prefix + '.enable', 1)

    comp = p.get('comp', {})
    if comp.get('enable'):
        for k in ('threshold', 'ratio', 'timeconstant', 'granularity', 'tfresolution',
                  'freq1', 'freq2', 'freq3', 'freq4', 'freq5', 'freq6', 'freq7',
                  'gain1', 'gain2', 'gain3', 'gain4', 'gain5', 'gain6', 'gain7'):
            if k in comp:
                if k in ('granularity', 'tfresolution'):
                    engine.set_i('comp.' + k, comp[k])
                else:
                    engine.set_f('comp.' + k, comp[k])
        engine.set_f('comp.outgain', comp.get('outputGain', 0.0))
        engine.set_i('comp.autogain', 1 if comp.get('autoGain') else 0)
        engine.set_i('comp.mode', comp.get('mode', 0))
        engine.set_i('comp.enable', 1)

    dy = p.get('dyneq', {})
    if dy.get('enable'):
        engine.set_f('dyneq.attack', dy.get('attack', 2.0))
        engine.set_f('dyneq.release', dy.get('release', 120.0))
        for band, eng in (('low', 'low'), ('mid', 'mid'), ('high', 'high')):
            bd = dy.get(band, {})
            if bd.get('enable'):
                for k in ('freq', 'q', 'gain', 'range', 'threshold'):
                    engine.set_f('dyneq.%s.%s' % (eng, k), bd[k])
                engine.set_f('dyneq.%s.attack' % eng, bd.get('attack', 10.0))
                engine.set_f('dyneq.%s.release' % eng, bd.get('release', 100.0))
                engine.set_i('dyneq.%s.enable' % eng, 1)
        engine.set_i('dyneq.enable', 1)

    post = p.get('post', {})
    engine.set_f('post.gain', post.get('gain', 0.0))
    for i, v in enumerate(post.get('channelTrims', [])[:8]):
        engine.set_f('post.gain.c%d' % i, v)
    engine.set_f('limiter.threshold', post.get('threshold', -0.1))
    engine.set_f('limiter.release', post.get('release', 100.0))
    engine.set_i('limiter.link', 1 if post.get('link', True) else 0)
    engine.set_i('limiter.lookahead', 1 if post.get('lookahead', False) else 0)
    engine.set_i('limiter.enable', 1 if post.get('limiterEnable', True) else 0)


# ---------------------------------------------------------------- measurement

def capture_ir(engine, amp=0.05, seconds=2.5):
    n = int(engine.sr * seconds)
    x = np.zeros((n, engine.channels), dtype=np.float32)
    x[0, :] = amp
    y = engine.render(x)
    mono = y[:, 0]
    nz = np.where(np.abs(mono) > 1e-7)[0]
    onset = int(nz[0]) if len(nz) else 0
    return mono, onset, y


def fr_db(ir, sr, f_grid, ampref, nfft=8192, start=0):
    """脉冲响应传递函数（矩形窗，按输入脉冲幅度归一化 -> 直通为 0dB）。

    不用 Hann：脉冲位于窗首，Hann 的 w[0]=0 会把主脉冲整段抹掉。
    """
    seg = ir[start:start + nfft]
    if len(seg) < nfft:
        seg = np.pad(seg, (0, nfft - len(seg)))
    spec = np.fft.rfft(seg)
    freqs = np.fft.rfftfreq(len(seg), 1.0 / sr)
    mag = 20.0 * np.log10(np.maximum(np.abs(spec), 1e-20))
    mag -= 20.0 * math.log10(max(ampref, 1e-20))
    out = np.interp(f_grid, freqs, mag)
    return out


def fr_steady(engine, freqs, level_dbfs=-24.0, warm_s=0.5, meas_s=2.0):
    """稳态正弦法测幅频响应（基波幅度，不含谐波/噪声）。

    比脉冲法更适合含混响/非线性/时变效果的预设：混响稳态在同一频率上
    仍是同频率正弦，取基波 bin 即可；不会因 IR 截断产生 ±5dB 的假纹波。
    """
    sr, block = engine.sr, engine.block
    nw = int(round(warm_s * sr / block)) * block
    nm = int(round(meas_s * sr / block)) * block
    amp = 10.0 ** (level_dbfs / 20.0)
    out = []
    for f in freqs:
        t = np.arange(nw + nm) / sr
        x = np.zeros((len(t), engine.channels), dtype=np.float32)
        for c in range(engine.channels):
            x[:, c] = amp * np.sin(2 * np.pi * f * t)
        y = engine.render(x)
        seg = y[nw:nw + nm, 0].astype(np.float64)
        win = np.hanning(len(seg))
        spec = np.fft.rfft(seg * win)
        df = sr / len(seg)
        k = int(round(f / df))
        binamp = 2.0 * float(np.abs(spec[k])) / max(float(np.sum(win)), 1.0)
        out.append(round(20.0 * math.log10(max(binamp, 1e-12) / max(amp, 1e-12)), 2))
    return out


def thdn_metrics(engine, freq, level_dbfs, warm_s=1.0, meas_s=1.0):
    amp = 10.0 ** (level_dbfs / 20.0)
    sr = engine.sr
    block = engine.block
    warm_n = int(round(warm_s * sr / block)) * block
    meas_n = int(round(meas_s * sr / block)) * block
    t = np.arange(warm_n + meas_n) / sr
    x = np.zeros((len(t), 2), dtype=np.float32)
    x[:, 0] = amp * np.sin(2 * np.pi * freq * t)
    x[:, 1] = x[:, 0]
    y = engine.render(x)
    seg = y[warm_n:warm_n + meas_n, 0].astype(np.float64)
    win = np.hanning(len(seg))
    spec = np.fft.rfft(seg * win)
    power = np.abs(spec) ** 2
    df = sr / len(seg)
    k0 = int(round(freq / df))
    # 基波 ±3 bin
    lo, hi = max(1, k0 - 3), min(len(power) - 1, k0 + 3)
    fund = power[lo:hi + 1].sum()
    total = power[1:].sum()
    harm = 0.0
    harmonics = []
    for h in range(2, 11):
        kh = int(round(freq * h / df))
        if kh + 2 >= len(power):
            break
        p = power[max(0, kh - 2):kh + 3].sum()
        harm += p
        harmonics.append((h, 10.0 * math.log10(max(p, 1e-30) / max(fund, 1e-30))))
    noise = max(total - fund - harm, 0.0)
    thd = 10.0 * math.log10(max(harm, 1e-30) / max(fund, 1e-30)) if fund > 0 else -999
    thdn = 10.0 * math.log10(max(total - fund, 1e-30) / max(fund, 1e-30)) if fund > 0 else -999
    nf = 10.0 * math.log10(max(noise, 1e-30) / max(fund, 1e-30)) if fund > 0 else -999
    rms = float(np.sqrt(np.mean(seg ** 2)))
    peak = float(np.max(np.abs(seg)))
    return {
        'freq': freq, 'level_dbfs': level_dbfs,
        'thd_db': round(float(thd), 2),
        'thdn_db': round(float(thdn), 2),
        'noise_rel_db': round(float(nf), 2),
        'rms_dbfs': round(20 * math.log10(max(rms, 1e-12)), 2),
        'peak_dbfs': round(20 * math.log10(max(peak, 1e-12)), 2),
        'harmonics_db': [(h, round(v, 2)) for h, v in harmonics],
    }


def noise_floor(engine, settle_s=1.0, meas_s=1.0):
    sr, block = engine.sr, engine.block
    n0 = int(round(settle_s * sr / block)) * block
    n1 = int(round(meas_s * sr / block)) * block
    y = engine.render(np.zeros((n0 + n1, 2), dtype=np.float32))
    seg = y[n0:n0 + n1, 0].astype(np.float64)
    rms = float(np.sqrt(np.mean(seg ** 2)))
    peak = float(np.max(np.abs(seg)))
    if len(seg) >= 4096:
        win = np.hanning(len(seg))
        spec = np.abs(np.fft.rfft(seg * win)) ** 2
        freqs = np.fft.rfftfreq(len(seg), 1.0 / sr)
        # 忽略 20Hz 以下与 DC
        m = freqs >= 20.0
        p = spec[m]
        peak_bin = float(np.max(p)) if len(p) else 0.0
        peak_f = float(freqs[m][int(np.argmax(p))]) if len(p) else 0.0
    else:
        peak_bin, peak_f = 0.0, 0.0
    return {
        'rms_dbfs': round(20 * math.log10(max(rms, 1e-12)), 2),
        'peak_dbfs': round(20 * math.log10(max(peak, 1e-12)), 2),
        'peak_spectral_dbfs': round(10 * math.log10(max(peak_bin, 1e-30)), 2),
        'peak_freq': round(peak_f, 1),
    }


def rt60(ir, sr, onset):
    # 跳过直达声/早期反射前 50ms：否则稀疏脉冲的直接峰会把 Schroeder
    # 曲线前 5–25dB 段压成“直达衰减”，低湿声时严重低估 RT60。
    skip = int(0.05 * sr)
    seg = ir[onset + skip:].astype(np.float64)
    if len(seg) < 64:
        return None
    # Schroeder 反向能量
    e = np.cumsum(seg[::-1] ** 2)[::-1]
    e = 10.0 * np.log10(np.maximum(e / max(e[0], 1e-30), 1e-30))
    t = np.arange(len(e)) / sr
    try:
        i5 = int(np.where(e <= -5.0)[0][0])
        i25 = int(np.where(e <= -25.0)[0][0])
        rt = (t[i25] - t[i5]) * 3.0
    except IndexError:
        return None
    return round(float(rt), 3)


def headroom(engine, limiter=True, freq=1000.0, amp=1.0, seconds=1.0, noise=False):
    sr, block = engine.sr, engine.block
    n = int(round(seconds * sr / block)) * block
    if noise:
        rng = np.random.default_rng(11)
        x = rng.normal(0, amp, size=(n, 2)).astype(np.float32)
    else:
        t = np.arange(n) / sr
        x = np.zeros((n, 2), dtype=np.float32)
        x[:, 0] = amp * np.sin(2 * np.pi * freq * t)
        x[:, 1] = x[:, 0]
    y = engine.render(x)
    seg = y[int(n * 0.5):]
    peak = float(np.max(np.abs(seg)))
    rms = float(np.sqrt(np.mean(seg ** 2)))
    rc, gr = engine.get_f('gr.limiter')
    return {
        'input_peak_dbfs': round(20 * math.log10(max(amp, 1e-12)), 2),
        'out_peak_dbfs': round(20 * math.log10(max(peak, 1e-12)), 2),
        'out_rms_dbfs': round(20 * math.log10(max(rms, 1e-12)), 2),
        'limiter_gr_db': round(float(gr), 2) if rc == 0 else None,
    }


def block_cost(engine, seconds=2.0):
    sr, block = engine.sr, engine.block
    nblocks = int(round(seconds * sr / block))
    x = np.zeros((block, 2), dtype=np.float32)
    t = np.arange(block) / sr
    x[:, 0] = 0.25 * np.sin(2 * np.pi * 1000 * t)
    x[:, 1] = x[:, 0]
    for _ in range(30):
        engine.process(x)
    times = []
    for _ in range(nblocks):
        t0 = time.perf_counter_ns()
        engine.process(x)
        times.append((time.perf_counter_ns() - t0) / 1000.0)
    times.sort()
    p50 = times[len(times) // 2]
    p95 = times[int(len(times) * 0.95)]
    p99 = times[int(len(times) * 0.99)]
    mx = times[-1]
    ratio = sum(times) / (nblocks * block / sr * 1e6)
    return {
        'blocks': nblocks, 'p50_us': round(p50, 2), 'p95_us': round(p95, 2),
        'p99_us': round(p99, 2), 'max_us': round(mx, 2),
        'cpu_percent': round(ratio * 100.0, 2),
    }


def rss_kb():
    try:
        import psutil
        return int(psutil.Process().memory_info().rss // 1024)
    except Exception:
        return None


def peak_freq_grid():
    return np.array([20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315,
                     400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000,
                     5000, 6300, 8000, 10000, 12500, 16000, 20000], dtype=float)


# ---------------------------------------------------------------- suites

def measure_baseline():
    print('\n== 基线：全关 / 限幅开 / 直通 ==')
    out = {}
    for label, lim in [('bypass_limiter_off', False), ('bypass_limiter_on', True)]:
        e = Engine()
        e.disable_all()
        e.set_i('limiter.enable', 1 if lim else 0)
        ir, onset, _ = capture_ir(e, amp=0.05, seconds=1.0)
        grid = peak_freq_grid()
        fr = fr_db(ir, e.sr, grid, 0.05, start=onset)
        out[label] = {
            'latency_ms_reported': round(e.latency_ms(), 3),
            'latency_samples_measured': onset,
            'fr_db': [(float(f), round(float(v), 2)) for f, v in zip(grid, fr)],
            'thdn_1k_minus12': thdn_metrics(e, 1000.0, -12.0),
            'noise': noise_floor(e),
            'headroom_0dbfs': headroom(e, lim),
            'cpu': block_cost(e),
        }
        e.close()
        print(' ', label, json.dumps(out[label], ensure_ascii=False))
    return out


def measure_preset(name, preset, sr=SR, quick=False):
    e = Engine(sr=sr)
    apply_preset(e, preset)
    ir, onset, stereo = capture_ir(e, amp=0.05, seconds=1.0 if quick else 2.5)
    grid = peak_freq_grid()
    fr = fr_db(ir, e.sr, grid, 0.05, start=onset)
    fr_steady_db = fr_steady(e, grid, -24.0, 0.5, 2.0)
    rv_on = bool(preset.get('params', {}).get('reverb', {}).get('enable'))
    res = {
        'name': preset.get('name'),
        'category': preset.get('category'),
        'description': preset.get('description'),
        'sr': sr,
        'latency_ms_reported': round(e.latency_ms(), 3),
        'latency_samples_measured': int(onset),
        'fr_db_direct': [(float(f), round(float(v), 2)) for f, v in zip(grid, fr)],
        'fr_db_steady': [(float(f), round(float(v), 2)) for f, v in zip(grid, fr_steady_db)],
        'rt60_s': rt60(ir, e.sr, onset) if rv_on else 0.0,
        'thdn_1k_minus12': thdn_metrics(e, 1000.0, -12.0),
        'thdn_100_minus12': thdn_metrics(e, 100.0, -12.0),
        'thdn_10k_minus12': thdn_metrics(e, 10000.0, -12.0),
        'noise': noise_floor(e),
        'headroom_1k_0dbfs': headroom(e, True),
        'cpu': block_cost(e),
    }
    # 限幅器关：看预设本身把 0dBFS 推到多高（危险但可诊断真实余量需求）
    if not quick:
        e2 = Engine(sr=sr)
        apply_preset(e2, preset)
        e2.set_i('limiter.enable', 0)
        res['prelimiter_1k_0dbfs'] = headroom(e2, False, 1000.0, 1.0, 1.0)
        res['prelimiter_100_0dbfs'] = headroom(e2, False, 100.0, 1.0, 1.0)
        res['prelimiter_40_0dbfs'] = headroom(e2, False, 40.0, 1.0, 1.0)
        res['prelimiter_noise_0dbfs'] = headroom(e2, False, noise=True, amp=1.0, seconds=1.0)
        e2.close()
    e.close()
    print(' ', name, '| SR', sr, '|', json.dumps({
        'lat': res['latency_ms_reported'], 'rt60': res['rt60_s'],
        'thd1k': res['thdn_1k_minus12']['thd_db'],
        'thdn1k': res['thdn_1k_minus12']['thdn_db'],
        'noise': res['noise']['rms_dbfs'],
        'outpk': res['headroom_1k_0dbfs']['out_peak_dbfs'],
        'cpu': res['cpu']['p99_us'],
    }, ensure_ascii=False))
    return res


def measure_sample_rates(preset):
    out = {}
    for sr in (44100, 48000, 96000, 192000):
        e = Engine(sr=sr)
        apply_preset(e, preset)
        ir, onset, _ = capture_ir(e, amp=0.03, seconds=0.5)
        fr = fr_steady(e, [100.0, 1000.0, 10000.0, 20000.0], -24.0, 0.5, 2.0)
        out[str(sr)] = {
            'latency_ms': round(e.latency_ms(), 3),
            'onset': int(onset),
            'fr_at_100': fr[0],
            'fr_at_1k': fr[1],
            'fr_at_10k': fr[2],
            'fr_at_20k': fr[3],
            'thdn_1k_minus12': thdn_metrics(e, 1000.0, -12.0, warm_s=0.5, meas_s=0.5),
        }
        e.close()
    return out


def measure_multichannel():
    print('\n== 多声道：6ch 离散 / 矩阵 ==')
    out = {}
    ff = [440.0, 880.0, 1320.0, 1760.0, 2200.0, 2640.0]
    for mode in (1, 0):
        e = Engine(block=BLOCK, channels=6)
        e.disable_all()
        e.set_i('channels.count', 6)
        e.set_i('channels.mode', mode)
        n = BLOCK
        t = np.arange(n) / e.sr
        x = np.zeros((n, 6), dtype=np.float32)
        for c in range(6):
            x[:, c] = 0.1 * np.sin(2 * np.pi * ff[c] * t)
        # 逐块相同输入，先预热
        y = None
        for _ in range(10):
            y = e.process(x)
        y = e.process(x)
        levels = []
        for c in range(6):
            levels.append(round(20 * math.log10(max(float(np.sqrt(np.mean(y[:, c] ** 2))), 1e-12)), 2))
        xtalk = []
        for c in range(6):
            other = [i for i in range(6) if i != c]
            xtalk.append(round(float(np.max(np.abs([np.corrcoef(y[:, c], y[:, o])[0, 1] for o in other]))), 3))
        out['mode%d' % mode] = {'channel_rms_dbfs': levels, 'max_crosstab_corr': xtalk}
        print('  mode%d' % mode, out['mode%d' % mode])
        e.close()
    return out


def measure_limiter_stress():
    print('\n== 限幅器压力（0 dBFS 正弦 / 宽带噪声 / lookahead）==')
    out = {}
    for look in (0, 1):
        e = Engine()
        e.disable_all()
        e.set_f('limiter.threshold', -0.1)
        e.set_i('limiter.lookahead', look)
        e.set_i('limiter.enable', 1)
        h = headroom(e, True, 1000.0, 1.0, 2.0)
        # 白噪声 0 dBFS RMS
        rng = np.random.default_rng(7)
        n = int(e.sr * 1)
        x = rng.normal(0, 1.0, size=(n, 2)).astype(np.float32)
        y = e.render(x)
        seg = y[int(n / 2):]
        peak = float(np.max(np.abs(seg)))
        out['lookahead%d' % look] = {
            'sine': h,
            'noise_out_peak_dbfs': round(20 * math.log10(max(peak, 1e-12)), 2),
        }
        e.close()
    return out


def measure_components():
    """关键组件独立指标：限幅/压缩/门限/去齿音/激励器/超采样。"""
    print('\n== 关键组件独立指标 ==')
    out = {}

    # 超采样混叠抑制：16k 以上? 现有 smoke 已有；这里只测 THD 改善
    for label, params in [
        ('tube_os_on', {'tube.oversample': 1}),
        ('tube_os_off', {'tube.oversample': 0}),
    ]:
        e = Engine()
        e.disable_all()
        e.set_f('tube.gain', 6.0)
        e.set_f('tube.mix', 1.0)
        e.set_i('tube.style', 2)
        e.set_i('tube.oversample', params['tube.oversample'])
        e.set_i('tube.enable', 1)
        out[label] = thdn_metrics(e, 1000.0, -12.0)
        e.close()

    # 限幅器阈值精度
    e = Engine()
    e.disable_all()
    e.set_f('limiter.threshold', -6.0)
    e.set_f('limiter.release', 100.0)
    e.set_i('limiter.enable', 1)
    out['limit_threshold_minus6'] = headroom(e, True, 1000.0, 1.0, 1.0)
    e.close()
    return out


def main():
    quick = '--quick' in sys.argv
    t0 = time.time()
    print('DLL:', DLL)
    print('version:', lib.auradsp_version().decode('utf-8', 'replace'), 'ABI', lib.auradsp_abi())
    presets = {}
    for fn in sorted(os.listdir(PRESET_DIR)):
        if fn.endswith('.json'):
            with open(os.path.join(PRESET_DIR, fn), encoding='utf-8') as f:
                presets[fn[:-5]] = json.load(f)

    data = {
        'dll': DLL,
        'version': lib.auradsp_version().decode('utf-8', 'replace'),
        'abi': int(lib.auradsp_abi()),
        'block': BLOCK,
        'sr': SR,
        'baseline': measure_baseline(),
        'presets': {},
        'sample_rates': {},
        'multichannel': measure_multichannel(),
        'limiter_stress': measure_limiter_stress(),
        'components': measure_components(),
    }
    for name, p in presets.items():
        print('\n== 出厂预设：%s ==' % name)
        data['presets'][name] = measure_preset(name, p, quick=quick)
    # 采样率一致性：用最具代表性的 V-Shape（宽频提升）+ Pop Vocal（中频）
    for name in ('V-Shape Smile Hi-Fi', 'Pop Vocal Clarity'):
        print('\n== 采样率矩阵：%s ==' % name)
        data['sample_rates'][name] = measure_sample_rates(presets[name])

    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    with open(OUT_JSON, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print('\nJSON ->', OUT_JSON, '| 用时 %.1fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
