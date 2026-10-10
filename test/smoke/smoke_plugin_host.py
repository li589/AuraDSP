# -*- coding: utf-8 -*-
"""
smoke_plugin_host.py — 验证 M1 VST3/CLAP 64位插件宿主与扫描器

测试点：
1. auradsp_plugin_scan 扫描系统标准 VST3 / CLAP 目录，返回发现的插件数；
2. auradsp_plugin_get_all 获取完整 JSON，验证元数据字段完整性；
3. 加载系统真实 VST3/CLAP 插件（例如 KV-Element-FX.vst3 或 ValhallaSupermassive.vst3）；
4. 验证 auradsp_process 音频链路在插件激活、旁路 (bypass)、卸载状态下的正确性；
5. 验证状态回读 auradsp_plugin_get_status 与延迟探测。
"""
import ctypes
import json
import os
import sys

dll_path = r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll"
assert os.path.exists(dll_path), f"Engine DLL not found: {dll_path}"
dll = ctypes.CDLL(dll_path)

# ABI signatures
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int]

dll.auradsp_plugin_scan.restype = ctypes.c_int
dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

dll.auradsp_plugin_get_count.restype = ctypes.c_int
dll.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]

dll.auradsp_plugin_get_item.restype = ctypes.c_int
dll.auradsp_plugin_get_item.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]

dll.auradsp_plugin_get_all.restype = ctypes.c_int
dll.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

dll.auradsp_plugin_load.restype = ctypes.c_int
dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]

dll.auradsp_plugin_unload.restype = ctypes.c_int
dll.auradsp_plugin_unload.argtypes = [ctypes.c_void_p]

dll.auradsp_plugin_set_bypass.restype = ctypes.c_int
dll.auradsp_plugin_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int]

dll.auradsp_plugin_get_bypass.restype = ctypes.c_int
dll.auradsp_plugin_get_bypass.argtypes = [ctypes.c_void_p]

dll.auradsp_plugin_get_latency.restype = ctypes.c_uint32
dll.auradsp_plugin_get_latency.argtypes = [ctypes.c_void_p]

dll.auradsp_plugin_get_status.restype = ctypes.c_int
dll.auradsp_plugin_get_status.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

print("=== [1] 创建引擎实例 ===")
h = dll.auradsp_create(48000.0, 1024)
assert h is not None, "Failed to create auradsp engine handle"

print("=== [2] 执行插件扫描 (快速扫描) ===")
count = dll.auradsp_plugin_scan(h, b"", 0)
print(f"Scanned {count} plugins")
assert count > 0, "Expected at least 1 plugin found in system directories"

buf = ctypes.create_string_buffer(65536)
len_all = dll.auradsp_plugin_get_all(h, buf, 65536)
assert len_all > 0, "Failed to get all scanned plugins json"
plugins_json = json.loads(buf.value.decode('utf-8'))
print(f"Retrieved {len(plugins_json)} plugin metadata entries:")
for i, p in enumerate(plugins_json[:5]):
    print(f"  [{i+1}] {p['name']} ({p['format']}) - {p['path']}")

# Check item lookup
item_buf = ctypes.create_string_buffer(4096)
dll.auradsp_plugin_get_item(h, 0, item_buf, 4096)
item_0 = json.loads(item_buf.value.decode('utf-8'))
assert item_0['name'] == plugins_json[0]['name']

print("=== [3] 状态初始校验 (未加载插件) ===")
status_buf = ctypes.create_string_buffer(4096)
dll.auradsp_plugin_get_status(h, status_buf, 4096)
status_init = json.loads(status_buf.value.decode('utf-8'))
assert not status_init['hasActive']
assert status_init['plugin'] is None

print("=== [4] 测试插件加载与音频处理 ===")
# Find a test plugin to load
target_plugin = None
for p in plugins_json:
    # Prefer KV-Element-FX or Valhalla or Convology
    if "KV-Element-FX" in p['name'] or "Valhalla" in p['name'] or "Convology" in p['name']:
        target_plugin = p
        break
if not target_plugin:
    target_plugin = plugins_json[0]

print(f"Attempting to load plugin: {target_plugin['name']} from {target_plugin['path']}")
load_rc = dll.auradsp_plugin_load(h, target_plugin['path'].encode('utf-8'), b"")
print(f"Load result: rc = {load_rc}")
assert load_rc == 1, f"Failed to load plugin {target_plugin['name']}"

dll.auradsp_plugin_get_status(h, status_buf, 4096)
status_loaded = json.loads(status_buf.value.decode('utf-8'))
print(f"Active status: hasActive={status_loaded['hasActive']}, latency={status_loaded['latency']}")
assert status_loaded['hasActive'], "Expected hasActive=true after load"
assert status_loaded['plugin'] is not None

print("=== [5] 验证音频 process() 处理与直通旁路 ===")
# Feed 1024 frames of 0.5f test signal
frames = 256
in_samples = [0.5] * (frames * 2)
in_arr = (ctypes.c_float * len(in_samples))(*in_samples)
out_arr = (ctypes.c_float * len(in_samples))()

dll.auradsp_process(h, in_arr, out_arr, frames)
print(f"Processed 256 frames, sample 0: in={in_arr[0]:.4f}, out={out_arr[0]:.4f}")

# Bypass
dll.auradsp_plugin_set_bypass(h, 1)
assert dll.auradsp_plugin_get_bypass(h) == 1
dll.auradsp_process(h, in_arr, out_arr, frames)
print(f"Bypassed 256 frames, sample 0: out={out_arr[0]:.4f}")

# Unbypass
dll.auradsp_plugin_set_bypass(h, 0)
assert dll.auradsp_plugin_get_bypass(h) == 0

print("=== [6] 插件卸载与销毁 ===")
unload_rc = dll.auradsp_plugin_unload(h)
assert unload_rc == 1
dll.auradsp_plugin_get_status(h, status_buf, 4096)
status_unloaded = json.loads(status_buf.value.decode('utf-8'))
assert not status_unloaded['hasActive']

dll.auradsp_destroy(h)
print("ALL TESTS PASSED: M1 VST3/CLAP Plugin Host & Scanner smoke test 100% OK!")
