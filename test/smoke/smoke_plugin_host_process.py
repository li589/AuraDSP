# -*- coding: utf-8 -*-
"""smoke_plugin_host_process.py — Phase 4 out-of-process host smoke test.

Verifies:
1. AURA_PLUGIN_HOST_MODE=process launches auradsp_plugin_host.exe as a child.
2. Remote scan/load/process works and reports >= 128 frames transport latency.
3. taskkill /F of the host does not kill the engine and audio falls back to bypass.
4. Reload after host crash relaunches the host and restores processing.
5. Engine destroy also terminates the host process.
6. Layout integrity: a position-coded ramp vector (ch0 up / ch1 down) must
   survive the proxy scratch boundary as a dense signal — any channel/frame
   permutation there shows up as a sparse (mostly-zero) output.

NOTE on test strength: a constant signal (e.g. 0.5) is invariant under any
sample permutation, so "output != input" probes cannot detect layout bugs at
the proxy boundary. Sections [4]/[4b]/[4c]/[7] are liveness probes only;
section [4a] is the correctness gate.
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
    # errors="replace": taskkill/PowerShell emit locale-encoded (cp936) text on
    # Chinese Windows; the reader thread must not die on undecodable bytes.
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                            capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=20)
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


def ramp_input(frames, block_index, total_blocks):
    """Position-coded stereo ramp: ch0 climbs 0.1 -> 0.9, ch1 falls -0.1 -> -0.9.

    Every sample's value encodes its (frame, channel) position, so any
    permutation of frames or channels at the proxy scratch boundary destroys
    the dense ramp structure and leaves a sparse, mostly-zero output.
    """
    samples = [0.0] * (frames * 2)
    for i in range(frames):
        t = (block_index * frames + i) / float(total_blocks * frames)
        samples[i * 2 + 0] = 0.1 + 0.8 * t   # ch0: upward ramp
        samples[i * 2 + 1] = -0.1 - 0.8 * t  # ch1: downward ramp
    return samples


def process_ramp_blocks(handle, frames, blocks, pace_s=0.005):
    in_arr = (ctypes.c_float * (frames * 2))()
    out_arr = (ctypes.c_float * (frames * 2))()
    last_in = None
    last = None
    for b in range(blocks):
        samples = ramp_input(frames, b, blocks)
        for i, v in enumerate(samples):
            in_arr[i] = v
        dll.auradsp_process(handle, in_arr, out_arr, frames)
        last_in = samples
        last = list(out_arr)
        if pace_s:
            time.sleep(pace_s)
    return last, last_in


def wait_for_ramp_processed(handle, timeout=5.0):
    """Gate: wait until remote output is no longer bit-exact passthrough.

    During transport warm-up the proxy passes input through unchanged, so a
    dense ramp would trivially satisfy the density check even while broken.
    A ramp (not a constant) is used because a constant's steady state can
    legitimately equal the input (e.g. a unity-DC reverb IR), which would
    leave a constant-based gate closed forever on a healthy pipeline.
    """
    deadline = time.time() + timeout
    out, src = process_ramp_blocks(handle, 256, 4)
    while time.time() < deadline:
        if max(abs(a - b) for a, b in zip(out, src)) > 1e-3:
            return out, src
        out, src = process_ramp_blocks(handle, 256, 4)
    return out, src


def assert_processing(out, src, label):
    """Assert the plugin actually transforms the ramp (not passthrough)."""
    maxdiff = max(abs(a - b) for a, b in zip(out, src))
    assert maxdiff > 1e-3, (
        f"{label}: plugin returned bit-exact passthrough "
        f"(max|out-in|={maxdiff:.6f})")
    return maxdiff


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

print("=== [4] remote processing transforms the input ===")
out, src = wait_for_ramp_processed(handle)
assert not any(abs(v) == 777.0 for v in out)
assert_processing(out, src, "[4] remote processing")

print("=== [4a] layout integrity: ramp vector must stay dense across the proxy boundary ===")
out, src = process_ramp_blocks(handle, 256, 12)
assert not any(abs(v) == 777.0 for v in out)
assert_processing(out, src, "[4a] settled ramp")
nz = sum(1 for v in out if abs(v) > 1e-5)
nz_ratio = nz / len(out)
ch0 = out[0::2]
ch1 = out[1::2]
print(f"  non-zero density: {nz_ratio:.1%} ({nz}/{len(out)}); "
      f"mean(ch0)={sum(ch0) / len(ch0):+.4f} mean(ch1)={sum(ch1) / len(ch1):+.4f}")
assert nz_ratio > 0.7, (
    f"output is sparse ({nz_ratio:.1%} non-zero) — frames/channels are being "
    "permuted at the proxy scratch boundary (a dense ramp through any "
    "non-silent plugin must produce a dense signal)")
# F-4: healthy steady state must show zero seq gaps (output blocks lost
# upstream are counted via the host-echoed seq; a nonzero value here means
# the transport silently dropped blocks).
status = get_status(handle)
gaps = status.get("seqGaps")
assert gaps == 0, (
    f"seq gaps in healthy steady state: {gaps} — blocks are being lost in "
    "the transport without a parameter change")
print(f"  transport clean: seqGaps={gaps}, "
      f"inputOverflows={status.get('inputOverflows')}, "
      f"outputOverflows={status.get('outputOverflows')}")

print("=== [4b] replacing a loaded remote plugin keeps processing ===")
assert dll.auradsp_plugin_load(handle, TARGET["path"].encode("utf-8"), b"") == 1
out, src = wait_for_ramp_processed(handle)
assert_processing(out, src, "[4b] plugin replacement")

print("=== [4c] async replacement over a loaded remote slot ===")
assert dll.auradsp_plugin_slot_load_async(
    handle, 0, TARGET["path"].encode("utf-8"), b"") == 1
deadline = time.time() + 10.0
state = 1
while state == 1 and time.time() < deadline:
    time.sleep(0.05)
    state = dll.auradsp_plugin_slot_task_state(handle, 0)
assert state == 2, f"async replacement failed, task_state={state}"
out, src = wait_for_ramp_processed(handle)
assert_processing(out, src, "[4c] async replacement")

print("=== [5] host process exists as child ===")
hosts = hosts_for_parent(os.getpid())
assert hosts, "auradsp_plugin_host.exe child not found"
host_pid = hosts[0]
print(f"host pid: {host_pid}")

print("=== [6] kill host; engine must survive and bypass ===")
subprocess.run(["taskkill", "/F", "/PID", str(host_pid)],
               capture_output=True, text=True,
               encoding="utf-8", errors="replace", timeout=20)
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
out, src = wait_for_ramp_processed(handle)
assert_processing(out, src, "[7] reloaded remote plugin")
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
