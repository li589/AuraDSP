# -*- coding: utf-8 -*-
# 复现 app 的驱动方式：1056 帧块 + 每 33ms viz_read(8)
import ctypes, math, os, sys, time

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
