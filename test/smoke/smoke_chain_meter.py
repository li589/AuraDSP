import ctypes
import math
import os
import sys

# S1 迁移（2026-11-01）：路径统一走 test/engine_artifact 解析
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
from engine_artifact import engine_lib_path as _elp, REPO_ROOT as _RR  # noqa: E402
DLL_PATH = _elp()
dll = ctypes.CDLL(DLL_PATH)


# --- VizFrame 单一来源（§7-1 ABI 镜像门禁）---
# ctypes 镜像只在 tools/bin/viz_frame.py 定义一次，这里不再手抄。
# 手抄件的危险：头文件 sizeof 改了却漏改某个脚本 → 脚本按旧尺寸申请缓冲、
# 引擎按新尺寸写 → 静默堆越界（审查 A1/A2/A3 三处即此）。viz_frame 导入时
# 自带 sizeof / ABI 版本哨兵，出错就地抛 AssertionError。
_VIZ_ROOT = os.path.dirname(os.path.abspath(__file__))
while not os.path.isfile(os.path.join(_VIZ_ROOT, 'tools', 'bin', 'viz_frame.py')):
    _VIZ_PARENT = os.path.dirname(_VIZ_ROOT)
    if _VIZ_PARENT == _VIZ_ROOT:
        raise ImportError('未找到 tools/bin/viz_frame.py（VizFrame 的唯一定义处）')
    _VIZ_ROOT = _VIZ_PARENT
if os.path.join(_VIZ_ROOT, 'tools', 'bin') not in sys.path:
    sys.path.insert(0, os.path.join(_VIZ_ROOT, 'tools', 'bin'))
from viz_frame import VizFrame  # noqa: E402


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
# 0..11: vendor 12 stages (tube, comp, bass, eq, arbmag, convolver, ddc, liveprog, crossfeed, stereo, reverb, output)
# 12: gate in, 13: gate out, 14: dyneq, 15: filter, 16: bassmono, 17: haas, 18: exciter, 19: loudness,
# 20: spatial
# 21..23, 30..31: reserved (-120 dBFS)
# 24: limiter GR, 25: comp GR, 26: gate GR, 27..29: dyneq low/mid/high GR (0.0 dB in passthrough)
stages_l = list(last_frame.stage_levels_l)
stages_r = list(last_frame.stage_levels_r)
print("Pass 1 stage levels (expect stages 0..20 all around -10.5 dBFS, 21..23/30..31 == -120, 24..29 GR == 0.0):")
for idx in range(21):
    l_val = stages_l[idx]
    r_val = stages_r[idx]
    print(f"  Stage {idx:02d}: L={l_val:.2f}dBFS, R={r_val:.2f}dBFS")
    assert -12.0 < l_val < -9.0, f"Stage {idx} L mismatch: {l_val}"
    assert -12.0 < r_val < -9.0, f"Stage {idx} R mismatch: {r_val}"

for idx in [21, 22, 23, 30, 31]:
    assert stages_l[idx] == -120.0, f"Reserved stage {idx} should be -120, got {stages_l[idx]}"
    assert stages_r[idx] == -120.0, f"Reserved stage {idx} should be -120, got {stages_r[idx]}"

for idx in range(24, 30):
    assert abs(stages_l[idx]) < 1e-4, f"GR stage {idx} should be 0.0 dB in passthrough, got {stages_l[idx]}"
    assert abs(stages_r[idx]) < 1e-4, f"GR stage {idx} should be 0.0 dB in passthrough, got {stages_r[idx]}"

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

print("\nPASS: smoke_chain_meter passed successfully! All 20 per-stage meters validated.")
dll.auradsp_destroy(h)
