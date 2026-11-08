# -*- coding: utf-8 -*-
# 多声道 EEL 脚本级（方案 B）边界与并发门禁：
# 越界声道读 0/写丢弃、num_ch 随声道切换、坏脚本保旧码、unload 直通、
# 直通脚本比特精确、非有限卫士、@block 段语义、换码竞态压测。
import ctypes, math, struct, sys, threading, time

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
assert h
i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)

def set_i(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)
def set_str(pid, s):
    b = s.encode("utf-8")
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))
def get_i(pid):
    v = ctypes.c_int32()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value

N = 480

def make_io(ch):
    buf = (ctypes.c_float * (N * ch))()
    out = (ctypes.c_float * (N * ch))()
    for n in range(N):
        for c in range(ch):
            buf[n * ch + c] = 0.08 * (c + 1)
    return buf, out

def run(ch, blocks=4, frames=None):
    buf, out = make_io(ch)
    f = frames if frames is not None else N
    for _ in range(blocks):
        dll.auradsp_process(h, buf, out, f)
    return buf, out

def chvals(out, ch, c):
    return [out[n * ch + c] for n in range(0, N, 53)]

def expect(vals, want, label, tol=1e-5):
    for v in vals:
        assert abs(v - want) <= tol, f"{label}: got {v}, want {want}"

def set_channels(ch):
    assert set_i("channels.count", ch) == 0
    assert set_i("channels.mode", 1) == 0

# ---------- 1. 越界声道：读为 0、写丢弃（4 声道） ----------
set_channels(4)
assert set_str("liveprogmc.code",
               "@init\n// oob read\n@sample\nspl0 = spl7;\n") == 0
assert set_i("liveprogmc.enable", 1) == 0
_, out = run(4)
expect(chvals(out, 4, 0), 0.0, "OOB read spl7 in 4ch must be 0")
expect(chvals(out, 4, 1), 0.16, "4ch ch1 untouched")

assert set_str("liveprogmc.code",
               "@init\n// oob write\n@sample\nspl7 = 1.0;\nspl6 = -3.0;\nspl1 = spl1 * 0.5;\n") == 0
_, out = run(4)
expect(chvals(out, 4, 0), 0.08, "OOB write ch0 untouched")
expect(chvals(out, 4, 1), 0.08, "OOB write ch1 halved")
expect(chvals(out, 4, 2), 0.24, "OOB write ch2 untouched")
expect(chvals(out, 4, 3), 0.32, "OOB write ch3 untouched")

# ---------- 2. num_ch 随声道数切换 ----------
assert set_str("liveprogmc.code",
               "@init\n// numch\n@sample\nspl1 = num_ch;\n") == 0
for ch, want in ((8, 8.0), (6, 6.0), (4, 4.0), (8, 8.0)):
    set_channels(ch)
    _, out = run(ch)
    expect(chvals(out, ch, 1), want, f"num_ch == {want} in {ch}ch")

# ---------- 3. 坏脚本：返回错误、状态负、旧代码继续运行 ----------
set_channels(8)
assert set_str("liveprogmc.code",
               "@init\n// good\n@sample\nspl0 = spl0 * 0.5;\n") == 0
_, out = run(8)
expect(chvals(out, 8, 0), 0.04, "good script halves ch0")
rc = set_str("liveprogmc.code", "@init\n@sample\nspl0 = spl0 * ;\n")
assert rc != 0, "bad script must fail set_param"
assert get_i("liveprogmc.status") < 0, "status must be negative after bad load"
_, out = run(8)
expect(chvals(out, 8, 0), 0.04, "old code still running after bad load")
rc = set_str("liveprogmc.code", "@sample\nspl0 = 1;\n")
assert rc != 0, "missing @init must fail set_param"
assert get_i("liveprogmc.status") == 0, "missing @init -> status 0"

# ---------- 4. unload：状态清零、直通 ----------
assert set_i("liveprogmc.unload", 1) == 0
assert get_i("liveprogmc.status") == 0
assert get_i("liveprogmc.enable") == 0
_, out = run(8)
expect(chvals(out, 8, 0), 0.08, "after unload passthrough")

# ---------- 5. 直通脚本与未使能比特精确 ----------
_, out_off = run(8)
# 注：空 @sample 段编译不出 code handle（与立体声同口径），直通脚本用恒等式
assert set_str("liveprogmc.code",
               "@init\n// noop\n@sample\n"
               "spl0 = spl0; spl1 = spl1; spl2 = spl2; spl3 = spl3;\n"
               "spl4 = spl4; spl5 = spl5; spl6 = spl6; spl7 = spl7;\n") == 0
assert set_i("liveprogmc.enable", 1) == 0
_, out_on = run(8)
bits_off = struct.pack(f"<{N * 8}f", *list(out_off))
bits_on = struct.pack(f"<{N * 8}f", *list(out_on))
assert bits_off == bits_on, "passthrough script must be bit-exact vs disabled"

# ---------- 6. 非有限卫士：inf/NaN 写回必须变 0 ----------
assert set_str("liveprogmc.code",
               "@init\n// nonfinite\n@sample\nspl0 = 1 / 0;\nspl1 = sqrt(-1);\n") == 0
_, out = run(8)
for v in chvals(out, 8, 0) + chvals(out, 8, 1):
    assert math.isfinite(v) and v == 0.0, f"non-finite guard failed: {v}"
expect(chvals(out, 8, 2), 0.24, "guard leaves other channels alone")

# ---------- 7. @block 段：每块执行一次 ----------
assert set_str("liveprogmc.code",
               "@init\ncnt = 0;\n@block\ncnt += 1;\n@sample\nspl0 = cnt;\n") == 0
set_i("liveprogmc.enable", 1)
_, out1 = run(8, blocks=3)
v1 = out1[0]
_, out2 = run(8, blocks=3)
v2 = out2[0]
assert v2 - v1 == 3, f"@block must run once per block: {v1} -> {v2}"

# ---------- 8. 小块长：frames=1 / 7 ----------
assert set_str("liveprogmc.code",
               "@init\n// small\n@sample\nspl3 = spl0 + spl1;\n") == 0
for frames in (1, 7):
    buf, out = make_io(8)
    dll.auradsp_process(h, buf, out, frames)
    for n in range(frames):
        assert abs(out[n * 8 + 3] - 0.24) < 1e-5, f"frames={frames} spl3 sum"

# ---------- 9. 换码竞态：处理线程连续跑 + 控制线程高频换码 ----------
stop = threading.Event()
errors = []
def rt_loop():
    buf, out = make_io(8)
    while not stop.is_set():
        dll.auradsp_process(h, buf, out, N)
        for v in out:
            if not math.isfinite(v):
                errors.append("non-finite output during race")
                return
t = threading.Thread(target=rt_loop)
t.start()
scripts = [
    "@init\n// a\n@sample\nspl0 = spl0 * 0.5;\n",
    "@init\n// b\n@sample\nspl2 = spl0 + spl1;\nspl3 = spl3 * 0.25;\n",
    "@init\n// bad\n@sample\nspl0 = ;\n",
]
t0 = time.time()
k = 0
while time.time() - t0 < 3.0:
    set_str("liveprogmc.code", scripts[k % len(scripts)])
    k += 1
stop.set()
t.join(timeout=10)
assert not t.is_alive(), "RT thread stuck (possible deadlock in slot swap)"
assert not errors, errors
# 竞态后落定到已知脚本，行为必须确定
assert set_str("liveprogmc.code",
               "@init\n// final\n@sample\nspl0 = spl0 * 0.5;\n") == 0
assert get_i("liveprogmc.status") == 1
_, out = run(8)
expect(chvals(out, 8, 0), 0.04, "post-race deterministic behavior")

print("smoke_liveprog_mc_stress: PASS (oob / num_ch / bad-keeps-old / unload / bit-exact / nonfinite / @block / small frames / race)")
sys.exit(0)
