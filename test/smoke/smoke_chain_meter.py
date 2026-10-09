import ctypes
import math

DLL_PATH = r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll"
dll = ctypes.CDLL(DLL_PATH)

class VizFrame(ctypes.Structure):
    _fields_ = [
        ("seq", ctypes.c_uint64),
        ("timestamp_ms", ctypes.c_double),
        ("spectrum", ctypes.c_float * 32),
        ("level_l_dbfs", ctypes.c_float),
        ("level_r_dbfs", ctypes.c_float),
        ("stage_levels_l", ctypes.c_float * 16),
        ("stage_levels_r", ctypes.c_float * 16),
    ]

dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_process.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_float),
    ctypes.POINTER(ctypes.c_float),
    ctypes.c_int,
]
dll.auradsp_set_param.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_void_p,
    ctypes.c_uint32,
]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_viz_read.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(VizFrame),
    ctypes.c_uint32,
]
dll.auradsp_viz_read.restype = ctypes.c_uint32

h = dll.auradsp_create(48000.0, 240)
assert h, "Failed to create engine handle"

N = 240
in_buf = (ctypes.c_float * (N * 2))()
out_buf = (ctypes.c_float * (N * 2))()
frames = (VizFrame * 64)()

# 1) 未开启效果时直通，测试输入幅值为 0.3 (-10.46 dBFS)
phase = 0.0
last_frame = None
for _ in range(300):
    for i in range(N):
        val = 0.3 * math.sin(phase)
        phase += 2.0 * math.pi * 1000.0 / 48000.0
        in_buf[2 * i] = val
        in_buf[2 * i + 1] = val
    dll.auradsp_process(h, in_buf, out_buf, N)
    n = dll.auradsp_viz_read(h, frames, 64)
    if n > 0:
        last_frame = frames[n - 1]

assert last_frame is not None, "No viz frames received"
print(f"Overall output levels: L={last_frame.level_l_dbfs:.2f}dBFS, R={last_frame.level_r_dbfs:.2f}dBFS")
assert -11.0 < last_frame.level_l_dbfs < -9.5, f"Unexpected overall level: {last_frame.level_l_dbfs}"

# stage 顺序对照：
# 0: tube, 1: comp, 2: bass, 3: eq, 4: arbmag, 5: convolver,
# 6: ddc, 7: liveprog, 8: crossfeed, 9: stereo, 10: reverb, 11: output
stages_l = list(last_frame.stage_levels_l)[:12]
stages_r = list(last_frame.stage_levels_r)[:12]
print("Pass 1 stage levels (expect all around -10.5 dBFS in passthrough):")
for idx, (l_val, r_val) in enumerate(zip(stages_l, stages_r)):
    print(f"  Stage {idx:02d}: L={l_val:.2f}dBFS, R={r_val:.2f}dBFS")
    assert -12.0 < l_val < -9.0, f"Stage {idx} level mismatch: {l_val}"

# 2) 开启 liveprog (增益 2.0x，即 +6.02dB)，观察 stage 7 及后续 stage 电平提升
script = """@init
dummy = 1;
@sample
spl0 *= 2.0;
spl1 *= 2.0;
"""
b_script = script.encode("utf-8")
c_buf = (ctypes.c_char * len(b_script)).from_buffer_copy(b_script)
rc = dll.auradsp_set_param(h, b"liveprog.code", c_buf, len(b_script))
assert rc == 0, f"set liveprog.code failed: {rc}"
on = ctypes.c_int32(1)
rc = dll.auradsp_set_param(h, b"liveprog.enable", ctypes.byref(on), 4)
assert rc == 0, f"set liveprog.enable failed: {rc}"

last_frame = None
for _ in range(300):
    for i in range(N):
        val = 0.3 * math.sin(phase)
        phase += 2.0 * math.pi * 1000.0 / 48000.0
        in_buf[2 * i] = val
        in_buf[2 * i + 1] = val
    dll.auradsp_process(h, in_buf, out_buf, N)
    n = dll.auradsp_viz_read(h, frames, 64)
    if n > 0:
        last_frame = frames[n - 1]

assert last_frame is not None
stages_l_gain = list(last_frame.stage_levels_l)[:12]
print("\nPass 2 with liveprog x2.0 gain:")
for idx, l_val in enumerate(stages_l_gain):
    print(f"  Stage {idx:02d}: L={l_val:.2f}dBFS")

# 验证 stage 0~6（上游）仍为 ~ -10.5 dBFS，而 stage 7~11（下游）提升至约 -4.4 dBFS
for idx in range(7):
    assert -12.0 < stages_l_gain[idx] < -9.0, f"Upstream stage {idx} should not be affected by liveprog: {stages_l_gain[idx]}"
for idx in range(7, 12):
    assert -5.5 < stages_l_gain[idx] < -3.5, f"Downstream stage {idx} should be boosted by +6dB: {stages_l_gain[idx]}"

print("\nPASS: smoke_chain_meter passed successfully! All 12 per-stage meters validated.")
dll.auradsp_destroy(h)
