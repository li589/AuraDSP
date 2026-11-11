# -*- coding: utf-8 -*-
# 多声道 EEL 脚本级（liveprog.mc，方案 B）引擎级验证：
# 8 声道 spl0..spl7 读写 / 逐声道增益 / 滑块与立体声参数隔离 /
# 代码回读与状态 / 未使能直通。边界与竞态见 smoke_liveprog_mc_stress。
import ctypes, sys

import os as _os, sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
from engine_artifact import engine_lib_path as _elp  # noqa: E402

dll = ctypes.CDLL(_elp())
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]

h = dll.auradsp_create(48000.0, 480)
assert h, "auradsp_create failed"
i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)

def set_i(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)
def set_f(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)
def set_str(pid, s):
    b = s.encode("utf-8")
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))
def get_i(pid):
    v = ctypes.c_int32()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value
def get_f(pid):
    v = ctypes.c_float()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value
def get_str(pid, n=8192):
    buf = ctypes.create_string_buffer(n)
    rc = dll.auradsp_get_param(h, pid.encode(), buf, n)
    return rc, buf.value.decode("utf-8", "replace")

CH = 8
N = 480
# 逐声道不同常数：ch c = 0.08*(c+1)（0.08 .. 0.64），便于逐路核对
IN = [0.08 * (c + 1) for c in range(CH)]
buf = (ctypes.c_float * (N * CH))()
out = (ctypes.c_float * (N * CH))()
for n in range(N):
    for c in range(CH):
        buf[n * CH + c] = IN[c]

def run(blocks=6):
    for _ in range(blocks):
        dll.auradsp_process(h, buf, out, N)
    return [[out[n * CH + c] for n in range(0, N, 37)] for c in range(CH)]

def expect(vals, want, label, tol=1e-5):
    for v in vals:
        assert abs(v - want) <= tol, f"{label}: got {v}, want {want}"

assert set_i("channels.count", CH) == 0
assert set_i("channels.mode", 1) == 0  # 离散多声道：逐声道独立，链路透明

# ---- 基线：无脚本时多声道链逐声道直通 ----
base = run()
for c in range(CH):
    expect(base[c], IN[c], f"baseline ch{c}")

# ---- 脚本 1：第 5 声道 = 第 1 声道 × 0.5，其余不动 ----
script1 = "@init\n// mc basic\n@sample\nspl4 = spl0 * 0.5;\n"
assert set_str("liveprogmc.code", script1) == 0, "load script1"
assert get_i("liveprogmc.status") == 1, "status after load"
rc, back = get_str("liveprogmc.code")
assert rc == 0 and back == script1, "code readback"
assert set_i("liveprogmc.enable", 1) == 0
r = run()
expect(r[4], IN[0] * 0.5, "script1 ch4 = ch0*0.5")
for c in (0, 1, 2, 3, 5, 6, 7):
    expect(r[c], IN[c], f"script1 ch{c} untouched")

# ---- 脚本 2：逐声道增益 + slider 控制 + 与立体声参数隔离 ----
assert set_f("liveprogmc.param1", 0.5) == 0
assert set_f("liveprog.param1", 0.9) == 0  # 立体声同名滑块：不得串扰
script2 = ("@init\n// gains\n@sample\n"
           "spl0 = spl0 * 0.5;\n"
           "spl1 = spl1 * slider1;\n"
           "spl7 = spl7 * 0.25;\n")
assert set_str("liveprogmc.code", script2) == 0, "load script2"
assert get_i("liveprogmc.status") == 1
r = run()
expect(r[0], IN[0] * 0.5, "script2 ch0 gain")
expect(r[1], IN[1] * 0.5, "script2 ch1 slider gain (mc param1=0.5)")
expect(r[7], IN[7] * 0.25, "script2 ch7 gain")
for c in (2, 3, 4, 5, 6):
    expect(r[c], IN[c], f"script2 ch{c} untouched")
assert abs(get_f("liveprogmc.param1") - 0.5) < 1e-6, "mc param1 readback"
assert abs(get_f("liveprog.param1") - 0.9) < 1e-6, "stereo param1 isolation"

# ---- 未使能：脚本在位也必须直通 ----
assert set_i("liveprogmc.enable", 0) == 0
r = run()
for c in range(CH):
    expect(r[c], IN[c], f"disabled ch{c} passthrough")

print("smoke_liveprog_mc: PASS (8ch spl rw / gains / slider isolation / readback / disable)")
sys.exit(0)
