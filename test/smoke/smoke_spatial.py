# -*- coding: utf-8 -*-
"""smoke_spatial.py — 空间音效 L1（参数化 HRTF + 早期反射）验收。

验收标准：
  0. 8 参数 set/get 对称 + 钳位；style 下发联动 room/width/center。
  1. 关闭直通（float32 精度内逐位一致）。
  2. 双耳对称性：硬左声像与其镜像的输出互为镜像（确定性 DSP 该成立）。
  3. 双耳差异：单声道输入进左右耳不等（ITD/ILD 真在干活）。
  4. 早期反射：B3c 矩形房间镜像源（2 阶）；room=1 脉冲尾 >> room=0；
     首个反射落在镜像源距离处，room 增大 → 反射更晚；左右能量对等。
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
check('mix set/get+clamp',
      set_f('spatial.mix', 0.42) == 0 and abs(get_f('spatial.mix')[1] - 0.42) < 1e-6 and
      set_f('spatial.mix', 9.0) == 0 and abs(get_f('spatial.mix')[1] - 1.0) < 1e-6 and
      set_f('spatial.mix', -9.0) == 0 and abs(get_f('spatial.mix')[1] - 0.0) < 1e-6)
set_f('spatial.mix', 1.0)
check('elevation set/get+clamp',
      set_f('spatial.elevation', 12.0) == 0 and abs(get_f('spatial.elevation')[1] - 12.0) < 1e-6 and
      set_f('spatial.elevation', 99.0) == 0 and abs(get_f('spatial.elevation')[1] - 30.0) < 1e-6 and
      set_f('spatial.elevation', -99.0) == 0 and abs(get_f('spatial.elevation')[1] + 30.0) < 1e-6)
set_f('spatial.elevation', 0.0)
check('fdn set/get', set_i('spatial.fdn', 1) == 0 and get_i('spatial.fdn') == (0, 1))
check('late set/get+clamp',
      set_f('spatial.late', 0.33) == 0 and abs(get_f('spatial.late')[1] - 0.33) < 1e-6 and
      set_f('spatial.late', 9.0) == 0 and abs(get_f('spatial.late')[1] - 1.0) < 1e-6 and
      set_f('spatial.late', -9.0) == 0 and abs(get_f('spatial.late')[1] - 0.0) < 1e-6)
set_i('spatial.fdn', 0)
set_f('spatial.late', 0.25)
check('headazim set/get+clamp',
      set_f('spatial.headazim', 45.0) == 0 and abs(get_f('spatial.headazim')[1] - 45.0) < 1e-6 and
      set_f('spatial.headazim', 999.0) == 0 and abs(get_f('spatial.headazim')[1] - 180.0) < 1e-6 and
      set_f('spatial.headazim', -999.0) == 0 and abs(get_f('spatial.headazim')[1] + 180.0) < 1e-6)
check('headtrack set/get', set_i('spatial.headtrack', 1) == 0 and get_i('spatial.headtrack') == (0, 1))
set_f('spatial.headazim', 0.0)
set_i('spatial.headtrack', 0)

# style 联动预设值（影院 0.7/1.0/0.8；定位 0.25/1.1/0.5；中性 0.0/1.0/0.5）
set_i('spatial.style', 0)
check('style=0 pushes cinema preset',
      abs(get_f('spatial.room')[1] - 0.7) < 1e-6 and
      abs(get_f('spatial.width')[1] - 1.0) < 1e-6 and
      abs(get_f('spatial.center')[1] - 0.8) < 1e-6)
set_i('spatial.style', 1)
check('style=1 pushes imaging preset',
      abs(get_f('spatial.room')[1] - 0.25) < 1e-6 and
      abs(get_f('spatial.width')[1] - 1.1) < 1e-6 and
      abs(get_f('spatial.center')[1] - 0.5) < 1e-6)
set_i('spatial.style', 2)
check('style=2 pushes neutral preset',
      abs(get_f('spatial.room')[1] - 0.0) < 1e-6 and
      abs(get_f('spatial.width')[1] - 1.0) < 1e-6 and
      abs(get_f('spatial.center')[1] - 0.5) < 1e-6)
dll.auradsp_destroy(h)


def fresh_cinema():
    """全新句柄 + 影院默认态（enable/room0.7/width1.0/center0.8/其余默认）。"""
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

# 1b. 头跟踪：headazim 必须改变声像；headtrack 只是外部源标志，不改变 DSP。
def run_last_block(hh, az, ht):
    dll.auradsp_set_param(hh, b'spatial.enable', ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(hh, b'spatial.headazim', ctypes.byref(f32(az)), 4)
    dll.auradsp_set_param(hh, b'spatial.headtrack', ctypes.byref(i32(ht)), 4)
    n0 = 0
    last = None
    for _ in range(12):
        buf = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            s = 0.25 * math.sin(2 * math.pi * 440.0 * (n0 + i) / SR)
            buf[i * 2] = s
            buf[i * 2 + 1] = 0.0
        out = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(hh, buf, out, BLOCK)
        n0 += BLOCK
        last = bytes(out)
    return last


h_a = dll.auradsp_create(SR, BLOCK)
o_off = run_last_block(h_a, 0.0, 0)
dll.auradsp_destroy(h_a)
h_b = dll.auradsp_create(SR, BLOCK)
o_man = run_last_block(h_b, 90.0, 0)
dll.auradsp_destroy(h_b)
h_c = dll.auradsp_create(SR, BLOCK)
o_track = run_last_block(h_c, 90.0, 1)
dll.auradsp_destroy(h_c)
h_d = dll.auradsp_create(SR, BLOCK)
o_zero_track = run_last_block(h_d, 0.0, 1)
dll.auradsp_destroy(h_d)
check('headazim steers the image (manual)', o_off != o_man)
check('headtrack flag alone is inert', o_off == o_zero_track)
check('headtrack=1 consumes same headazim', o_man == o_track)

# 2/3. 双耳对称 + 差异（影院默认态；每 run 全新句柄——vendor limiter
# 慢包络跨 run 污染对称测量，与被测 spatial 无关，见 smoke 注释）
# 对称测量在 room=0 纯 HRTF 路径下进行（反射 comb 相位干涉与测量正弦相位
# 耦合，不适合做镜像相等断言；反射能量均衡由 2b mono 测试覆盖）。
def run_fresh(fn, blocks=40, room=None, mix=None, elev=None, fdn=None,
              late=None):
    hh = dll.auradsp_create(SR, BLOCK)
    dll.auradsp_set_param(hh, b'spatial.enable', ctypes.byref(i32(1)), 4)
    if room is not None:
        dll.auradsp_set_param(hh, b'spatial.room', ctypes.byref(f32(room)), 4)
    if mix is not None:
        dll.auradsp_set_param(hh, b'spatial.mix', ctypes.byref(f32(mix)), 4)
    if elev is not None:
        dll.auradsp_set_param(hh, b'spatial.elevation',
                              ctypes.byref(f32(elev)), 4)
    if fdn is not None:
        dll.auradsp_set_param(hh, b'spatial.fdn', ctypes.byref(i32(fdn)), 4)
    if late is not None:
        dll.auradsp_set_param(hh, b'spatial.late', ctypes.byref(f32(late)), 4)
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

# 2a. mix=0 必须回到干声；仰角 notch 移动必须可测（6k 正弦）
l_m0, r_m0, _ = run_fresh(sine_l, room=0.0, mix=0.0)
check('mix=0 returns dry signal',
      abs(l_m0 - 0.25 / math.sqrt(2.0)) < 0.01 and
      abs(r_m0 - 0.0) < 1e-6,
      'L=%.4f R=%.4f' % (l_m0, r_m0))


def sine_l6k(n):
    return 0.25 * math.sin(2 * math.pi * 6000.0 * n / SR), 0.0


l_ev_neg, _, _ = run_fresh(sine_l6k, room=0.0, elev=-25.0)
l_ev_pos, _, _ = run_fresh(sine_l6k, room=0.0, elev=25.0)
check('elevation moves pinna notch (>2%)',
      abs(l_ev_neg - l_ev_pos) / max(l_ev_neg, l_ev_pos, 1e-9) > 0.02,
      'elev-25=%.4f elev+25=%.4f' % (l_ev_neg, l_ev_pos))

# 2b. 反射能量均衡：mono 噪声输入 room=0.7 时左右 RMS 近似相等（±配对 tap
# 设计）。必须用噪声而非正弦：正弦与反射 comb 干涉的相位耦合会让任何
# 真实房间都量出 L/R 差异，噪声下干涉平均掉，只剩能量对比。
def noise_mono(n):
    u = (((n * 1103515245 + 12345) & 0x7fffffff) >> 8) / 8388607.0 - 0.5
    return 0.5 * u, 0.5 * u


lm, rm, _ = run_fresh(noise_mono, room=0.7)
check('reflections energy-balanced (mono L~R)',
      abs(lm - rm) / max(lm, 1e-9) < 0.05, 'L=%.4f R=%.4f' % (lm, rm))

# 2c. FDN 晚期混响（WP1 语义变化）：spatial.fdn 已退役为 deprecated 写别名，
# 晚期混响职责移交统一混响引擎（本文件拓扑 → vendor Progenitor2）。spatial 段
# 内部不再含 FDN，旧断言「fdn 给 spatial 输出加尾音能量」随之失效；新断言改为
# 迁移语义：fdn=1 → reverb.preset=5 + vendor 引擎上报；late → freeverb.wet。
# 完整别名矩阵见 smoke_spatial_fdn_removed.py。
hh = dll.auradsp_create(SR, BLOCK)
try:
    def _gi(pid):
        v = i32(0)
        dll.auradsp_get_param(hh, pid.encode(), ctypes.byref(v), 4)
        return v.value

    def _gf(pid):
        v = f32(0)
        dll.auradsp_get_param(hh, pid.encode(), ctypes.byref(v), 4)
        return v.value

    check('fdn alias: default reverb off', _gi('reverb.preset') == -1)
    dll.auradsp_set_param(hh, b'spatial.fdn', ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(hh, b'spatial.late', ctypes.byref(f32(1.0)), 4)
    check('fdn=1 migrates to unified reverb preset 5',
          _gi('reverb.preset') == 5, 'preset=%d' % _gi('reverb.preset'))
    check('fdn=1 picks vendor engine on stereo/matrix topology',
          _gi('reverb.engine') == 0, 'engine=%d' % _gi('reverb.engine'))
    check('late=1.0 migrates into freeverb.wet',
          abs(_gf('freeverb.wet') - 1.0) < 1e-6,
          'wet=%.3f' % _gf('freeverb.wet'))
    # 别名只迁移「开启」语义：fdn=0 不得关掉统一混响
    dll.auradsp_set_param(hh, b'spatial.fdn', ctypes.byref(i32(0)), 4)
    check('fdn=0 leaves unified reverb on', _gi('reverb.preset') == 5)
finally:
    dll.auradsp_destroy(hh)

# 4. B3c 镜像源早期反射：脉冲尾 room=1 >> room=0；反射时刻由房间几何决定。
def capture_ir(room, blocks=40):
    hh = dll.auradsp_create(SR, BLOCK)
    dll.auradsp_set_param(hh, b'spatial.enable', ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(hh, b'spatial.room', ctypes.byref(f32(room)), 4)
    dll.auradsp_set_param(hh, b'spatial.fdn', ctypes.byref(i32(0)), 4)
    dll.auradsp_set_param(hh, b'spatial.center', ctypes.byref(f32(0.0)), 4)
    dll.auradsp_set_param(hh, b'spatial.mix', ctypes.byref(f32(1.0)), 4)
    L, R = [], []
    for b in range(blocks):
        bi = (ctypes.c_float * (BLOCK * 2))()
        bo = (ctypes.c_float * (BLOCK * 2))()
        if b == 0:
            bi[0] = 1.0
            bi[1] = 1.0
        dll.auradsp_process(hh, bi, bo, BLOCK)
        for i in range(BLOCK):
            L.append(bo[i * 2])
            R.append(bo[i * 2 + 1])
    dll.auradsp_destroy(hh)
    return L, R


def img_taps_ms(room):
    """与 dsp_spatial.cpp spat_image_taps 同式：镜像源距离 → 延迟(ms)。"""
    hx = 0.8 + 1.7 * room
    hy = 1.2 + 2.3 * room
    ey = 1.5
    pts = [(2 * hx, ey), (-2 * hx, ey), (0, 2 * hy - ey), (0, -2 * hy - ey),
           (4 * hx, ey), (-4 * hx, ey), (0, 4 * hy - ey), (0, -4 * hy - ey)]
    for sx in (-1, 1):
        for sy in (-1, 1):
            pts.append((sx * 2 * hx, sy * (2 * hy - ey)))
    return [math.hypot(x, y) / 343.0 * 1000.0 for x, y in pts]


def tail_energy(room, skip_ms=3.0):
    L, R = capture_ir(room)
    a = int(skip_ms * SR / 1000.0)
    return sum(x * x for x in L[a:]) + sum(y * y for y in R[a:])


e0 = tail_energy(0.0)
e1 = tail_energy(1.0)
check('early reflections tail grows with room', e1 > 5.0 * max(e0, 1e-12),
      'tail0=%.6f tail1=%.6f' % (e0, e1))

# 4b. B3c 几何：首个反射落在镜像源距离处，且在此前无能量。
irL, irR = capture_ir(1.0)


def ir_peak(t0_ms, t1_ms):
    a = max(0, int(t0_ms * SR / 1000.0))
    b = int(t1_ms * SR / 1000.0)
    return max([abs(x) for x in irL[a:b]] + [abs(y) for y in irR[a:b]] + [0.0])


t_first = min(img_taps_ms(1.0))
t_last = max(img_taps_ms(1.0))
p_first = ir_peak(t_first - 0.6, t_first + 0.6)
p_pre = ir_peak(2.0, t_first - 1.5)
check('B3c first reflection lands at image-source delay',
      p_first > 1e-4 and p_pre < 0.05 * p_first,
      'first=%.2fms peak=%.3e pre=%.3e' % (t_first, p_first, p_pre))

# 4c. B3b 全通扩散：最后一个反射 tap 之后仍有弥散尾（未加全通应≈0）。
p_last = ir_peak(t_last - 0.6, t_last + 0.6)
p_smear = ir_peak(t_last + 1.5, t_last + 4.0)
check('B3b allpass smears after last reflection tap',
      p_last > 1e-4 and p_smear > 0.05 * p_last,
      'last=%.2fms tap=%.3e smear=%.3e' % (t_last, p_last, p_smear))

# 4d. room 只改房间尺寸/反射率：更大房间 → 首个反射更晚（几何单调）。
def first_reflection_ms(room, thr=0.004):
    L, R = capture_ir(room)
    for i in range(int(3.0 * SR / 1000.0), len(L)):
        if abs(L[i]) > thr or abs(R[i]) > thr:
            return i * 1000.0 / SR
    return -1.0


fr_small = first_reflection_ms(0.3)
fr_big = first_reflection_ms(1.0)
check('room scales reflection geometry (bigger room = later first tap)',
      fr_small > 0 and fr_big > fr_small + 2.0,
      'small=%.2fms big=%.2fms' % (fr_small, fr_big))

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

# 8. 加固：快速自动化 + 奇异块长 + 中途开关 + 96k（全新句柄）
h = dll.auradsp_create(SR, BLOCK)
dll.auradsp_set_param(h, b'spatial.enable', ctypes.byref(i32(1)), 4)
dll.auradsp_set_param(h, b'spatial.autogain', ctypes.byref(i32(1)), 4)
n = 0
worst = 0.0
ok_auto = True
for b in range(40):
    dll.auradsp_set_param(h, b'spatial.room', ctypes.byref(f32((b % 11) / 10.0)), 4)
    dll.auradsp_set_param(h, b'spatial.width', ctypes.byref(f32(0.5 + (b % 11) / 10.0)), 4)
    dll.auradsp_set_param(h, b'spatial.center', ctypes.byref(f32((b % 7) / 6.0)), 4)
    dll.auradsp_set_param(h, b'spatial.outgain', ctypes.byref(f32(-12.0 + (b % 7) * 3.0)), 4)
    bi = (ctypes.c_float * (BLOCK * 2))()
    bo = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        s = 0.25 * math.sin(2 * math.pi * 440.0 * (n + i) / SR)
        bi[2 * i] = s
        bi[2 * i + 1] = 0.0
    dll.auradsp_process(h, bi, bo, BLOCK)
    n += BLOCK
    for i in range(BLOCK * 2):
        v = bo[i]
        if v != v or abs(v) > 10.0:
            ok_auto = False
        a = abs(v)
        if a > worst:
            worst = a
check('rapid automation finite+bounded', ok_auto and worst < 10.0,
      'worst=%.3f' % worst)

# 奇异块长（frames=1/7/100/511/512，皆须有限；create 上限内任意帧数合法）
ok_fr = True
for fr in (1, 7, 100, 511, 512):
    bi = (ctypes.c_float * (fr * 2))()
    bo = (ctypes.c_float * (fr * 2))()
    for i in range(fr):
        bi[2 * i] = 0.1
        bi[2 * i + 1] = -0.1
    dll.auradsp_process(h, bi, bo, fr)
    for i in range(fr * 2):
        if bo[i] != bo[i] or abs(bo[i]) > 10.0:
            ok_fr = False
check('odd frame counts finite (1/7/100/511/512)', ok_fr)

# 中途开关：关→直通有限，开→恢复可听（状态残留不得爆音/静默）
dll.auradsp_set_param(h, b'spatial.enable', ctypes.byref(i32(0)), 4)
bi = (ctypes.c_float * (BLOCK * 2))()
bo = (ctypes.c_float * (BLOCK * 2))()
for i in range(BLOCK):
    bi[2 * i] = 0.2
    bi[2 * i + 1] = 0.2
dll.auradsp_process(h, bi, bo, BLOCK)
off_ok = all(bo[i] == bo[i] and abs(bo[i]) < 10.0 for i in range(BLOCK * 2))
dll.auradsp_set_param(h, b'spatial.enable', ctypes.byref(i32(1)), 4)
pk_on = 0.0
for _ in range(8):
    dll.auradsp_process(h, bi, bo, BLOCK)
    pk_on = max([pk_on] + [abs(bo[i]) for i in range(BLOCK * 2)])
check('toggle off finite, on resumes audible',
      off_ok and pk_on == pk_on and 0.001 < pk_on < 10.0, 'pk=%.4f' % pk_on)
dll.auradsp_destroy(h)

# 96k 独立句柄（ITD/tap/hist/全通高 fs 缩放冒烟）
h96 = dll.auradsp_create(96000.0, BLOCK)
ok96 = h96 is not None and h96 != 0
if ok96:
    dll.auradsp_set_param(h96, b'spatial.enable', ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h96, b'spatial.room', ctypes.byref(f32(1.0)), 4)
    dll.auradsp_set_param(h96, b'spatial.width', ctypes.byref(f32(1.5)), 4)
    bi = (ctypes.c_float * (BLOCK * 2))()
    bo = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        s = 0.25 * math.sin(2 * math.pi * 440.0 * i / 96000.0)
        bi[2 * i] = s
        bi[2 * i + 1] = 0.0
    for _ in range(8):
        dll.auradsp_process(h96, bi, bo, BLOCK)
    pk96 = max(abs(bo[i]) for i in range(BLOCK * 2))
    ok96 = pk96 == pk96 and 0.001 < pk96 < 10.0
    dll.auradsp_destroy(h96)
check('96k handle finite audible (ITD clamp path)', ok96)

# 192k 独立句柄：ITD 154 < 256；全通最长 4.1ms≈788 < 1024。
h192 = dll.auradsp_create(192000.0, BLOCK)
ok192 = h192 is not None and h192 != 0
if ok192:
    dll.auradsp_set_param(h192, b'spatial.enable', ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h192, b'spatial.room', ctypes.byref(f32(1.0)), 4)
    dll.auradsp_set_param(h192, b'spatial.width', ctypes.byref(f32(1.5)), 4)
    dll.auradsp_set_param(h192, b'spatial.fdn', ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h192, b'spatial.late', ctypes.byref(f32(0.5)), 4)
    bi = (ctypes.c_float * (BLOCK * 2))()
    bo = (ctypes.c_float * (BLOCK * 2))()
    for i in range(BLOCK):
        s = 0.25 * math.sin(2 * math.pi * 440.0 * i / 192000.0)
        bi[2 * i] = s
        bi[2 * i + 1] = 0.0
    for _ in range(8):
        dll.auradsp_process(h192, bi, bo, BLOCK)
    pk192 = max(abs(bo[i]) for i in range(BLOCK * 2))
    ok192 = pk192 == pk192 and 0.001 < pk192 < 10.0
    dll.auradsp_destroy(h192)
check('192k handle finite audible (ITD/allpass full length)', ok192)

print()
if FAIL:
    print('SPATIAL FAILURES:', FAIL)
    sys.exit(1)
print('spatial: all checks passed')
