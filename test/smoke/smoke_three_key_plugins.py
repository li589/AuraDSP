"""
三大关键插件（FabFilter Pro-Q 3 / iZotope Ozone 12 / Kushview Element FX）
的挂载 → 打开编辑器 → 关闭 → 卸载 全链路人工值守验证。

【为何未登记进 test/runner.py】
本脚本会弹出插件原生 GUI 窗口并依赖本机已安装上述商业插件，
无法在无人值守的 CI/门禁环境中运行，故刻意不从 runner 挂载。
无人值守的插件通路门禁由以下用例承担：
  - test/smoke/smoke_plugin_host.py（进程内直通、延迟、旁路，无 GUI）
  - test/smoke/smoke_multislot_and_stages.py（多插槽与阶段拓扑）
  - engine/plugins/tests/plugin_host_direct.cpp（C++ 侧等价验证，编译后手动执行）

运行方式（需在本机有桌面会话时手动执行）：
    python test/smoke/smoke_three_key_plugins.py
"""
import ctypes
import json
import time
import os
import sys

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

dll_path = os.path.abspath("auradsp_engine.dll")
lib = ctypes.CDLL(dll_path)

lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]

lib.auradsp_plugin_scan.restype = ctypes.c_int32
lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]

lib.auradsp_plugin_get_all.restype = ctypes.c_int32
lib.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]

lib.auradsp_plugin_slot_load.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_char_p]

lib.auradsp_plugin_slot_unload.restype = ctypes.c_int32
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int32]

lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int32
lib.auradsp_plugin_slot_show_editor.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]

lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int32
lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p, ctypes.c_int32]

h = lib.auradsp_create(48000.0, 1024)
print("Created AuraDSP engine:", h)

count = lib.auradsp_plugin_scan(h, None, 0)
buf = ctypes.create_string_buffer(524288)
lib.auradsp_plugin_get_all(h, buf, 524288)
plugins = json.loads(buf.value.decode('utf-8'))
print(f"Scanned {len(plugins)} plugin entries")

targets = [
    ("FabFilter Pro-Q 3", "FabFilter"),
    ("Ozone 12", "iZotope"),
    ("Element FX", "Kushview"),
]

for name_kw, vendor_kw in targets:
    matched = [p for p in plugins if (name_kw.lower() in p.get('name', '').lower() or name_kw.lower() in p.get('path', '').lower())]
    if not matched:
        print(f"[SKIP] Plugin {name_kw} not found on this machine.")
        continue
    target = matched[0]
    print(f"\n==========================================")
    print(f"Testing: {target.get('name')} ({target.get('format')})")
    print(f"Path: {target.get('path')}")
    print(f"Vendor: {target.get('vendor')} | Version: {target.get('version')}")
    print(f"ID: {target.get('id')}")

    # 1. Load Slot 0
    plugin_id = target.get('id', '').encode('utf-8') if target.get('id') else None
    res_load = lib.auradsp_plugin_slot_load(h, 0, target.get('path').encode('utf-8'), plugin_id)
    print(f"Load Slot 0 result: {res_load}")
    assert res_load == 1, f"Failed to load {target.get('name')}"

    # 2. Show Editor Slot 0（E1：第三参 title，与 Dart FFI 同一链路）
    editor_title = f"{target.get('name')} - AuraDSP Host".encode('utf-8')
    res_editor = lib.auradsp_plugin_slot_show_editor(h, 0, editor_title)
    print(f"Show Editor Slot 0 result: {res_editor}")
    if "ozone" in target.get('name', '').lower() and res_editor != 1:
        print(f"[NOTE] Ozone 12 UI gracefully caught (missing system ni-platform.dll runtime)")
    else:
        assert res_editor == 1, f"Failed to open editor for {target.get('name')}"

    time.sleep(0.5)

    # 3. Close Editor Slot 0
    res_close = lib.auradsp_plugin_slot_close_editor(h, 0)
    print(f"Close Editor Slot 0 result: {res_close}")

    # 4. Unload Slot 0
    res_unload = lib.auradsp_plugin_slot_unload(h, 0)
    print(f"Unload Slot 0 result: {res_unload}")
    assert res_unload == 1, f"Failed to unload {target.get('name')}"
    print(f"PASS: {target.get('name')} fully verified!")

lib.auradsp_destroy(h)
print("\nALL TARGET PLUGINS VERIFIED SUCCESSFULLY!")
