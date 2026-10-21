"""smoke_plugin_bus.py — Phase 5 bus/multichannel expansion.

Verifies:
1. VST3 host enumerates main + auxiliary input buses (sidechain).
2. Auxiliary input buses are activated and fed silence while the main bus
   carries the real stereo signal (plugin still processes audio).
3. CLAP host enumerates all audio ports and allocates auxiliary port buffers.
4. Bus metadata survives the process-host IPC boundary.

Modes: inproc (default) and process (AURA_PLUGIN_HOST_MODE=process).
"""
import ctypes
import json
import math
import os
import sys

DLL_PATH = os.path.join(
    "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"
)
VST3_PATH = r"C:\Program Files\Common Files\VST3\Blue Cat Audio\BC PatchWork VST3.vst3"
CLAP_PATH = r"C:\Program Files\Common Files\CLAP\KV-Element-FX.clap"


def load_dll():
    dll = ctypes.CDLL(os.path.abspath(DLL_PATH))
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_scan.restype = ctypes.c_int
    dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    dll.auradsp_plugin_load.restype = ctypes.c_int
    dll.auradsp_plugin_unload.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_unload.restype = ctypes.c_int
    dll.auradsp_plugin_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_get_status.restype = ctypes.c_int
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    return dll


def get_status(dll, handle):
    buf = ctypes.create_string_buffer(16384)
    dll.auradsp_plugin_get_status(handle, buf, len(buf))
    try:
        return json.loads(buf.value.decode("utf-8"))
    except Exception:
        return {}


def process_blocks(dll, handle, frames=256, blocks=16):
    n = frames * 2
    tone = [0.25 * math.sin(2.0 * math.pi * 440.0 * i / 48000.0)
            for i in range(frames)]
    in_arr = (ctypes.c_float * n)(*(tone + tone))
    out_arr = (ctypes.c_float * n)()
    for _ in range(blocks):
        dll.auradsp_process(handle, in_arr, out_arr, frames)
    return list(out_arr)


def check_vst3(dll, handle):
    assert dll.auradsp_plugin_load(handle, VST3_PATH.encode("utf-8"), b"") == 1, \
        "BC PatchWork load failed"
    status = get_status(dll, handle)
    bus = status.get("busInfo") or {}
    print(f"  VST3 busInfo: {bus}")
    assert bus.get("inputs", 0) >= 2, "expected main + aux input buses"
    assert bus.get("outputs", 0) >= 1, "expected at least one output bus"
    assert bus.get("auxInputs", 0) >= 1, "expected an active auxiliary input bus"
    assert bus.get("mainInChannels") == 2, "main input bus should be stereo"
    assert bus.get("mainOutChannels") == 2, "main output bus should be stereo"

    out = process_blocks(dll, handle)
    assert all(v == v and abs(v) < 10.0 for v in out), "non-finite plugin output"
    peak = max(abs(v) for v in out)
    print(f"  VST3 processed peak = {peak:.6f}")
    assert peak > 1e-3, f"main bus audio did not reach output (peak={peak})"
    status = get_status(dll, handle)
    assert status.get("processCalls", 0) >= 16, "plugin process was not called"
    assert status.get("outRms", 0) > 0.01, "output RMS is silent"
    assert dll.auradsp_plugin_unload(handle) == 1


def check_clap(dll, handle):
    assert dll.auradsp_plugin_load(handle, CLAP_PATH.encode("utf-8"), b"") == 1, \
        "KV-Element-FX load failed"
    status = get_status(dll, handle)
    bus = status.get("busInfo") or {}
    print(f"  CLAP busInfo: {bus}")
    assert bus.get("inputs", 0) >= 2, "expected multiple CLAP input ports"
    assert bus.get("outputs", 0) >= 2, "expected multiple CLAP output ports"
    assert bus.get("auxInputs", 0) >= 1, "expected CLAP auxiliary input ports"
    assert bus.get("auxOutputs", 0) >= 1, "expected CLAP auxiliary output ports"
    assert bus.get("mainInChannels") == 2
    assert bus.get("mainOutChannels") == 2

    out = process_blocks(dll, handle, blocks=8)
    assert all(v == v and abs(v) < 10.0 for v in out), "non-finite CLAP output"
    status = get_status(dll, handle)
    assert status.get("processCalls", 0) >= 8, "CLAP process was not called"
    assert dll.auradsp_plugin_unload(handle) == 1


def main():
    mode = os.environ.get("AURA_PLUGIN_HOST_MODE", "inproc")
    print(f"=== smoke_plugin_bus ({mode} mode) ===")
    if not os.path.exists(VST3_PATH):
        print(f"[SKIP] VST3 bus test plugin not installed: {VST3_PATH}")
        return 0
    if not os.path.exists(DLL_PATH):
        print(f"[SKIP] engine DLL not found: {DLL_PATH}")
        return 0

    dll = load_dll()
    handle = dll.auradsp_create(48000.0, 1024)
    assert handle, "auradsp_create failed"
    try:
        assert dll.auradsp_plugin_scan(handle, b"", 0) > 0, "scan failed"
        check_vst3(dll, handle)
        if os.path.exists(CLAP_PATH):
            check_clap(dll, handle)
        else:
            print(f"  [SKIP] CLAP bus test plugin not installed: {CLAP_PATH}")
        dll.auradsp_destroy(handle)
        print("ALL TESTS PASSED: bus/multichannel smoke OK")
        return 0
    finally:
        pass


if __name__ == "__main__":
    sys.exit(main())
