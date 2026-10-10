# -*- coding: utf-8 -*-
# 低频频段修复验证 v2：相位连续的 60Hz 正弦流（不重用块缓冲）
import ctypes, math

dll = ctypes.CDLL(r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll")

class VizFrame(ctypes.Structure):
    # 必须与 auradsp_engine.h 的 auradsp_viz_frame 逐字节一致（280 字节）。
    # 早期版本漏了 stage_levels_l/r（M3.5-c 才加入 ABI），结构只有 152 字节；
    # 于是 auradsp_viz_read(out, 8) 会往 1216 字节的缓冲里写 2240 字节，
    # 造成 1024 字节堆溢出（STATUS_HEAP_CORRUPTION 0xC0000374）。
    # 下面的 sizeof 断言用于在 ABI 再变时立刻失败，而不是静默越界。
    _fields_ = [("seq", ctypes.c_uint64), ("timestamp_ms", ctypes.c_double),
                ("spectrum", ctypes.c_float * 32),
                ("level_l_dbfs", ctypes.c_float), ("level_r_dbfs", ctypes.c_float),
                ("stage_levels_l", ctypes.c_float * 16),
                ("stage_levels_r", ctypes.c_float * 16)]

assert ctypes.sizeof(VizFrame) == 280, (
    "VizFrame out of sync with auradsp_viz_frame: expected 280, got "
    + str(ctypes.sizeof(VizFrame)))

dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(VizFrame), ctypes.c_uint32]
dll.auradsp_viz_read.restype = ctypes.c_uint32

h = dll.auradsp_create(48000.0, 240)
N = 240
buf = (ctypes.c_float * (N*2))()
out = (ctypes.c_float * (N*2))()
frames = (VizFrame * 64)()

phase = 0
last = None
for i in range(400):
    for n in range(N):
        s = 0.3 * math.sin(phase)
        phase += 2*math.pi*60.0/48000.0
        buf[2*n] = s; buf[2*n+1] = s
    dll.auradsp_process(h, buf, out, N)
    n = dll.auradsp_viz_read(h, frames, 64)
    if n: last = frames[n-1]

assert last is not None, "no viz frames"
b = list(last.spectrum)
lvl = max(last.level_l_dbfs, last.level_r_dbfs)
print("seq=%d lvl=%.2f dBFS" % (last.seq, lvl))
print("bands[0:8]:", ["%.3f" % x for x in b[:8]])

assert -13 < lvl < -9, "level mismatch: %s" % lvl
assert b[4] > 0.3, "FAIL: 50-63Hz band (band4) not lit: %s" % b[:8]
peak = max(range(8), key=lambda i: b[i])
assert peak in (4, 5), "FAIL: peak in band %d (expect 4/5 for 60Hz)" % peak
# DC 修复断言：band0 不应因直流泄漏常亮
assert b[0] < 0.1, "FAIL: band0 DC leakage: %.3f" % b[0]
print("PASS: 60Hz lands in band4/5 (peak band=%d=%.3f), band0=%.3f (no DC leak)" % (peak, b[peak], b[0]))
dll.auradsp_destroy(h)
