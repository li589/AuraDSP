"""probe_plugin_load_all.py — 逐个加载所有扫描到的插件（进程模式），
报告每个插件的 load/process/unload 结果，按厂商分组汇总失败项。

用途：验证 Phase 4 进程隔离对多厂商插件的兼容性，确认失败仅局限于个别插件/厂商。
"""
import ctypes
import json
import os
import sys
import time

DLL_PATH = os.path.join(
    "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"
)


def load_dll():
    dll = ctypes.CDLL(os.path.abspath(DLL_PATH))
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_scan.restype = ctypes.c_int
    dll.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_count.restype = ctypes.c_int
    dll.auradsp_plugin_get_item.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int
    ]
    dll.auradsp_plugin_get_item.restype = ctypes.c_int
    dll.auradsp_plugin_load.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p
    ]
    dll.auradsp_plugin_load.restype = ctypes.c_int
    dll.auradsp_plugin_unload.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_unload.restype = ctypes.c_int
    dll.auradsp_plugin_get_latency.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_latency.restype = ctypes.c_uint32
    dll.auradsp_plugin_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int
    ]
    dll.auradsp_plugin_get_status.restype = ctypes.c_int
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int,
    ]
    return dll


def get_status(dll, handle):
    buf = ctypes.create_string_buffer(16384)
    dll.auradsp_plugin_get_status(handle, buf, len(buf))
    try:
        return json.loads(buf.value.decode("utf-8"))
    except Exception:
        return {}


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "AURA_PLUGIN_HOST_MODE", "inproc")
    os.environ["AURA_PLUGIN_HOST_MODE"] = mode
    print(f"mode={mode}")
    dll = load_dll()
    handle = dll.auradsp_create(48000.0, 1024)
    assert handle, "auradsp_create failed"

    count = dll.auradsp_plugin_scan(handle, b"", 0)
    print(f"scanned plugins: {count}\n")

    items = []
    for i in range(count):
        buf = ctypes.create_string_buffer(32768)
        if dll.auradsp_plugin_get_item(handle, i, buf, len(buf)) <= 0:
            continue
        try:
            items.append(json.loads(buf.value.decode("utf-8")))
        except Exception:
            continue

    frames = 256
    in_arr = (ctypes.c_float * (frames * 2))(*([0.5] * (frames * 2)))
    out_arr = (ctypes.c_float * (frames * 2))()

    results = []
    for idx, item in enumerate(items):
        name = item.get("name", "?")
        vendor = item.get("vendor", "(unknown)")
        fmt = item.get("format", "?")
        path = item.get("path", "")
        arch = item.get("isCompatible", True)

        t0 = time.time()
        rc = dll.auradsp_plugin_load(handle, path.encode("utf-8"), b"")
        load_ms = (time.time() - t0) * 1000.0

        status = get_status(dll, handle)
        active = bool(status.get("hasActive"))
        latency = dll.auradsp_plugin_get_latency(handle)

        # process a few blocks
        proc_ok = False
        if active:
            for _ in range(8):
                dll.auradsp_process(handle, in_arr, out_arr, frames)
                time.sleep(0.002)
            last = list(out_arr)
            proc_ok = any(abs(v) < 1000.0 for v in last)

        unload_rc = dll.auradsp_plugin_unload(handle)
        time.sleep(0.05)

        ok = bool(rc == 1 and active and (not active or proc_ok))
        results.append({
            "idx": idx,
            "name": name,
            "vendor": vendor,
            "format": fmt,
            "arch_ok": arch,
            "load_rc": rc,
            "active": active,
            "latency": latency,
            "load_ms": load_ms,
            "unload_rc": unload_rc,
            "ok": ok,
        })
        flag = "OK " if ok else "FAIL"
        print(f"[{flag}] {vendor} / {name} ({fmt}) "
              f"load_rc={rc} active={active} lat={latency} "
              f"{load_ms:.0f}ms unload={unload_rc}")

    dll.auradsp_destroy(handle)

    # summary by vendor
    by_vendor = {}
    for r in results:
        by_vendor.setdefault(r["vendor"], []).append(r)
    print("\n=== by vendor ===")
    fails = 0
    for vendor in sorted(by_vendor):
        rs = by_vendor[vendor]
        f = sum(1 for r in rs if not r["ok"])
        fails += f
        names_fail = [r["name"] for r in rs if not r["ok"]]
        suffix = f"  FAIL: {names_fail}" if names_fail else ""
        print(f"  {vendor}: {len(rs)} total, {f} fail{suffix}")

    total = len(results)
    print(f"\nTOTAL {total} plugins, {fails} failed")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
