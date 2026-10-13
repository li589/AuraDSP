"""smoke_dyneq.py — 全参数动态EQ验收。

验收标准：
  1. 总开关关 → 直通（基频残差 <0.5%）。
  2. Mid 静态 +6dB（range=0）→ 基频 ≈x2；带外（200Hz）基本不动。
  3. 动态：range=12/threshold=-30，大声 1kHz 被压（<-1dB），小声不压，错频段不压。
  4. Low/High shelf 静态增益方向正确。
  5. set/get 回读对称 + 钳位。
  6. graph.effects 注册表含 dyneq（21 项，2048 缓冲不断尾）。
"""
import ctypes
import json
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


def run_sine(freq, amp, blocks=40):
    n0 = 0
    ys = []
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            s = amp * math.sin(2 * math.pi * freq * (n0 + i) / SR)
            buf[i * 2] = s
            buf[i * 2 + 1] = s
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        n0 += BLOCK
        if b >= blocks - 8:
            for i in range(BLOCK):
                ys.append(out[i * 2])
    return ys


def gz(ys, f):
    n = len(ys)
    w = 2 * math.pi * f / SR
    cw, sw = math.cos(w), math.sin(w)
    s0 = s1 = s2 = 0.0
    for y in ys:
        s0 = y + 2 * cw * s1 - s2
        s2 = s1
        s1 = s0
    return ((cw * s1 - s2) ** 2 + (sw * s1) ** 2) / (n * n)


def fund(ys, f):
    return math.sqrt(gz(ys, f)) * 2


# 0. 回读 + 钳位
check('enable set/get', set_i('dyneq.enable', 1) == 0 and get_i('dyneq.enable') == (0, 1))
check('attack set/get', set_f('dyneq.attack', 5.0) == 0 and abs(get_f('dyneq.attack')[1] - 5.0) < 1e-6)
set_f('dyneq.mid.freq', 99999.0)
check('mid freq clamp 99999->8000', abs(get_f('dyneq.mid.freq')[1] - 8000.0) < 1e-3)
set_f('dyneq.low.q', 9.0)
check('low q clamp 9->2 (shelf)', abs(get_f('dyneq.low.q')[1] - 2.0) < 1e-6)
set_f('dyneq.high.range', 99.0)
check('high range clamp 99->24', abs(get_f('dyneq.high.range')[1] - 24.0) < 1e-6)
set_f('dyneq.mid.threshold', -99.0)
check('mid thr clamp -99->-60', abs(get_f('dyneq.mid.threshold')[1] + 60.0) < 1e-6)
set_i('dyneq.enable', 0)

# 1. 总开关关 → 直通
ys = run_sine(1000.0, 0.2)
f0 = fund(ys, 1000.0)
check('disabled passthrough', abs(f0 - 0.2) < 0.005, 'fund=%.4f' % f0)

# 2. Mid 静态 +6dB（range=0），带内提升，带外不动
set_i('dyneq.enable', 1)
set_i('dyneq.mid.enable', 1)
set_f('dyneq.mid.freq', 1000.0)
set_f('dyneq.mid.q', 1.0)
set_f('dyneq.mid.gain', 6.0)
set_f('dyneq.mid.range', 0.0)
f_in = fund(run_sine(1000.0, 0.2), 1000.0)
check('static +6dB in-band', abs(f_in - 0.4) < 0.02, 'fund=%.4f' % f_in)
f_out = fund(run_sine(200.0, 0.2), 200.0)
check('static out-of-band untouched', abs(f_out - 0.2) < 0.02, 'fund=%.4f' % f_out)

# 3. 动态：range=12/threshold=-30，大声压，静音/错频段不压
set_f('dyneq.mid.gain', 0.0)
set_f('dyneq.mid.range', 12.0)
set_f('dyneq.mid.threshold', -30.0)
f_loud = fund(run_sine(1000.0, 0.3), 1000.0)
check('dyn loud cut (>1dB)', f_loud < 0.3 * 0.891, 'fund=%.4f' % f_loud)
f_quiet = fund(run_sine(1000.0, 0.01), 1000.0)
check('dyn quiet untouched', abs(f_quiet - 0.01) < 0.002, 'fund=%.5f' % f_quiet)
f_wrong = fund(run_sine(200.0, 0.3), 200.0)
check('dyn wrong-band untouched', abs(f_wrong - 0.3) < 0.02, 'fund=%.4f' % f_wrong)

# 4. Low/High shelf 静态方向
set_i('dyneq.mid.enable', 0)
set_i('dyneq.low.enable', 1)
set_f('dyneq.low.freq', 120.0)
set_f('dyneq.low.gain', 6.0)
set_f('dyneq.low.range', 0.0)
f_low = fund(run_sine(100.0, 0.2), 100.0)
check('low shelf boosts lows', f_low > 0.2 * 1.5, 'fund=%.4f' % f_low)
set_i('dyneq.low.enable', 0)
set_i('dyneq.high.enable', 1)
set_f('dyneq.high.freq', 6000.0)
set_f('dyneq.high.gain', 6.0)
set_f('dyneq.high.range', 0.0)
f_high = fund(run_sine(8000.0, 0.2), 8000.0)
check('high shelf boosts highs', f_high > 0.2 * 1.5, 'fund=%.4f' % f_high)
set_i('dyneq.high.enable', 0)

# 5. 段开关关 → 该段直通（总开关开着）
set_i('dyneq.mid.enable', 0)
f_off = fund(run_sine(1000.0, 0.2), 1000.0)
check('band off passthrough', abs(f_off - 0.2) < 0.01, 'fund=%.4f' % f_off)

# 6. graph.effects 注册表含 dyneq（2048 缓冲；1024 会拿 E_PARAM 防断尾）
buf = ctypes.create_string_buffer(2048)
rc = dll.auradsp_get_param(h, b'graph.effects', buf, 2048)
check('graph.effects rc', rc == 0, 'rc=%d' % rc)
try:
    reg = json.loads(buf.value.decode('utf-8'))
    ids = [e['id'] for e in reg]
    check('graph.effects 21 entries', len(reg) == 21, 'n=%d' % len(reg))
    check('graph.effects has dyneq', 'dyneq' in ids)
    dy = [e for e in reg if e['id'] == 'dyneq'][0]
    check('dyneq exposed tier1', dy.get('exposed') is True and dy.get('tier') == 1, str(dy))
except (ValueError, KeyError, IndexError) as ex:
    check('graph.effects valid JSON', False, str(ex))
small = ctypes.create_string_buffer(1024)
check('graph.effects 1024 rejected (no truncation)', dll.auradsp_get_param(h, b'graph.effects', small, 1024) != 0)

dll.auradsp_destroy(h)

print()
if FAIL:
    print('DYNEQ FAILURES:', FAIL)
    sys.exit(1)
print('dyneq: all checks passed')
