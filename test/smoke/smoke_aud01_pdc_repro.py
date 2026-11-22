#!/usr/bin/env python3
"""smoke_aud01_pdc_repro.py — AUD-01 动态复现（2026-11-23）。

AUD-01（已修 f8dd5196）：进程外插件 loadPreset 后 PDC 延迟记账
错位——旧实现只写 m_latency = 新延迟 + 1×传输块、不更新插件
延迟分量：多块回调下少报传输部分，块数变化时又被旧插件延迟
重算覆盖。修复前证据只有静态核对，本冒烟补动态判别：

夹具 auradsp_test_latency.clap（engine/plugins/tests）出厂延迟
100 帧，state（预设文件 = 4 字节 LE uint32）可改写为任意值并
经 CLAP latency-changed 通知宿主。以 process 模式加载后：

  1. 未处理时上报 = 100 + 128（首块前保守口径 N=1）；
  2. 以 384 帧回调处理后 = 100 + 384（N=3 块重算）；
  3. loadPreset(250) 后 = 250 + 384 = 634
     （旧实现：250 + 128 = 378 —— 少报 2 个传输块）；
  4. 再以 128 帧回调处理 = 250 + 128 = 378
     （旧实现：用陈旧插件延迟 100 重算 = 228）。

夹具或引擎产物缺失时自 SKIP（仓库通例）。
"""
import ctypes
import os
import struct
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE_DLL = os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
FIXTURE = os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release",
    "auradsp_test_latency.clap")

FAILURES = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILURES.append(msg)


def main():
    if sys.platform != "win32":
        print("SKIP (windows only)")
        return 0
    if not os.path.exists(ENGINE_DLL) or not os.path.exists(FIXTURE):
        print("SKIP (engine/fixture artifact missing)")
        return 0
    os.environ["AURA_PLUGIN_HOST_MODE"] = "process"

    dll = ctypes.CDLL(ENGINE_DLL)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.c_int]
    dll.auradsp_plugin_scan.restype = ctypes.c_int
    dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.c_char_p]
    dll.auradsp_plugin_load.restype = ctypes.c_int
    dll.auradsp_plugin_unload.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_unload.restype = ctypes.c_int
    dll.auradsp_plugin_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int]
    dll.auradsp_plugin_set_bypass.restype = ctypes.c_int
    dll.auradsp_plugin_get_latency.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_latency.restype = ctypes.c_uint32
    dll.auradsp_plugin_slot_load_preset.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
    dll.auradsp_plugin_slot_load_preset.restype = ctypes.c_int

    handle = dll.auradsp_create(48000.0, 1024)
    check(handle is not None, "auradsp_create")
    if not handle:
        return 1
    try:
        fixture_dir = os.path.dirname(FIXTURE)
        dll.auradsp_plugin_scan(handle, fixture_dir.encode("utf-8"), 0)
        rc = dll.auradsp_plugin_load(handle, FIXTURE.encode("utf-8"), b"")
        check(rc == 1, f"fixture loads in process mode (rc={rc})")
        if rc != 1:
            return 1
        check(dll.auradsp_plugin_set_bypass(handle, 0) == 1, "un-bypass slot")
        time.sleep(0.1)

        lat = dll.auradsp_plugin_get_latency(handle)
        check(lat == 100 + 128, f"initial latency 228 (got {lat})")

        def run_blocks(frames, count=6):
            in_arr = (ctypes.c_float * (frames * 2))(*([0.25] * (frames * 2)))
            out_arr = (ctypes.c_float * (frames * 2))()
            for _ in range(count):
                dll.auradsp_process(handle, in_arr, out_arr, frames)
            time.sleep(0.1)

        run_blocks(384)
        lat = dll.auradsp_plugin_get_latency(handle)
        check(lat == 100 + 384,
              f"384-frame callbacks: latency 484 (got {lat})")

        preset = os.path.join(tempfile.gettempdir(),
                              "aud01_preset_250.clapstate")
        with open(preset, "wb") as f:
            f.write(struct.pack("<I", 250))
        rc = dll.auradsp_plugin_slot_load_preset(
            handle, 0, preset.encode("utf-8"))
        check(rc == 1, f"slot_load_preset rc={rc}")
        time.sleep(0.1)
        lat = dll.auradsp_plugin_get_latency(handle)
        check(lat == 250 + 384,
              f"after preset: latency 634 = 250 + 3x128 (got {lat}; "
              "378 would be the AUD-01 bug)")

        run_blocks(128)
        lat = dll.auradsp_plugin_get_latency(handle)
        check(lat == 250 + 128,
              f"128-frame callbacks after preset: latency 378 (got {lat}; "
              "228 would mean a stale plugin-latency component)")

        check(dll.auradsp_plugin_unload(handle) == 1, "unload")
    finally:
        dll.auradsp_destroy(handle)

    if FAILURES:
        print(f"smoke_aud01_pdc_repro: FAIL ({len(FAILURES)})")
        return 1
    print("smoke_aud01_pdc_repro: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
