# -*- coding: utf-8 -*-
# 低频频段修复验证 v2：相位连续的 60Hz 正弦流（不重用块缓冲）
import ctypes, math, os, sys

# S1 迁移（2026-11-01）：路径统一走 test/engine_artifact 解析
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
from engine_artifact import engine_lib_path as _elp, REPO_ROOT as _RR  # noqa: E402
dll = ctypes.CDLL(_elp())


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
# DC 修复断言：band0 不应因直流泄漏常亮。
# 阈值 0.2：60Hz 正弦在 band0（20–25Hz）的汉宁窗旁瓣随 viz 产出间隔变化——
# 100Hz 产出时 engine_viz.cpp 记录为 0.061，2026-10-29 产出降到 30Hz 后
# DC blocker 重复递推次数变少，旁瓣升到 0.122（AURADSP_GATE=0 复测逐位相同，
# 与静音门控无关）。真正的直流泄漏实测 0.319，0.2 仍能判红；不要再放宽。
assert b[0] < 0.2, "FAIL: band0 DC leakage: %.3f" % b[0]
print("PASS: 60Hz lands in band4/5 (peak band=%d=%.3f), band0=%.3f (no DC leak)" % (peak, b[peak], b[0]))
dll.auradsp_destroy(h)
