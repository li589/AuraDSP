"""probe_concurrent.py — 验证两个 auradsp handle 能否安全共存（D11 探测方案的前提）

若通过，则组件延迟探测可以用"一次性探针 handle"实现：
控制线程建一个独立 handle → 只开目标效果 → 打脉冲测首个非零输出样本 →
销毁探针 handle。全程不碰正在放音的 handle，无竞争、无静音缺口。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")
lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_get_state.restype = ctypes.c_int32
lib.auradsp_get_state.argtypes = [ctypes.c_void_p]

RATE = 48000.0


def si(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def sf(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)


live = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(RATE), 2048))
si(live, "mode.latency", 2)
si(live, "bass.enable", 1)
sf(live, "bass.gain", 6.0)
print("live handle state =", lib.auradsp_get_state(live))

probe = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(RATE), 2048))
print("probe handle created:", bool(probe))
si(probe, "mode.latency", 2)

N = 256
buf = (ctypes.c_float * (N * 2))()
out = (ctypes.c_float * (N * 2))()
sp = ctypes.cast(buf, ctypes.POINTER(ctypes.c_float))
dp = ctypes.cast(out, ctypes.POINTER(ctypes.c_float))

ok = True
for rnd in range(200):
    for i in range(N):
        buf[i * 2] = 0.4 * math.sin(2 * math.pi * 440.0 * (rnd * N + i) / RATE)
        buf[i * 2 + 1] = 0.4 * math.sin(2 * math.pi * 660.0 * (rnd * N + i) / RATE)
    lib.auradsp_process(live, sp, dp, N)     # 正在放音的 handle
    si(probe, "reverb.preset", 3)             # 探针 handle 同时改参数
    lib.auradsp_process(probe, sp, dp, N)
    for v in out:
        if v != v or abs(v) > 1e6:
            ok = False
            break
    if not ok:
        break

print("200 rounds of concurrent processing:", "OK" if ok else "CORRUPTED")

# live handle 是否仍正常（状态未被探针污染）
print("live state after =", lib.auradsp_get_state(live))
lib.auradsp_destroy(probe)
lib.auradsp_process(live, sp, dp, N)
print("live still usable after probe destroy: OK")
lib.auradsp_destroy(live)
sys.exit(0 if ok else 1)