# -*- coding: utf-8 -*-
"""回归门禁：块长抖动不得触发卷积器重建（P-008）。

背景（用户实测「播放长声音时脉冲响应周期性断续 / 变小 / 卡顿」）：
  libjamesdsp 的 pfloat32Multiplexd 在 blockSize 变化时无条件调用
  JamesDSPRefreshConvolutions -> Convolver1DLoadImpulseResponse(updateOld=0)，
  即析构并重建整个卷积器（重做全 IR 的 FFT + 分段选择）。
  而 WASAPI 泵传入 n = min(avail, max_block)，avail 随 padding 逐轮抖动，
  于是几乎每次调用都重建。

  实测（0.5s / 48kHz IR）修复前：
    恒定 n=1024    中位 0.160ms，输出 RMS 0.5607
    n 抖动         中位 4.050ms（25x），输出 RMS 0.4360（低 22%）
  重建既吃满 CPU 预算（卡顿），又重置卷积状态截断湿信号尾巴（变小 / 断续）。

本用例钉住修复后契约：块长抖动时 ① 耗时不应显著升高 ② 输出电平不应偏移。
FFTConvolver 的 Process 以输入 FIFO 逐块消化，任意 len 都输出正确，
故「不重建」不牺牲正确性。
"""
import array
import ctypes
import math
import os
import random
import struct
import time

# S1 迁移（2026-11-01）：路径统一走 test/engine_artifact 解析
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
from engine_artifact import engine_lib_path as _elp, REPO_ROOT as _RR  # noqa: E402
DLL = _elp()
DIR = os.path.dirname(os.path.abspath(__file__))
FS = 48000.0
MAX_BLOCK = 1024
IR_FRAMES = 24000          # 0.5s
CALLS = 400
WARMUP = 40


def write_wav(path, ch, rate):
    data = array.array('h')
    for c in ch:
        for s in c:
            data.append(max(-32768, min(32767, int(s * 32767))))
    raw = data.tobytes()
    hdr = (b'RIFF' + struct.pack('<I', 36 + len(raw)) + b'WAVEfmt '
           + struct.pack('<IHHIIHH', 16, 1, len(ch), rate,
                         rate * len(ch) * 2, len(ch) * 2, 16)
           + b'data' + struct.pack('<I', len(raw)))
    with open(path, 'wb') as f:
        f.write(hdr + raw)


dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)


def make_ir():
    random.seed(7)
    left, right = [], []
    for i in range(IR_FRAMES):
        env = math.exp(-4.0 * i / IR_FRAMES)
        left.append(env * (random.random() * 2 - 1) * 0.5)
        right.append(env * (random.random() * 2 - 1) * 0.5)
    p = os.path.join(DIR, "_probe_ir_stability.wav")
    write_wav(p, [left, right], int(FS))
    return p


ir_path = make_ir()


def setup():
    h = ctypes.c_void_p(dll.auradsp_create(FS, MAX_BLOCK))
    b = ir_path.encode("utf-8")
    pb = (ctypes.c_char * len(b)).from_buffer_copy(b)
    rc = dll.auradsp_set_param(h, b"convolver.ir.path", pb, len(b))
    assert rc == 0, "IR load rc=%d %s" % (rc, dll.auradsp_last_error(h))
    rc = dll.auradsp_set_param(h, b"convolver.enable", ctypes.byref(i32(1)), 4)
    assert rc == 0, "enable %s" % dll.auradsp_last_error(h)
    return h


def run(sizes):
    h = setup()
    buf_in = (ctypes.c_float * (MAX_BLOCK * 2))()
    buf_out = (ctypes.c_float * (MAX_BLOCK * 2))()
    times, rms = [], []
    pos = 0
    for i in range(CALLS):
        n = sizes[i % len(sizes)]
        for k in range(n * 2):
            buf_in[k] = math.sin(2 * math.pi * 220.0 * (pos + k // 2) / FS) * 0.3
        pos += n
        t0 = time.perf_counter()
        dll.auradsp_process(h, buf_in, buf_out, n)      # (h, in, out, frames)
        times.append((time.perf_counter() - t0) * 1000.0)
        acc = 0.0
        for k in range(n * 2):
            v = buf_out[k]
            acc += v * v
        rms.append(math.sqrt(acc / (n * 2)))
    dll.auradsp_destroy(h)
    warm = sorted(times[WARMUP:])
    r = sorted(rms[WARMUP:])
    return warm[len(warm) // 2], warm[-1], r[len(r) // 2]


print("IR = %d frames (%.2fs), max_block=%d" % (IR_FRAMES, IR_FRAMES / FS, MAX_BLOCK))
m_const, _, r_const = run([MAX_BLOCK])
m_jit, _, r_jit = run([MAX_BLOCK, 900, 700])
m_j1, _, r_j1 = run([MAX_BLOCK, MAX_BLOCK - 1])
m_wide, peak_wide, r_wide = run([MAX_BLOCK, 500])
m_severe, peak_severe, r_severe = run([MAX_BLOCK, 300])

print("const  n=%d   median=%.3fms  rms=%.4f" % (MAX_BLOCK, m_const, r_const))
print("jitter 1024/900/700  median=%.3fms  rms=%.4f" % (m_jit, r_jit))
print("jitter 1024/1023     median=%.3fms  rms=%.4f" % (m_j1, r_j1))
print("wide   1024/500      median=%.3fms  max=%.3fms  rms=%.4f" % (m_wide, peak_wide, r_wide))
print("severe 1024/300      median=%.3fms  max=%.3fms  rms=%.4f" % (m_severe, peak_severe, r_severe))

# 修复前实测：jitter median 4.05ms vs const 0.16ms（25x），rms 低 22%
assert m_jit < m_const * 3.0, \
    "块长抖动导致中位耗时放大 %.1fx（修复前约 25x）—— 卷积器仍在重建" % (m_jit / m_const)
assert m_wide < m_const * 3.0, \
    "大幅块长变化导致中位耗时放大 %.1fx —— 仍在跨 2 倍阈值时重建" % (m_wide / m_const)
assert m_severe < m_const * 3.0, \
    "大幅块长变化导致中位耗时放大 %.1fx —— 仍在跨 2 倍阈值时重建" % (m_severe / m_const)
assert abs(r_jit - r_const) / r_const < 0.02, \
    "块长抖动导致输出电平偏移 %.1f%%（修复前约 -22%%）—— 卷积尾巴被截断" % (
        (r_jit - r_const) / r_const * 100)
for label, value in (("1024/500", r_wide), ("1024/300", r_severe)):
    assert abs(value - r_const) / r_const < 0.02, \
        "大幅块长变化导致输出电平偏移 %.1f%% —— 卷积状态仍被重置" % (
            abs(value - r_const) / r_const * 100)
assert r_const > 0.05, "IR 未真正生效（RMS 过低），本用例失去意义"

print("PASS: 块长抖动不再重建卷积器（P-008），代价与电平均与恒定块一致")

try:
    os.remove(ir_path)
except OSError:
    pass