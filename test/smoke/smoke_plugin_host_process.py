# -*- coding: utf-8 -*-
"""smoke_plugin_host_process.py — Phase 4 out-of-process host smoke test.

Verifies:
1. AURA_PLUGIN_HOST_MODE=process launches auradsp_plugin_host.exe as a child.
2. Remote scan/load/process works and reports >= 128 frames transport latency.
3. taskkill /F of the host does not kill the engine and audio falls back to bypass.
4. Reload after host crash relaunches the host and restores processing.
5. Engine destroy also terminates the host process.
"""
import ctypes
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
PLUGIN_NAME = "Convology"
TARGET = None

os.environ["AURA_PLUGIN_HOST_MODE"] = "process"

dll = ctypes.CDLL(DLL_PATH)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_plugin_scan.restype = ctypes.c_int
dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
dll.auradsp_plugin_get_count.restype = ctypes.c_int
dll.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
dll.auradsp_plugin_get_item.restype = ctypes.c_int
dll.auradsp_plugin_get_item.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
dll.auradsp_plugin_load.restype = ctypes.c_int
dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
dll.auradsp_plugin_unload.restype = ctypes.c_int
dll.auradsp_plugin_unload.argtypes = [ctypes.c_void_p]
dll.auradsp_plugin_get_status.restype = ctypes.c_int
dll.auradsp_plugin_get_status.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
dll.auradsp_plugin_get_latency.restype = ctypes.c_uint32
dll.auradsp_plugin_get_latency.argtypes = [ctypes.c_void_p]
dll.auradsp_plugin_slot_load_async.restype = ctypes.c_int
dll.auradsp_plugin_slot_load_async.argtypes = [
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p]
dll.auradsp_plugin_slot_task_state.restype = ctypes.c_int
dll.auradsp_plugin_slot_task_state.argtypes = [ctypes.c_void_p, ctypes.c_int]


def hosts_for_parent(parent_pid):
    script = ("Get-CimInstance Win32_Process -Filter \"Name='auradsp_plugin_host.exe'\" | "
              "Select-Object ProcessId,ParentProcessId | ConvertTo-Json -Compress")
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                            capture_output=True, text=True, timeout=20)
    text = result.stdout.strip()
    if not text:
        return []
    data = json.loads(text)
    if isinstance(data, dict):
        data = [data]
    return [int(x["ProcessId"]) for x in data if int(x.get("ParentProcessId", 0)) == parent_pid]


def process_blocks(handle, frames, blocks, pace_s=0.005):
    samples = [0.5] * (frames * 2)
    in_arr = (ctypes.c_float * len(samples))(*samples)
    out_arr = (ctypes.c_float * len(samples))()
    last = None
    for _ in range(blocks):
        dll.auradsp_process(handle, in_arr, out_arr, frames)
        last = list(out_arr)
        if pace_s:
            time.sleep(pace_s)
    return last


def wait_for_processed(handle, timeout=5.0):
    deadline = time.time() + timeout
    out = []
    while time.time() < deadline:
        out = process_blocks(handle, 256, 16)
        if max(abs(v - 0.5) for v in out) > 1e-3:
            return out
    return out


def get_status(handle):
    buf = ctypes.create_string_buffer(8192)
    dll.auradsp_plugin_get_status(handle, buf, len(buf))
    return json.loads(buf.value.decode("utf-8"))


print("=== [1] create engine (process mode) ===")
handle = dll.auradsp_create(48000.0, 1024)
assert handle, "auradsp_create failed"
assert not hosts_for_parent(os.getpid()), "engine create eagerly spawned a host"

print("=== [2] remote scan ===")
count = dll.auradsp_plugin_scan(handle, b"", 0)
assert count > 0, "remote scan returned no plugins"
print(f"remote scanned plugins: {count}")

buf = ctypes.create_string_buffer(4096)
for i in range(count):
    dll.auradsp_plugin_get_item(handle, i, buf, len(buf))
    item = json.loads(buf.value.decode("utf-8"))
    if PLUGIN_NAME in item.get("name", ""):
        TARGET = item
        break
assert TARGET, f"test plugin containing {PLUGIN_NAME!r} not found"

print(f"=== [3] remote load {TARGET['name']} ===")
assert dll.auradsp_plugin_load(handle, TARGET["path"].encode("utf-8"), b"") == 1
status = get_status(handle)
assert status["hasActive"] and status["plugin"] is not None
assert status.get("remoteMode") is True, f"expected remoteMode, got {status}"
latency = dll.auradsp_plugin_get_latency(handle)
assert latency >= 128, f"transport latency missing: {latency}"
assert status.get("transportLatency") == 128, f"unexpected transport latency: {status}"
assert 128 / 48000.0 * 1000.0 < 5.0, "transport latency exceeds 5 ms"
print(f"remote active, latency={latency} frames (transport 128 = "
      f"{128 / 48000.0 * 1000.0:.2f} ms)")

print("=== [4] remote processing differs from input ===")
out = wait_for_processed(handle)
assert not any(abs(v) == 777.0 for v in out)
assert max(abs(v - 0.5) for v in out) > 1e-3, "remote plugin returned passthrough"

print("=== [4b] replacing a loaded remote plugin keeps processing ===")
assert dll.auradsp_plugin_load(handle, TARGET["path"].encode("utf-8"), b"") == 1
out = wait_for_processed(handle)
assert max(abs(v - 0.5) for v in out) > 1e-3, "plugin replacement lost processing"

print("=== [4c] async replacement over a loaded remote slot ===")
assert dll.auradsp_plugin_slot_load_async(
    handle, 0, TARGET["path"].encode("utf-8"), b"") == 1
deadline = time.time() + 10.0
state = 1
while state == 1 and time.time() < deadline:
    time.sleep(0.05)
    state = dll.auradsp_plugin_slot_task_state(handle, 0)
assert state == 2, f"async replacement failed, task_state={state}"
out = wait_for_processed(handle)
assert max(abs(v - 0.5) for v in out) > 1e-3, "async replacement lost processing"

print("=== [5] host process exists as child ===")
hosts = hosts_for_parent(os.getpid())
assert hosts, "auradsp_plugin_host.exe child not found"
host_pid = hosts[0]
print(f"host pid: {host_pid}")

print("=== [6] kill host; engine must survive and bypass ===")
subprocess.run(["taskkill", "/F", "/PID", str(host_pid)],
               capture_output=True, text=True, timeout=20)
time.sleep(0.1)
out = process_blocks(handle, 256, 80)
assert len(out) == 512
assert all(abs(v) < 10.0 for v in out), "engine output corrupted after host kill"
status = get_status(handle)
assert status.get("remoteMode") is True
assert status.get("remoteFailed") is True, f"host crash not reported: {status}"
assert status.get("bypassed") is True, f"host crash not auto-bypassed: {status}"
print("engine survived; host crash reported and bypassed")

print("=== [7] reload relaunches host and restores processing ===")
assert dll.auradsp_plugin_unload(handle) == 1
assert dll.auradsp_plugin_load(handle, TARGET["path"].encode("utf-8"), b"") == 1
out = wait_for_processed(handle)
assert max(abs(v - 0.5) for v in out) > 1e-3, "reloaded remote plugin returned passthrough"
status = get_status(handle)
assert status.get("remoteMode") is True and status.get("remoteFailed") is False
hosts = hosts_for_parent(os.getpid())
assert hosts, "host was not relaunched after reload"
print(f"reload restored processing; new host pid: {hosts[0]}")

print("=== [8] destroy engine and reap host ===")
dll.auradsp_destroy(handle)
time.sleep(1.0)
assert not hosts_for_parent(os.getpid()), "host process survived engine destroy"

print("ALL TESTS PASSED: out-of-process plugin host smoke test OK")
