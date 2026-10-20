import ctypes
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
PLUGIN = r"C:\Program Files\Common Files\VST3\FabFilter\FabFilter Pro-Q 4.vst3"

if not os.path.isfile(PLUGIN):
    print(f"[SKIP] Pro-Q 4 not installed: {PLUGIN}")
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
lib.auradsp_plugin_slot_load.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                         ctypes.c_char_p, ctypes.c_char_p]
lib.auradsp_plugin_slot_unload.restype = ctypes.c_int32
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int32]
lib.auradsp_plugin_slot_set_insert_stage.restype = ctypes.c_int32
lib.auradsp_plugin_slot_set_insert_stage.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                                    ctypes.c_int32]
lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int32
lib.auradsp_plugin_slot_get_status.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                               ctypes.c_char_p, ctypes.c_int32]

BLOCK = 512
STAGES = 5
h = lib.auradsp_create(48000.0, BLOCK)
if not h:
    print("[FAIL] auradsp_create")
    sys.exit(1)

try:
    if lib.auradsp_plugin_slot_load(h, 0, PLUGIN.encode("utf-8"), b"") != 1:
        print("[FAIL] Pro-Q 4 load")
        sys.exit(1)

    buf = ctypes.create_string_buffer(4096)
    previous_calls = 0
    for stage in range(STAGES):
        if lib.auradsp_plugin_slot_set_insert_stage(h, 0, stage) != 1:
            print(f"[FAIL] stage {stage} set")
            sys.exit(1)

        inp = (ctypes.c_float * (BLOCK * 2))()
        out = (ctypes.c_float * (BLOCK * 2))()
        for i in range(BLOCK):
            v = 0.25 * math.sin(2.0 * math.pi * 997.0 * i / 48000.0)
            inp[i * 2] = v
            inp[i * 2 + 1] = v
        for _ in range(3):
            lib.auradsp_process(h, inp, out, BLOCK)

        n = lib.auradsp_plugin_slot_get_status(h, 0, buf, len(buf))
        status = json.loads(buf.value[:n].decode("utf-8"))
        calls = status["processCalls"]
        print(f"stage={stage} calls={calls} outRms={status['outRms']:.6f} "
              f"frames={status['lastFrames']} latency={status['latency']}")
        if not status["hasActive"]:
            print(f"[FAIL] stage {stage}: plugin inactive")
            sys.exit(1)
        if status["insertStage"] != stage:
            print(f"[FAIL] stage {stage}: insertStage={status['insertStage']}")
            sys.exit(1)
        if calls <= previous_calls:
            print(f"[FAIL] stage {stage}: processCalls did not advance")
            sys.exit(1)
        if status["lastFrames"] != BLOCK:
            print(f"[FAIL] stage {stage}: lastFrames={status['lastFrames']}")
            sys.exit(1)
        if status["outRms"] <= 1e-6:
            print(f"[FAIL] stage {stage}: outRms={status['outRms']}")
            sys.exit(1)
        previous_calls = calls

    lib.auradsp_plugin_slot_unload(h, 0)
finally:
    lib.auradsp_destroy(h)

print("PASS  Pro-Q 4 telemetry on all five insert stages")
