# -*- coding: utf-8 -*-
# 算法性能基准：各效果每块(480f=10ms@48k)处理耗时 + eq.curve 重建耗时
import ctypes, math, time

dll = ctypes.CDLL(r"core\desktop\windows\out\Release\auradsp_engine.dll")
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
h = dll.auradsp_create(48000.0, 480)
f32 = lambda v: ctypes.c_float(v); i32 = lambda v: ctypes.c_int32(v)
def set_f(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)
def set_i(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)
def set_str(pid, s):
    b = s.encode(); buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))
N = 480
buf = (ctypes.c_float * (N*2))(); out = (ctypes.c_float * (N*2))()
ph = 0.0
for n in range(N):
    s = 0.3*math.sin(ph) + 0.1*math.sin(ph*2.7)
    ph += 2*math.pi*220.0/48000.0
    buf[2*n]=s; buf[2*n+1]=s

def bench(label, blocks=2000):
    dll.auradsp_process(h, buf, out, N)  # 预热
    t0 = time.perf_counter()
    for _ in range(blocks):
        dll.auradsp_process(h, buf, out, N)
    dt = (time.perf_counter() - t0) / blocks * 1e6  # us/块
    print("%-34s %8.1f us/块  (%5.2f%% of 10ms)" % (label, dt, dt/100))
    return dt

set_i("mode.latency", 2)
print("== 每 480 帧块（10ms@48k）处理耗时 ==")
d0 = bench("基线（vendor 链全关）")
set_i("shelf.enable", 1); set_f("shelf.gain", 6.0)
d1 = bench("+ 低频搁架")
set_i("freeverb.enable", 1); set_f("freeverb.wet", 0.3)
d2 = bench("+ Freeverb")
set_i("tube.enable", 1); set_i("crossfeed.enable", 1)
d3 = bench("+ tube + crossfeed")
set_i("freeverb.enable", 0); set_i("tube.enable", 0); set_i("crossfeed.enable", 0)
set_i("shelf.enable", 0)
d4 = bench("回落基线（一致性校验）")
assert abs(d4 - d0) < max(2.0, d0 * 0.15), (d0, d4)

# eq.curve 重建耗时（单次 set_param 往返）
rebuild = []
for _ in range(5):
    t0 = time.perf_counter()
    set_str("eq.curve", "100:0;440:6;1000:0;4000:0;10000:0")
    rebuild.append((time.perf_counter() - t0) * 1e3)
print("%-34s %8.2f ms/次  (makima + 最小相位 IR 重建)" % ("eq.curve 重建",
      sorted(rebuild)[2]))

# liveprog 空脚本编译耗时（参考）
print("\n审计点：viz 每 10ms 一次 4096 FFT + 去均值已含在基线内")
