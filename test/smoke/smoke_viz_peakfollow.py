# -*- coding: utf-8 -*-
# 第四十轮回归：频谱 peak-follow——FL 无信号时频谱必须跟随有信号的声道。
# 旧实现 viz 历史 0 槽恒为 FL、compute_bands 只读 0 槽，于是离散逐声道
# 测 C/SL、纯 R 内容时频谱恒空（user 实测）。本冒烟三例同频正弦分别喂
# R / L / 离散 SL，断言频谱均点亮且峰值带一致；静音例断言不假亮。
import ctypes, math, os, sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from engine_artifact import engine_lib_path as _elp  # noqa: E402

dll = ctypes.CDLL(_elp())

_VIZ_ROOT = os.path.dirname(os.path.abspath(__file__))
while not os.path.isfile(os.path.join(_VIZ_ROOT, 'tools', 'bin', 'viz_frame.py')):
    _VIZ_PARENT = os.path.dirname(_VIZ_ROOT)
    if _VIZ_PARENT == _VIZ_ROOT:
        raise ImportError('未找到 tools/bin/viz_frame.py')
    _VIZ_ROOT = _VIZ_PARENT
if os.path.join(_VIZ_ROOT, 'tools', 'bin') not in sys.path:
    sys.path.insert(0, os.path.join(_VIZ_ROOT, 'tools', 'bin'))
from viz_frame import VizFrame  # noqa: E402

dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(VizFrame), ctypes.c_uint32]
dll.auradsp_viz_read.restype = ctypes.c_uint32
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_int]

FAILS = []


def check(name, ok, detail=''):
    print(('  PASS  ' if ok else '  FAIL  ') + name + (('  ' + detail) if detail else ''))
    if not ok:
        FAILS.append(name)


def setp(h, pid, v):
    # channels.count / channels.mode 为 i32 参数，须按 4 字节整型下发
    # （与 smoke_config_and_matrix 的 set_i32 同口径；double 缓冲会被拒）。
    val = ctypes.c_int32(int(v))
    rc = dll.auradsp_set_param(h, pid.encode(), ctypes.byref(val), 4)
    assert rc == 0, 'set_param %s rc=%d' % (pid, rc)


def run_case(channels, mode, active_ch, freq=1000.0, blocks=400):
    """喂 phase 连续正弦（仅 active_ch，None=全静音），返回末帧 spectrum 列表。"""
    h = dll.auradsp_create(48000.0, 240)
    assert h
    if channels != 2:
        setp(h, 'channels.count', float(channels))
    if mode != 0:
        setp(h, 'channels.mode', float(mode))
    N = 240
    buf = (ctypes.c_float * (N * channels))()
    out = (ctypes.c_float * (N * channels))()
    frames = (VizFrame * 64)()
    phase = 0.0
    last = None
    for _ in range(blocks):
        for n in range(N):
            s = 0.3 * math.sin(phase)
            phase += 2 * math.pi * freq / 48000.0
            for c in range(channels):
                buf[n * channels + c] = s if c == active_ch else 0.0
        dll.auradsp_process(h, buf, out, N)
        n = dll.auradsp_viz_read(h, frames, 64)
        if n:
            last = frames[n - 1]
    dll.auradsp_destroy(h)
    assert last is not None, 'no viz frames'
    return list(last.spectrum)


print('=== [1] 立体声 R-only 1000Hz（旧实现频谱恒空） ===')
b_r = run_case(2, 0, 1)
pk_r = max(range(32), key=lambda i: b_r[i])
check('R-only 频谱点亮', b_r[pk_r] > 0.3, 'peak band=%d val=%.3f' % (pk_r, b_r[pk_r]))

print('=== [2] 立体声 L-only 1000Hz（基线不回归） ===')
b_l = run_case(2, 0, 0)
pk_l = max(range(32), key=lambda i: b_l[i])
check('L-only 频谱点亮', b_l[pk_l] > 0.3, 'peak band=%d val=%.3f' % (pk_l, b_l[pk_l]))
check('L/R 峰值带一致', pk_l == pk_r, 'L=%d R=%d' % (pk_l, pk_r))

print('=== [3] 8 声道离散 SL-only 1000Hz（user 实测场景） ===')
b_sl = run_case(8, 1, 4)
pk_sl = max(range(32), key=lambda i: b_sl[i])
check('SL-only 频谱点亮', b_sl[pk_sl] > 0.3, 'peak band=%d val=%.3f' % (pk_sl, b_sl[pk_sl]))
check('SL 与 L 峰值带一致', pk_sl == pk_l, 'SL=%d L=%d' % (pk_sl, pk_l))

print('=== [4] 全静音不假亮 ===')
b_s = run_case(8, 1, None)
check('静音频谱保持空', max(b_s) < 0.05, 'max=%.4f' % max(b_s))

if FAILS:
    print('VIZ PEAKFOLLOW FAILURES:', FAILS)
    sys.exit(1)
print('ALL VIZ PEAKFOLLOW CHECKS PASSED')
