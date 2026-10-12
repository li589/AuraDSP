# -*- coding: utf-8 -*-
"""逐个验证 auradsp_engine.dll 副本是否含 EQ 输入 tap（a0869de）。

不信时间戳/哈希，直接跑功能断言：eq_in_spectrum 必须非零。
这能区分「文件是旧的」和「文件是新的但进程里跑的是旧的」。
"""
import ctypes
import glob
import os
import random
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
BANDS = 32


class VizFrame(ctypes.Structure):
    _fields_ = [
        ("seq", ctypes.c_uint64),
        ("timestamp_ms", ctypes.c_double),
        ("spectrum", ctypes.c_float * BANDS),
        ("eq_in_spectrum", ctypes.c_float * BANDS),
        ("level_l_dbfs", ctypes.c_float),
        ("level_r_dbfs", ctypes.c_float),
        ("stage_levels_l", ctypes.c_float * 16),
        ("stage_levels_r", ctypes.c_float * 16),
    ]


def check(path):
    dll = ctypes.CDLL(path)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_set_param.restype = ctypes.c_int
    dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_viz_read.restype = ctypes.c_uint32
    dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(VizFrame),
                                     ctypes.c_uint32]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_version.restype = ctypes.c_char_p

    h = ctypes.c_void_p(dll.auradsp_create(48000.0, 1024))
    if not h:
        return None, "create 失败"
    cb = b"60:9;300:0;1000:-9;8000:0;16000:9"
    pb = (ctypes.c_char * len(cb)).from_buffer_copy(cb)
    dll.auradsp_set_param(h, b"eq.curve", pb, len(cb))
    dll.auradsp_set_param(h, b"eq.enable", ctypes.byref(ctypes.c_int32(1)), 4)
    rng = random.Random(7)
    bi = (ctypes.c_float * 2048)()
    bo = (ctypes.c_float * 2048)()
    vb = (VizFrame * 8)()
    peak_in = 0.0
    for _ in range(300):
        for i in range(2048):
            bi[i] = rng.uniform(-0.3, 0.3)
        dll.auradsp_process(h, bi, bo, 1024)
        n = dll.auradsp_viz_read(h, vb, 8)
        if n > 0:
            peak_in = max(peak_in, max(vb[n - 1].eq_in_spectrum))
    ver = dll.auradsp_version().decode(errors="replace")
    dll.auradsp_destroy(h)
    return (peak_in, ver), None


paths = sorted(glob.glob(os.path.join(ROOT, "**", "auradsp_engine.dll"),
                         recursive=True))
if not paths:
    print("没找到任何副本")
    sys.exit(1)

print("%-62s %-10s %-8s %s" % ("path", "eq_in", "ver", "verdict"))
print("-" * 100)
allgood = True
for p in paths:
    res, err = check(p)
    rel = p.replace(ROOT + os.sep, "")
    if err:
        print("%-62s %-10s %-8s %s" % (rel, "-", "-", "ERR " + err))
        allgood = False
        continue
    peak_in, ver = res
    ok = peak_in > 0.05
    allgood = allgood and ok
    print("%-62s %-10.4f %-8s %s" % (rel, peak_in, ver,
                                       "NEW (含 EQ tap)" if ok else "OLD (无 EQ tap)"))

print("-" * 100)
print("全部为新版" if allgood else "存在旧版副本")
sys.exit(0 if allgood else 1)