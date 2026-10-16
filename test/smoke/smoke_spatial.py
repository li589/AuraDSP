# -*- coding: utf-8 -*-
"""smoke_spatial.py — 空间音效 L1（参数化 HRTF + 早期反射）验收。

验收标准：
  0. 8 参数 set/get 对称 + 钳位；style 下发联动 room/width/center。
  1. 关闭直通（float32 精度内逐位一致）。
  2. 双耳对称性：硬左声像与其镜像的输出互为镜像（确定性 DSP 该成立）。
  3. 双耳差异：单声道输入进左右耳不等（ITD/ILD 真在干活）。
  4. 早期反射：room=1 脉冲尾 >> room=0；8 tap ±配对保证 mono 下左右能量均衡。
  5. center/width/outgain 均可测地改变输出。
  6. autogain set/get + 有界；全参数极值 fuzz 有限无 NaN。
  7. 44.1k 独立句柄冒烟（ITD 缩放/pinna 系数/tap 偏移都跟 fs 走）。

卫生铁律（实测踩坑总结）：声学小节一律全新句柄——limiter 包络/延迟环/
  pinna 状态跨小节污染测量；float32 精度的期望值必须经 c_float 舍入。
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


def f32r(x):
    """float32 舍入后的期望值（与引擎内 float 运算对齐）。"""
    return ctypes.c_float(x).value


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


# 0. 参数面：set/get + 钳位（本节只碰参数面，不跑声学，无污染）
check('enable set/get', set_i('spatial.enable', 1) == 0 and get_i('spatial.enable') == (0, 1))
set_i('spatial.enable', 0)
check('style set/get+clamp',
      set_i('spatial.style', 2) == 0 and get_i('spatial.style') == (0, 2) and
      set_i('spatial.style', 9) == 0 and get_i('spatial.style') == (0, 2) and
      set_i('spatial.style', -9) == 0 and get_i('spatial.style') == (0, 0))
check('room set/get+clamp',
      set_f('spatial.room', 0.7) == 0 and abs(get_f('spatial.room')[1] - 0.7) < 1e-6 and
      set_f('spatial.room', 9.0) == 0 and abs(get_f('spatial.room')[1] - 1.0) < 1e-6 and
      set_f('spatial.room', -9.0) == 0 and abs(get_f('spatial.room')[1] - 0.0) < 1e-6)
check('width set/get+clamp',
      set_f('spatial.width', 1.2) == 0 and abs(get_f('spatial.width')[1] - 1.2) < 1e-6 and
      set_f('spatial.width', 9.0) == 0 and abs(get_f('spatial.width')[1] - 1.5) < 1e-6 and
      set_f('spatial.width', 0.0) == 0 and abs(get_f('spatial.width')[1] - 0.5) < 1e-6)
check('center set/get+clamp',
      set_f('spatial.center', 0.8) == 0 and abs(get_f('spatial.center')[1] - 0.8) < 1e-6 and
      set_f('spatial.center', 9.0) == 0 and abs(get_f('spatial.center')[1] - 1.0) < 1e-6)
check('outgain set/get+clamp',
      set_f('spatial.outgain', 6.0) == 0 and abs(get_f('spatial.outgain')[1] - 6.0) < 1e-6 and
      set_f('spatial.outgain', -99.0) == 0 and abs(get_f('spatial.outgain')[1] + 12.0) < 1e-6)
check('autogain set/get', set_i('spatial.autogain', 1) == 0 and get_i('spatial.autogain') == (0, 1))

# style 联动预设值（Dolby 0.7/1.0/0.8；DTS 0.25/1.1/0.5；中性 0.0/1.0/0.5）
set_i('spatial.style', 0)
check('style=0 pushes Dolby preset',
      abs(get_f('spatial.room')[1] - 0.7) < 1e-6 and
      abs(get_f('spatial.width')[1] - 1.0) < 1e-6 and
      abs(get_f('spatial.center')[1] - 0.8) < 1e-6)
set_i('spatial.style', 1)
check('style=1 pushes DTS preset',
      abs(get_f('spatial.room')[1] - 0.25) < 1e-6 and
      abs(get_f('spatial.width')[1] - 1.1) < 1e-6 and
      abs(get_f('spatial.center')[1] - 0.5) < 1e-6)
set_i('spatial.style', 2)
check('style=2 pushes neutral preset',
      abs(get_f('spatial.room')[1] - 0.0) < 1e-6 and
      abs(get_f('spatial.width')[1] - 1.0) < 1e-6 and
      abs(get_f('spatial.center')[1] - 0.5) < 1e-6)
dll.auradsp_destroy(h)


def fresh_dolby():
    """全新句柄 + Dolby 默认态（enable/room0.7/width1.0/center0.8/其余默认）。"""
    hh = dll.auradsp_create(SR, BLOCK)
    assert hh, 'create failed'
    dll.auradsp_set_param(hh, b'spatial.enable', ctypes.byref(i32(1)), 4)
    return hh


def run_blocks(hh, fn, blocks=24):
    """按 fn(n)->(L,R) 喂输入，返回最后 4 块的左右 RMS 和峰值。"""
    n0 = 0
    se_l = se_r = 0.0
    peak = 0.0
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            sL, sR = fn(n0 + i)
            buf[i * 2] = sL
            buf[i * 2 + 1] = sR
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(hh, buf, out, BLOCK)
        n0 += BLOCK
        if b >= blocks - 4:
            for i in range(BLOCK):
                se_l += out[i * 2] ** 2
                se_r += out[i * 2 + 1] ** 2
                a = abs(out[i * 2])
                b2 = abs(out[i * 2 + 1])
                if a > peak:
                    peak = a
                if b2 > peak:
                    peak = b2
    n = 4 * BLOCK
    return math.sqrt(se_l / n), math.sqrt(se_r / n), peak


def sine_l(n):
    # 0.25 幅值：峰值远离 vendor limiter 门限（~1.0），测纯 spatial 特性。
    s = 0.25 * math.sin(2 * math.pi * 440.0 * n / SR)
    return s, 0.0


def sine_r(n):
    s = 0.25 * math.sin(2 * math.pi * 440.0 * n / SR)
    return 0.0, s


def sine_mono(n):
    s = 0.25 * math.sin(2 * math.pi * 440.0 * n / SR)
    return s, s


# 1. 关闭直通（float32 精度内逐位一致；全新句柄排除一切状态污染）
h = dll.auradsp_create(SR, BLOCK)
n0 = 0
acc = []
for _ in range(8):
    buf = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        sL, sR = sine_l(n0 + i)
        buf[i * 2] = sL
        buf[i * 2 + 1] = sR
    out = (ctypes.c_float * (BLOCK * 2))()
    dll.auradsp_process(h, buf, out, BLOCK)
    n0 += BLOCK
    acc.extend([out[i] for i in range(BLOCK * 2)])
exp = [f32r(0.25 * math.sin(2 * math.pi * 440.0 * (n // 2) / SR))
       if (n % 2 == 0) else 0.0 for n in range(len(acc))]
check('disabled bit-identical passthrough',
      all(x == y for x, y in zip(acc, exp)))
dll.auradsp_destroy(h)

# 2/3. 双耳对称 + 差异（Dolby 默认态；每 run 全新句柄——vendor limiter
# 慢包络跨 run 污染对称测量，与被测 spatial 无关，见 smoke 注释）
# 对称测量在 room=0 纯 HRTF 路径下进行（反射 comb 相位干涉与测量正弦相位
# 耦合，不适合做镜像相等断言；反射能量均衡由 2b mono 测试覆盖）。
def run_fresh(fn, blocks=40, room=None):
    hh = dll.auradsp_create(SR, BLOCK)
    dll.auradsp_set_param(hh, b'spatial.enable', ctypes.byref(i32(1)), 4)
    if room is not None:
        dll.auradsp_set_param(hh, b'spatial.room', ctypes.byref(f32(room)), 4)
    out = run_blocks(hh, fn, blocks=blocks)
    dll.auradsp_destroy(hh)
    return out


l1, r1, _ = run_fresh(sine_l, room=0.0)
l2, r2, _ = run_fresh(sine_r, room=0.0)
check('symmetric render (mirror in/out swap)',
      abs(l1 - r2) / max(l1, 1e-9) < 0.02 and abs(r1 - l2) / max(r1, 1e-9) < 0.02,
      'L1=%.4f R2=%.4f R1=%.4f L2=%.4f' % (l1, r2, r1, l2))
check('binaural differs L/R (ITD/ILD active)',
      abs(l1 - r1) / max(l1, r1, 1e-9) > 0.02,
      'L1=%.4f R1=%.4f' % (l1, r1))
check('contralateral present but weaker', 0.05 * l1 < r1 < l1,
      'L1=%.4f R1=%.4f' % (l1, r1))

# 2b. 反射能量均衡：mono 噪声输入 room=0.7 时左右 RMS 近似相等（±配对 tap
# 设计）。必须用噪声而非正弦：正弦与反射 comb 干涉的相位耦合会让任何
# 真实房间都量出 L/R 差异，噪声下干涉平均掉，只剩能量对比。
def noise_mono(n):
    u = (((n * 1103515245 + 12345) & 0x7fffffff) >> 8) / 8388607.0 - 0.5
    return 0.5 * u, 0.5 * u


lm, rm, _ = run_fresh(noise_mono, room=0.7)
check('reflections energy-balanced (mono L~R)',
      abs(lm - rm) / max(lm, 1e-9) < 0.05, 'L=%.4f R=%.4f' % (lm, rm))

# 4. 早期反射：脉冲尾 room=1 >> room=0（全新句柄，排除包络残留）
h = dll.auradsp_create(SR, BLOCK)
dll.auradsp_set_param(h, b'spatial.enable', ctypes.byref(i32(1)), 4)


def impulse_tail(room, blocks=40):
    dll.auradsp_set_param(h, b'spatial.room', ctypes.byref(f32(room)), 4)
    e = 0.0
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * 2))()
        if b == 0:
            buf[0] = 1.0
            buf[1] = 1.0
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(h, buf, out, BLOCK)
        if b >= 2:
            e += sum(out[i] ** 2 for i in range(BLOCK * 2))
    return e


e0 = impulse_tail(0.0)
e1 = impulse_tail(1.0)
check('early reflections tail grows with room', e1 > 5.0 * max(e0, 1e-12),
      'tail0=%.6f tail1=%.6f' % (e0, e1))
dll.auradsp_destroy(h)

# 5. center/width/outgain 可测（每项独立全新句柄）
h = dll.auradsp_create(SR, BLOCK)
dll.auradsp_set_param(h, b'spatial.enable', ctypes.byref(i32(1)), 4)
dll.auradsp_set_param(h, b'spatial.room', ctypes.byref(f32(0.7)), 4)
dll.auradsp_set_param(h, b'spatial.center', ctypes.byref(f32(0.8)), 4)
lm0, rm0, _ = run_blocks(h, sine_mono, blocks=24)
dll.auradsp_set_param(h, b'spatial.center', ctypes.byref(f32(0.0)), 4)
lm1, rm1, _ = run_blocks(h, sine_mono, blocks=24)
check('center changes output (>2%)',
      abs(lm0 - lm1) / max(lm0, 1e-9) > 0.02, 'c08=%.4f c00=%.4f' % (lm0, lm1))
dll.auradsp_set_param(h, b'spatial.center', ctypes.byref(f32(0.8)), 4)
dll.auradsp_set_param(h, b'spatial.width', ctypes.byref(f32(0.5)), 4)
_, rw0, _ = run_blocks(h, sine_l, blocks=24)
dll.auradsp_set_param(h, b'spatial.width', ctypes.byref(f32(1.5)), 4)
_, rw1, _ = run_blocks(h, sine_l, blocks=24)
check('width steers contralateral ear (>2%)',
      abs(rw0 - rw1) / max(rw0, 1e-9) > 0.02, 'w05R=%.4f w15R=%.4f' % (rw0, rw1))
dll.auradsp_set_param(h, b'spatial.width', ctypes.byref(f32(1.0)), 4)
dll.auradsp_set_param(h, b'spatial.room', ctypes.byref(f32(0.7)), 4)
l60, _, _ = run_blocks(h, sine_l, blocks=24)
dll.auradsp_set_param(h, b'spatial.outgain', ctypes.byref(f32(6.0)), 4)
l66, _, _ = run_blocks(h, sine_l, blocks=24)
check('outgain +6dB doubles (+-5%)',
      abs(l66 / l60 - 2.0) / 2.0 < 0.05 if l60 > 0 else False,
      'ratio=%.4f' % (l66 / l60 if l60 > 0 else 0.0))
dll.auradsp_set_param(h, b'spatial.outgain', ctypes.byref(f32(0.0)), 4)
dll.auradsp_destroy(h)

# 6. autogain 有界 + 极值 fuzz（全新句柄）
h = dll.auradsp_create(SR, BLOCK)
dll.auradsp_set_param(h, b'spatial.enable', ctypes.byref(i32(1)), 4)
dll.auradsp_set_param(h, b'spatial.autogain', ctypes.byref(i32(1)), 4)
ag_l, _, ag_p = run_blocks(h, sine_l, blocks=40)
check('autogain bounded finite', ag_l == ag_l and ag_p < 5.0, 'rms=%.4f' % ag_l)
dll.auradsp_set_param(h, b'spatial.autogain', ctypes.byref(i32(0)), 4)
bad = False
for _room, _w, _c, _g in [(0.0, 0.5, 0.0, -12.0), (1.0, 1.5, 1.0, 6.0),
                          (0.0, 1.5, 1.0, -12.0), (1.0, 0.5, 0.0, 6.0)]:
    dll.auradsp_set_param(h, b'spatial.room', ctypes.byref(f32(_room)), 4)
    dll.auradsp_set_param(h, b'spatial.width', ctypes.byref(f32(_w)), 4)
    dll.auradsp_set_param(h, b'spatial.center', ctypes.byref(f32(_c)), 4)
    dll.auradsp_set_param(h, b'spatial.outgain', ctypes.byref(f32(_g)), 4)
    _, _, pk = run_blocks(h, sine_l, blocks=8)
    if pk != pk or pk > 10.0:
        bad = True
check('extreme params finite (no NaN/blowup)', not bad)
dll.auradsp_destroy(h)

# 7. 44.1k 独立句柄冒烟（ITD 缩放/pinna 系数/tap 偏移都跟 fs 走）
h44 = dll.auradsp_create(44100.0, BLOCK)
ok44 = h44 is not None and h44 != 0
if ok44:
    dll.auradsp_set_param(h44, b'spatial.enable', ctypes.byref(i32(1)), 4)
    buf = (ctypes.c_float * (BLOCK * 2))()
    out = (ctypes.c_float * (BLOCK * 2))()
    for n in range(BLOCK):
        s = 0.3 * math.sin(n * 0.05)
        buf[2 * n] = s
        buf[2 * n + 1] = s
    dll.auradsp_process(h44, buf, out, BLOCK)
    pk44 = max(abs(out[i]) for i in range(BLOCK * 2))
    ok44 = pk44 == pk44 and pk44 < 10.0 and pk44 > 0.001
    dll.auradsp_destroy(h44)
check('44.1k handle finite audible', ok44)

print()
if FAIL:
    print('SPATIAL FAILURES:', FAIL)
    sys.exit(1)
print('spatial: all checks passed')
