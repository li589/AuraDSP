# -*- coding: utf-8 -*-
# 复现 app 的驱动方式：1056 帧块 + 每 33ms viz_read(8)
import ctypes, math, time

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

h = dll.auradsp_create(48000.0, 2048)
N = 1056
buf = (ctypes.c_float * (N*2))()
out = (ctypes.c_float * (N*2))()
frames = (VizFrame * 8)()

phase = 0.0
for i in range(100):
    for n in range(N):
        s = 0.3 * math.sin(phase) * (0.5 + 0.5*math.sin(phase*0.11))
        phase += 2*math.pi*60.0/48000.0
        buf[2*n] = s; buf[2*n+1] = s
    dll.auradsp_process(h, buf, out, N)
    if i % 3 == 0:
        n = dll.auradsp_viz_read(h, frames, 8)
        if n and i % 10 == 0:
            print("blk %d viz n=%d seq=%d band0=%.3f band5=%.3f" % (
                i, n, frames[n-1].seq, frames[n-1].spectrum[0], frames[n-1].spectrum[5]), flush=True)
print("OK: 100 blocks x 1056 frames survived")
dll.auradsp_destroy(h)
