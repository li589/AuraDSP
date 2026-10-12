# -*- coding: utf-8 -*-
"""脉冲响应周期性断续/变小/卡顿 的根因探针。

假设：Dart 泵循环传 n = min(avail, max_block)，avail 随 WASAPI padding 抖动；
而 libjamesdsp 的 pfloat32Multiplexd 在 blockSize 变化时会
JamesDSPRefreshConvolutions -> Convolver1DLoadImpulseResponse(updateOld=0)
-> 析构并重建整个卷积器（重做全 IR 的 FFT + 分段选择）。

后果有二：
  (1) 卷积状态被重置，湿信号尾巴被截断 -> 听感「变小 / 断续」
  (2) 重建是 O(IR 长度) 的 CPU 开销 -> 「卡顿」

验证方法：固定 IR，喂一段持续信号，分别用
  A) 恒定 n（单块）
  B) 抖动 n（模拟 avail 抖动）
两种方式各跑 N 次 process，比较每次耗时。若假设成立，B 的耗时会出现
数量级尖峰，且尖峰次数等于 n 变化的次数。
"""
import ctypes
import os
import struct
import time

DLL = r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll"
OUT = os.path.join(os.path.dirname(__file__), "_probe_ir")
os.makedirs(OUT, exist_ok=True)

FS = 48000.0
MAX_BLOCK = 1024
# 约 0.5s 的 IR —— 真实用户常用的小型 room IR 量级
IR_FRAMES = 24000


def write_wav(path, ch, rate):
    import array
    data = array.array('h')
    for c in ch:
        for s in c:
            v = max(-32768, min(32767, int(s * 32767)))
            data.append(v)
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
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

# 指数衰减噪声 IR（左右不相关）
import math
import random
random.seed(7)
left, right = [], []
for i in range(IR_FRAMES):
    env = math.exp(-4.0 * i / IR_FRAMES)
    left.append(env * (random.random() * 2 - 1) * 0.5)
    right.append(env * (random.random() * 2 - 1) * 0.5)
ir_path = os.path.join(OUT, "probe_ir.wav")
write_wav(ir_path, [left, right], int(FS))

i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)
N_CH = 2


def setup():
    h = ctypes.c_void_p(dll.auradsp_create(FS, MAX_BLOCK))
    b = ir_path.encode("utf-8")
    pb = (ctypes.c_char * len(b)).from_buffer_copy(b)
    rc = dll.auradsp_set_param(h, b"convolver.ir.path", pb, len(b))
    assert rc == 0, "IR load failed rc=%d %s" % (rc, dll.auradsp_last_error(h))
    rc = dll.auradsp_set_param(h, b"convolver.enable", ctypes.byref(i32(1)), 4)
    assert rc == 0, "enable failed %s" % dll.auradsp_last_error(h)
    rc = dll.auradsp_set_param(h, b"convolver.mix", ctypes.byref(f32(1.0)), 4)
    assert rc == 0
    return h


def run(label, sizes):
    h = setup()
    buf_in = (ctypes.c_float * (MAX_BLOCK * 2))()
    buf_out = (ctypes.c_float * (MAX_BLOCK * 2))()
    times = []
    rms = []
    pos = 0
    for i in range(400):
        n = sizes[i % len(sizes)]
        for k in range(n * 2):
            buf_in[k] = math.sin(2 * math.pi * 220.0 * (pos + k // 2) / FS) * 0.3
        pos += n
        t0 = time.perf_counter()
        dll.auradsp_process(h, buf_in, buf_out, n)   # (h, in, out, frames)
        dt = (time.perf_counter() - t0) * 1000.0
        times.append(dt)
        acc = 0.0
        for k in range(n * 2):
            v = buf_out[k]
            acc += v * v
        rms.append(math.sqrt(acc / (n * 2)))
    dll.auradsp_destroy(h)
    warm = times[40:]
    warm.sort()
    med = warm[len(warm) // 2]
    mx = warm[-1]
    tail = rms[40:]
    rmed = sorted(tail)[len(tail) // 2]
    dips = sum(1 for v in tail if v < rmed * 0.5)
    print("%-24s median=%.3fms  max=%.3fms  max/med=%.1fx  rms_med=%.4f  rms_dips=%d"
          % (label, med, mx, mx / max(med, 1e-9), rmed, dips))
    return med, rmed


print("IR = %d frames (%.2fs), max_block=%d" % (IR_FRAMES, IR_FRAMES / FS, MAX_BLOCK))
m1, r1 = run("A) const n=1024", [1024])
m2, r2 = run("B) jitter 1024/900/700", [1024, 900, 700])
m3, r3 = run("C) jitter 1024/1023", [1024, 1023])
print()
print("判据：抖动场景的中位耗时不应显著高于恒定块（阈值 3x），且输出 RMS 应一致（阈值 2%）。")
cost_ok = m2 <= m1 * 3
level_ok = abs(r2 - r1) / max(r1, 1e-9) < 0.02
print("  抖动/恒定 中位耗时放大 = %.1fx  -> %s" % (m2 / max(m1, 1e-9), "OK" if cost_ok else "FAIL"))
print("  抖动/恒定 RMS 偏差     = %.2f%% -> %s" % (abs(r2 - r1) / max(r1, 1e-9) * 100,
                                            "OK" if level_ok else "FAIL"))
print("VERDICT: %s" % ("PASS - 块长抖动不再重建卷积器" if (cost_ok and level_ok)
                       else "FAIL - 抖动仍在触发重建"))