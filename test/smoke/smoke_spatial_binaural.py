# -*- coding: utf-8 -*-
"""smoke_spatial_binaural.py — B1 多声道→双耳虚拟环绕验收。

验收：
  1. 5.1 环绕声道只进 FL/FR；左环绕偏左、右环绕偏右。
  2. 中置双耳对称；LFE 低通后双耳轻混。
  3. 7.1 后环绕方位可辨；8ch 输出其余声道全零。
  4. 头旋转改变声像；mix=0 回到干声下混。
  5. binaural=0 时保持旧多声道直通路径（不回归）。
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
    print(('PASS  ' if cond else 'FAIL  ') + name +
          ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p,
                                ctypes.POINTER(ctypes.c_float),
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


def make(ch, binaural=1, head=0.0, mix=1.0, mode=0, autogain=0, room=0.0):
    h = dll.auradsp_create(SR, BLOCK)
    assert h, 'create failed'
    dll.auradsp_set_param(h, b'channels.count', ctypes.byref(i32(ch)), 4)
    dll.auradsp_set_param(h, b'channels.mode', ctypes.byref(i32(mode)), 4)
    dll.auradsp_set_param(h, b'spatial.enable', ctypes.byref(i32(1)), 4)
    dll.auradsp_set_param(h, b'spatial.binaural', ctypes.byref(i32(binaural)), 4)
    dll.auradsp_set_param(h, b'spatial.room', ctypes.byref(f32(room)), 4)
    dll.auradsp_set_param(h, b'spatial.mix', ctypes.byref(f32(mix)), 4)
    dll.auradsp_set_param(h, b'spatial.headazim', ctypes.byref(f32(head)), 4)
    dll.auradsp_set_param(h, b'spatial.autogain', ctypes.byref(i32(autogain)), 4)
    return h


def run_channel(ch, idx, freq=440.0, blocks=18, **kw):
    h = make(ch, **kw)
    n0 = 0
    acc = [0.0] * ch
    for b in range(blocks):
        buf = (ctypes.c_float * (BLOCK * ch))()
        for i in range(BLOCK):
            s = 0.25 * math.sin(2 * math.pi * freq * (n0 + i) / SR)
            buf[i * ch + idx] = s
        out = (ctypes.c_float * (BLOCK * ch))()
        dll.auradsp_process(h, buf, out, BLOCK)
        if b >= blocks - 4:
            for i in range(BLOCK):
                for c in range(ch):
                    acc[c] += out[i * ch + c] ** 2
        n0 += BLOCK
    dll.auradsp_destroy(h)
    n = BLOCK * 4
    return [math.sqrt(v / n) for v in acc]


# 1. 5.1 左/右环绕方位
sl = run_channel(6, 4)
sr = run_channel(6, 5)
check('5.1 SL renders to both ears', sl[0] > 0.01 and sl[1] > 0.005)
check('5.1 SL steers left', sl[0] > sl[1] * 1.05, 'L=%.4f R=%.4f' % (sl[0], sl[1]))
check('5.1 SR steers right', sr[1] > sr[0] * 1.05, 'L=%.4f R=%.4f' % (sr[0], sr[1]))
check('5.1 binaural zeros C/LFE/SL/SR',
      all(v < 1e-5 for v in sl[2:]))

# 2. 中置对称 + LFE 双耳
c = run_channel(6, 2)
check('5.1 C symmetric', abs(c[0] - c[1]) / max(c[0], c[1], 1e-9) < 0.02,
      'L=%.4f R=%.4f' % (c[0], c[1]))
lfe = run_channel(6, 3, freq=60.0)
lfe_hi = run_channel(6, 3, freq=2000.0)
check('LFE reaches both ears', lfe[0] > 0.01 and lfe[1] > 0.01)
check('LFE is low-passed', lfe[0] > lfe_hi[0] * 3.0,
      '60Hz=%.4f 2k=%.4f' % (lfe[0], lfe_hi[0]))

# 3. 7.1 后环绕 + 输出静音边界
bl = run_channel(8, 6)
br = run_channel(8, 7)
check('7.1 BL steers left', bl[0] > bl[1] * 1.05, 'L=%.4f R=%.4f' % (bl[0], bl[1]))
check('7.1 BR steers right', br[1] > br[0] * 1.05, 'L=%.4f R=%.4f' % (br[0], br[1]))
check('8ch binaural zeros non-front',
      all(v < 1e-5 for v in bl[2:]))

# 4. 头旋转 + mix=0 干声
sl_rot = run_channel(6, 4, head=90.0)
check('headazim rotates binaural image',
      abs(sl_rot[0] - sl[0]) / max(sl[0], 1e-9) > 0.02,
      'base=%.4f rot=%.4f' % (sl[0], sl_rot[0]))
dry = run_channel(6, 4, mix=0.0)
check('mix=0 returns dry downmix (L only)',
      dry[0] > 0.01 and dry[1] < 1e-4,
      'L=%.4f R=%.4f' % (dry[0], dry[1]))

# 5. binaural=0 旧路径：离散模式下 SL 直通、FL/FR 不接收 SL
old = run_channel(6, 4, binaural=0, mode=1)
check('binaural=0 keeps old discrete path',
      old[4] > 0.01 and old[0] < 1e-4 and old[1] < 1e-4,
      'FL=%.4f FR=%.4f SL=%.4f' % (old[0], old[1], old[4]))

# 6. 4ch / autogain 有限性
quad = run_channel(4, 2)
check('4ch quad back-left finite', quad[0] > 0.001 and quad[0] == quad[0])
ag = run_channel(6, 4, autogain=1)
check('binaural autogain finite/bounded',
      all(v == v and v < 10.0 for v in ag), str(ag))

# 7. B3c 镜像源反射在 binaural 总线同样生效：脉冲 IR 在 3ms 后的尾部
# 随 room 增长（稳态正弦会与延迟反射相干，不适合做能量断言）。
def binaural_tail(room, blocks=20, skip_ms=3.0):
    h = make(6, room=room)
    L, R = [], []
    for b in range(blocks):
        bi = (ctypes.c_float * (BLOCK * 6))()
        bo = (ctypes.c_float * (BLOCK * 6))()
        if b == 0:
            bi[4] = 1.0
        dll.auradsp_process(h, bi, bo, BLOCK)
        for i in range(BLOCK):
            L.append(bo[i * 6])
            R.append(bo[i * 6 + 1])
    dll.auradsp_destroy(h)
    a = int(skip_ms * SR / 1000.0)
    return sum(x * x for x in L[a:]) + sum(y * y for y in R[a:])


bt0 = binaural_tail(0.0)
bt7 = binaural_tail(0.7)
check('binaural B3c reflections add IR tail',
      bt7 > 1e-3 and bt7 > 5.0 * max(bt0, 1e-12),
      'tail0=%.3e tail07=%.3e' % (bt0, bt7))

print('\n' + ('SPATIAL BINAURAL FAILURES: ' + str(FAIL) if FAIL
             else 'spatial binaural: all checks passed'))
sys.exit(1 if FAIL else 0)
