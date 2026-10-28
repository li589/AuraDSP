# -*- coding: utf-8 -*-
"""smoke_plugin_channels.py -- per-slot channel mask + multichannel adaptation.

1. auradsp_plugin_slot_set/get_channels roundtrip.
2. Multichannel (4ch) process: selected pair is processed by a real plugin,
   unselected channels pass through bit-identical.
"""
import ctypes
import math
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
PLUGIN = r"C:\Program Files\Common Files\VST3\ConvologyXT_64.vst3"

if not os.path.isfile(PLUGIN):
    print(f"[SKIP] ConvologyXT_64 not installed: {PLUGIN}")
    sys.exit(0)
if not os.path.isfile(DLL):
    print(f"[FAIL] engine DLL missing: {DLL}")
    sys.exit(1)

lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
lib.auradsp_set_param.restype = ctypes.c_int
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_int]
lib.auradsp_plugin_slot_load.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                         ctypes.c_char_p, ctypes.c_char_p]
lib.auradsp_plugin_slot_unload.restype = ctypes.c_int32
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int32]
lib.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int32
lib.auradsp_plugin_slot_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                               ctypes.c_int32]
lib.auradsp_plugin_slot_set_channels.restype = ctypes.c_int32
lib.auradsp_plugin_slot_set_channels.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                                 ctypes.c_int32]
lib.auradsp_plugin_slot_get_channels.restype = ctypes.c_int32
lib.auradsp_plugin_slot_get_channels.argtypes = [ctypes.c_void_p, ctypes.c_int32]
lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int32
lib.auradsp_plugin_slot_get_status.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                               ctypes.c_char_p, ctypes.c_int32]

CH = 4
BLOCK = 256
BLOCKS = 20

def set_int(param, value):
    v = ctypes.c_int32(value)
    rc = lib.auradsp_set_param(h, param.encode(), ctypes.byref(v), 4)
    if rc != 0:
        print(f"[FAIL] set {param}={value} rc={rc}")
        sys.exit(1)

def load_status_json(slot):
    buf = ctypes.create_string_buffer(4096)
    lib.auradsp_plugin_slot_get_status(h, slot, buf, 4096)
    return buf.value.decode("utf-8")

h = lib.auradsp_create(48000.0, BLOCK)
if not h:
    print("[FAIL] auradsp_create")
    sys.exit(1)

try:
    if lib.auradsp_plugin_slot_get_channels(h, 0) != 0xFF:
        print("[FAIL] default channels mask != 0xFF")
        sys.exit(1)
    if lib.auradsp_plugin_slot_set_channels(h, 0, 0x03) != 1:
        print("[FAIL] set_channels(0x03)")
        sys.exit(1)
    if lib.auradsp_plugin_slot_get_channels(h, 0) != 0x03:
        print("[FAIL] get_channels != 0x03")
        sys.exit(1)

    if lib.auradsp_plugin_slot_load(h, 0, PLUGIN.encode("utf-8"), b"") != 1:
        print("[FAIL] ConvologyXT load")
        sys.exit(1)
    # P-041 挂载即旁路：显式解旁路（旁路槽不进路径，声道处理测不到）。
    assert lib.auradsp_plugin_slot_set_bypass(h, 0, 0) == 1

    status = load_status_json(0)
    if '"channels":3' not in status:
        print(f"[FAIL] status json missing channels=3: {status[:200]}")
        sys.exit(1)

    set_int("channels.count", CH)
    set_int("channels.mode", 1)
    set_int("limiter.enable", 0)

    inp = (ctypes.c_float * (BLOCK * CH))()
    for i in range(BLOCK):
        inp[i * CH + 0] = 0.25 * math.sin(2.0 * math.pi * 331.0 * i / 48000.0)
        inp[i * CH + 1] = 0.25 * math.cos(2.0 * math.pi * 553.0 * i / 48000.0)
        inp[i * CH + 2] = 0.125 * math.sin(2.0 * math.pi * 997.0 * i / 48000.0)
        inp[i * CH + 3] = 0.125 * math.cos(2.0 * math.pi * 1327.0 * i / 48000.0)

    out = (ctypes.c_float * (BLOCK * CH))()
    for _ in range(BLOCKS):
        lib.auradsp_process(h, inp, out, BLOCK)
        time.sleep(0.005)

    h2 = lib.auradsp_create(48000.0, BLOCK)
    if not h2:
        print("[FAIL] auradsp_create (control handle)")
        sys.exit(1)
    set_int2 = None
    try:
        set_int_param = ctypes.c_int32(CH)
        if lib.auradsp_set_param(h2, b"channels.count", ctypes.byref(set_int_param), 4) != 0:
            print("[FAIL] control handle channels.count")
            sys.exit(1)
        set_mode_param = ctypes.c_int32(1)
        if lib.auradsp_set_param(h2, b"channels.mode", ctypes.byref(set_mode_param), 4) != 0:
            print("[FAIL] control handle channels.mode")
            sys.exit(1)
        set_lim_param = ctypes.c_int32(0)
        if lib.auradsp_set_param(h2, b"limiter.enable", ctypes.byref(set_lim_param), 4) != 0:
            print("[FAIL] control handle limiter.enable")
            sys.exit(1)
        out2 = (ctypes.c_float * (BLOCK * CH))()
        for _ in range(BLOCKS):
            lib.auradsp_process(h2, inp, out2, BLOCK)
            time.sleep(0.005)

        selected_changed = False
        passed = True
        worst = 0.0
        for i in range(BLOCK):
            if abs(out[i * CH + 0] - out2[i * CH + 0]) > 1e-4:
                selected_changed = True
            for c in (2, 3):
                d = abs(out[i * CH + c] - out2[i * CH + c])
                if d > worst:
                    worst = d
                if d > 1e-7:
                    passed = False
        print(f"debug worst unselected diff vs control = {worst:.6g}")

        if not selected_changed:
            print("[FAIL] selected pair was not processed (plugin made no change)")
            sys.exit(1)
        if not passed:
            print("[FAIL] unselected channels did not match control (pass-through)")
            sys.exit(1)

        print("PASS  plugin slot channels: mask roundtrip + 4ch select/pass-through")
    finally:
        lib.auradsp_destroy(h2)
finally:
    lib.auradsp_plugin_slot_unload(h, 0)
    lib.auradsp_destroy(h)
