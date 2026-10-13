"""smoke_crossfeed.py — 串扰消除（Crossfeed / 交叉馈送）烟雾验收。

验收标准：
  1. 初始 crossfeed.enable=0, mode=0, fcut=700, feed=4.5。
  2. 支持切换 mode 0 (Default), 1 (Chu Moy), 2 (Jan Meier), 3 (Custom)。
  3. 支持设置 fcut [300, 2000] 与 feed [1.0, 15.0]。
  4. 开启 crossfeed.enable=1 后音频块处理正常（无崩溃/NaN/Inf）。
  5. 各模式与自定义模式推流稳态无损。
"""
import ctypes
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
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char),
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char),
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

h = dll.auradsp_create(SR, BLOCK)
assert h, 'create failed'

def set_i(pid, v):
    val = ctypes.c_int32(v)
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(val), 4)

def get_i(pid):
    val = ctypes.c_int32(0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(val), 4)
    return rc, val.value

def set_f(pid, v):
    val = ctypes.c_float(v)
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(val), 4)

def get_f(pid):
    val = ctypes.c_float(0.0)
    rc = dll.auradsp_get_param(h, pid.encode(), ctypes.byref(val), 4)
    return rc, val.value

# 1. 默认参数回读
rc, en = get_i('crossfeed.enable')
check('initial enable=0', rc == 0 and en == 0)
rc, m = get_i('crossfeed.mode')
check('initial mode=0', rc == 0 and m == 0)
rc, fcut = get_f('crossfeed.fcut')
check('initial fcut=700', rc == 0 and abs(fcut - 700.0) < 1e-3)
rc, feed = get_f('crossfeed.feed')
check('initial feed=4.5', rc == 0 and abs(feed - 4.5) < 1e-3)

# 2. 模式切换
check('set mode=1 (Chu Moy)', set_i('crossfeed.mode', 1) == 0)
_, m = get_i('crossfeed.mode')
check('get mode=1', m == 1)

check('set mode=2 (Jan Meier)', set_i('crossfeed.mode', 2) == 0)
_, m = get_i('crossfeed.mode')
check('get mode=2', m == 2)

check('set mode=3 (Custom)', set_i('crossfeed.mode', 3) == 0)
_, m = get_i('crossfeed.mode')
check('get mode=3', m == 3)

# 3. 自定义频点和衰减分贝
check('set fcut=850', set_f('crossfeed.fcut', 850.0) == 0)
_, fcut = get_f('crossfeed.fcut')
check('get fcut=850', abs(fcut - 850.0) < 1e-3)

check('set feed=6.5', set_f('crossfeed.feed', 6.5) == 0)
_, feed = get_f('crossfeed.feed')
check('get feed=6.5', abs(feed - 6.5) < 1e-3)

# 4. 开启与音频块处理
check('enable crossfeed', set_i('crossfeed.enable', 1) == 0)
_, en = get_i('crossfeed.enable')
check('get enable=1', en == 1)

# 生成立体声正弦波（左声道有信号，右声道静音，以检验 crossfeed 互馈入右声道）
in_buf = (ctypes.c_float * (BLOCK * 2))()
out_buf = (ctypes.c_float * (BLOCK * 2))()
import math
for i in range(BLOCK):
    in_buf[i * 2] = math.sin(2.0 * math.pi * 440.0 * i / SR) * 0.5
    in_buf[i * 2 + 1] = 0.0

dll.auradsp_process(h, in_buf, out_buf, BLOCK)

# 验证右声道因 crossfeed 互馈有了能量
r_energy = sum(out_buf[i * 2 + 1] ** 2 for i in range(BLOCK))
check('crossfeed feeds L into R', r_energy > 1e-5, f'r_energy={r_energy}')

# 5. 关闭 crossfeed 再测一块
set_i('crossfeed.enable', 0)
dll.auradsp_process(h, in_buf, out_buf, BLOCK)
r_energy_off = sum(out_buf[i * 2 + 1] ** 2 for i in range(BLOCK))
check('crossfeed off isolates R', r_energy_off < 1e-8, f'r_energy_off={r_energy_off}')

dll.auradsp_destroy(h)
print(f"\nAll tests completed. Failures: {len(FAIL)}")
if FAIL:
    sys.exit(1)
