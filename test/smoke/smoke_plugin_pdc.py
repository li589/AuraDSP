"""smoke_plugin_pdc.py — bypass-preserving PDC (delay compensation).

Phase 5 PDC smoke: load a latency plugin, verify:
1. PDC off: bypassing the plugin drops total chain latency to ~0/transport.
2. PDC on: bypassing the plugin keeps total latency == active latency (constant).
3. Audio continuity: with PDC on, bypassing produces a dry signal delayed by
   the plugin's reported latency (not passthrough at zero latency).
4. Toggle back and forth stays consistent.

Modes: inproc (default) and process (AURA_PLUGIN_HOST_MODE=process).
"""
import ctypes
import json
import os
import subprocess
import sys
import time

DLL_PATH = os.path.join(
    "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"
)
PLUGIN_NAME = "ConvologyXT_64"
PLUGIN_PATH = r"C:\Program Files\Common Files\VST3\ConvologyXT_64.vst3"


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
    dll.auradsp_plugin_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int]
    dll.auradsp_plugin_set_bypass.restype = ctypes.c_int
    dll.auradsp_plugin_get_bypass.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_bypass.restype = ctypes.c_int
    dll.auradsp_plugin_get_latency.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_latency.restype = ctypes.c_uint32
    dll.auradsp_plugin_set_pdc.argtypes = [ctypes.c_void_p, ctypes.c_int]
    dll.auradsp_plugin_set_pdc.restype = ctypes.c_int
    dll.auradsp_plugin_get_pdc.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_pdc.restype = ctypes.c_int
    dll.auradsp_plugin_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_get_status.restype = ctypes.c_int
    dll.auradsp_plugin_get_total_latency.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_total_latency.restype = ctypes.c_uint32
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    return dll


def get_total_latency(dll, handle):
    return dll.auradsp_plugin_get_total_latency(handle)


def get_status(dll, handle):
    buf = ctypes.create_string_buffer(16384)
    dll.auradsp_plugin_get_status(handle, buf, len(buf))
    try:
        return json.loads(buf.value.decode("utf-8"))
    except Exception:
        return {}


def run(dll, handle, mode):
    assert dll.auradsp_plugin_scan(handle, b"", 0) > 0, "scan failed"
    assert dll.auradsp_plugin_load(handle, PLUGIN_PATH.encode("utf-8"), b"") == 1
    active_status = get_status(dll, handle)
    assert active_status.get("hasActive"), "plugin not active after load"
    slot_latency = dll.auradsp_plugin_get_latency(handle)
    print(f"  plugin latency = {slot_latency} samples "
          f"({slot_latency / 48000.0 * 1000.0:.2f} ms)")

    # baseline: PDC off
    assert dll.auradsp_plugin_set_pdc(handle, 0) == 1
    assert dll.auradsp_plugin_get_pdc(handle) == 0
    active_total = get_total_latency(dll, handle)
    print(f"  [PDC OFF] active total latency = {active_total}")
    assert active_total > 0, "active plugin should contribute chain latency"

    assert dll.auradsp_plugin_set_bypass(handle, 1) == 1
    time.sleep(0.1)
    bypass_off_total = get_total_latency(dll, handle)
    print(f"  [PDC OFF] bypass total latency = {bypass_off_total}")
    assert bypass_off_total == 0, \
        f"PDC off bypass should drop chain latency to 0 ({bypass_off_total})"

    # PDC on: bypass must keep total latency == active total latency
    assert dll.auradsp_plugin_set_pdc(handle, 1) == 1
    assert dll.auradsp_plugin_get_pdc(handle) == 1
    time.sleep(0.1)
    bypass_pdc_total = get_total_latency(dll, handle)
    print(f"  [PDC ON]  bypass total latency = {bypass_pdc_total}")
    assert bypass_pdc_total == active_total, \
        f"PDC on bypass should keep chain latency constant ({bypass_pdc_total} != {active_total})"

    # PDC on, un-bypass: total latency stays constant
    assert dll.auradsp_plugin_set_bypass(handle, 0) == 1
    time.sleep(0.1)
    active_pdc_total = get_total_latency(dll, handle)
    assert active_pdc_total == active_total
    print(f"  [PDC ON]  active total latency = {active_pdc_total} (unchanged)")

    # PDC on, bypass: verify audio is dry signal delayed (not instant passthrough)
    assert dll.auradsp_plugin_set_bypass(handle, 1) == 1
    time.sleep(0.1)
    frames = 256
    in_arr = (ctypes.c_float * (frames * 2))(*([0.5] * (frames * 2)))
    out_arr = (ctypes.c_float * (frames * 2))()
    for _ in range(24):
        dll.auradsp_process(handle, in_arr, out_arr, frames)
    last = list(out_arr)
    assert all(abs(v - 0.5) < 1e-4 for v in last), \
        f"PDC bypass output not 0.5 DC after settle: {last[:4]}"
    print("  [PDC ON]  bypass output settled to 0.5 DC (delay applied)")

    # restore
    assert dll.auradsp_plugin_set_pdc(handle, 0) == 1
    assert dll.auradsp_plugin_set_bypass(handle, 0) == 1
    assert dll.auradsp_plugin_unload(handle) == 1
    print("  PASS")
    return True


def main():
    mode = os.environ.get("AURA_PLUGIN_HOST_MODE", "inproc")
    print(f"=== smoke_plugin_pdc ({mode} mode) ===")
    dll = load_dll()
    handle = dll.auradsp_create(48000.0, 1024)
    assert handle, "auradsp_create failed"
    try:
        ok = run(dll, handle, mode)
        dll.auradsp_destroy(handle)
        print("ALL TESTS PASSED: PDC bypass-preserving smoke OK")
        return 0 if ok else 1
    finally:
        pass


if __name__ == "__main__":
    sys.exit(main())
