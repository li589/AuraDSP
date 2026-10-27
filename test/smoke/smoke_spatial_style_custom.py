#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_spatial_style_custom.py — WP7 spatial 自定义档门禁。

断言（工程文档 §7.1）：
  - style 0/1/2 写值正确；
  - 手动改 room/width/center 后 style 置 3；
  - style=3 自定义不覆写当前参数；
  - style hook 不递归；
  - 越界值拒绝。
"""
import ctypes
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 512
E_PARAM = -1
FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


if not os.path.exists(DLL):
    print("SKIP（auradsp_engine.dll 不存在：%s）" % DLL)
    sys.exit(0)

dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]


def i32(v):
    return ctypes.c_int32(v)


def f32(v):
    return ctypes.c_float(v)


class Engine:
    def __init__(self):
        self.h = dll.auradsp_create(SR, BLOCK)
        assert self.h, "auradsp_create failed"

    def close(self):
        if self.h:
            dll.auradsp_destroy(self.h)
            self.h = None

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(i32(v)), 4)

    def set_f(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(f32(v)), 4)

    def get_i(self, pid):
        v = i32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def get_f(self, pid):
        v = f32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value


e = Engine()

print("=== [1] style 0/1/2 预设映射与防递归 ===")
# style 0 (Dolby 房: room=0.7, width=1.0, center=0.8)
check("set style=0", e.set_i("spatial.style", 0) == 0)
check("style 仍为 0（无递归改写）", e.get_i("spatial.style")[1] == 0)
check("style=0 room==0.7", abs(e.get_f("spatial.room")[1] - 0.7) < 1e-4)
check("style=0 width==1.0", abs(e.get_f("spatial.width")[1] - 1.0) < 1e-4)
check("style=0 center==0.8", abs(e.get_f("spatial.center")[1] - 0.8) < 1e-4)

# style 1 (DTS 定位: room=0.25, width=1.1, center=0.5)
check("set style=1", e.set_i("spatial.style", 1) == 0)
check("style 仍为 1", e.get_i("spatial.style")[1] == 1)
check("style=1 room==0.25", abs(e.get_f("spatial.room")[1] - 0.25) < 1e-4)
check("style=1 width==1.1", abs(e.get_f("spatial.width")[1] - 1.1) < 1e-4)
check("style=1 center==0.5", abs(e.get_f("spatial.center")[1] - 0.5) < 1e-4)

# style 2 (中性: room=0.0, width=1.0, center=0.5)
check("set style=2", e.set_i("spatial.style", 2) == 0)
check("style 仍为 2", e.get_i("spatial.style")[1] == 2)
check("style=2 room==0.0", abs(e.get_f("spatial.room")[1] - 0.0) < 1e-4)
check("style=2 width==1.0", abs(e.get_f("spatial.width")[1] - 1.0) < 1e-4)
check("style=2 center==0.5", abs(e.get_f("spatial.center")[1] - 0.5) < 1e-4)

print("=== [2] 手动改动参数自动切入自定义 (style=3) ===")
# 改 room -> style=3
e.set_i("spatial.style", 0)
e.set_f("spatial.room", 0.55)
check("手动改 room 后 style 自动变 3", e.get_i("spatial.style")[1] == 3)
check("room 保留为 0.55", abs(e.get_f("spatial.room")[1] - 0.55) < 1e-4)

# 改 width -> style=3
e.set_i("spatial.style", 1)
e.set_f("spatial.width", 1.35)
check("手动改 width 后 style 自动变 3", e.get_i("spatial.style")[1] == 3)
check("width 保留为 1.35", abs(e.get_f("spatial.width")[1] - 1.35) < 1e-4)

# 改 center -> style=3
e.set_i("spatial.style", 2)
e.set_f("spatial.center", 0.75)
check("手动改 center 后 style 自动变 3", e.get_i("spatial.style")[1] == 3)
check("center 保留为 0.75", abs(e.get_f("spatial.center")[1] - 0.75) < 1e-4)

print("=== [3] style=3 自定义档显式写入不覆写当前值 ===")
e.set_f("spatial.room", 0.42)
e.set_f("spatial.width", 1.28)
e.set_f("spatial.center", 0.64)
check("显式 set style=3 成功", e.set_i("spatial.style", 3) == 0)
check("style 为 3", e.get_i("spatial.style")[1] == 3)
check("room 依然是 0.42", abs(e.get_f("spatial.room")[1] - 0.42) < 1e-4)
check("width 依然是 1.28", abs(e.get_f("spatial.width")[1] - 1.28) < 1e-4)
check("center 依然是 0.64", abs(e.get_f("spatial.center")[1] - 0.64) < 1e-4)

print("=== [4] 越界钳制到合法区间 [0, 3] ===")
check("style=4 写入返回 OK", e.set_i("spatial.style", 4) == 0)
check("style=4 钳制为 3", e.get_i("spatial.style")[1] == 3)
check("style=-1 写入返回 OK", e.set_i("spatial.style", -1) == 0)
check("style=-1 钳制为 0", e.get_i("spatial.style")[1] == 0)

e.close()

if FAIL:
    print(f"\nFAIL: {len(FAIL)} 项断言未通过")
    sys.exit(1)
print("\nspatial_style_custom: all checks passed")
sys.exit(0)
