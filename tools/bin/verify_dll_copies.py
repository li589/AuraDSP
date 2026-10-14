# -*- coding: utf-8 -*-
"""auradsp_engine.dll 分发 + 验证（P0：单向政策）。

正式位置只剩 3 处：
  真相源  core/desktop/windows/out/Release/auradsp_engine.dll（构建产物）
  运行副本 app/auradsp_app/windows/runner/auradsp_engine.dll（随 flutter 打包）
  运行副本 test/auradsp_engine.dll（smoke 用）
其余散落副本已删除。流程：真相源 → 分发到 2 运行副本 → 功能断言全验。
不信时间戳/哈希，直接跑功能断言：eq_in_spectrum 必须非零。
这能区分「文件是旧的」和「文件是新的但进程里跑的是旧的」。
"""
import ctypes
import glob
import os
import random
import shutil
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
BANDS = 32

TRUTH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                     "auradsp_engine.dll")
RUNTIME = [
    os.path.join(ROOT, "app", "auradsp_app", "windows", "runner",
                 "auradsp_engine.dll"),
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
]


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

# P0 单向分发：真相源 → 运行副本（App 运行时锁住会跳过并报错，不静默）。
print("== 分发 ==")
for dst in RUNTIME:
    try:
        shutil.copyfile(TRUTH, dst)
        print(f"  OK {os.path.relpath(dst, ROOT)}")
    except OSError as e:
        print(f"  LOCKED（App 可能在跑，先退出再重跑） {os.path.relpath(dst, ROOT)}: {e}")
        sys.exit(2)

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

# VB 桥分发（05）：真相源 → 同 2 处运行副本；仅校验加载+导出存在，
# 功能断言归 smoke_vm_bridge.py（需 Voicemeeter 在线）。
BRIDGE_TRUTH = os.path.join(ROOT, "core", "desktop", "windows-drivers", "out",
                            "Release", "auravm_bridge.dll")
BRIDGE_RUNTIME = [
    os.path.join(ROOT, "app", "auradsp_app", "windows", "runner",
                 "auravm_bridge.dll"),
    os.path.join(ROOT, "test", "auravm_bridge.dll"),
]
print("== VB 桥分发 ==")
if os.path.exists(BRIDGE_TRUTH):
    for dst in BRIDGE_RUNTIME:
        try:
            shutil.copyfile(BRIDGE_TRUTH, dst)
            print(f"  OK {os.path.relpath(dst, ROOT)}")
        except OSError as e:
            print(f"  LOCKED（App 可能在跑，先退出再重跑） {os.path.relpath(dst, ROOT)}: {e}")
            sys.exit(2)
    try:
        b = ctypes.CDLL(BRIDGE_TRUTH)
        for sym in ("vb_detect", "vb_start", "vb_stop", "vb_status",
                    "vb_set_param", "vb_viz_read", "vb_test_start",
                    "vb_test_stop", "vb_bypass"):
            getattr(b, sym)
        print("  导出表 9/9 OK")
    except OSError as e:
        print(f"  桥加载失败: {e}")
        sys.exit(1)
else:
    print("  跳过（真相源未构建）")

sys.exit(0 if allgood else 1)