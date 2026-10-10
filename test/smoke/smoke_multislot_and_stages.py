"""
smoke_multislot_and_stages.py — 验证 AuraDSP 多插件挂载槽、处理链阶段插入与预设流式序列化
"""
import ctypes
import json
import os
import sys
import tempfile

DLL_PATH = os.path.abspath(r"core/desktop/windows/out/Release/auradsp_engine.dll")
if not os.path.exists(DLL_PATH):
    print(f"Error: DLL not found at {DLL_PATH}")
    sys.exit(1)

lib = ctypes.CDLL(DLL_PATH)

# 函数声明
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]

lib.auradsp_destroy.restype = None
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]

lib.auradsp_process.restype = None
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int32]

lib.auradsp_plugin_get_num_slots.restype = ctypes.c_int32
lib.auradsp_plugin_get_num_slots.argtypes = [ctypes.c_void_p]

lib.auradsp_plugin_scan.restype = ctypes.c_int32
lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]

lib.auradsp_plugin_get_all.restype = ctypes.c_int32
lib.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]

lib.auradsp_plugin_slot_load.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_char_p]

lib.auradsp_plugin_slot_unload.restype = ctypes.c_int32
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int32]

lib.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int32
lib.auradsp_plugin_slot_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32]

lib.auradsp_plugin_slot_get_latency.restype = ctypes.c_uint32
lib.auradsp_plugin_slot_get_latency.argtypes = [ctypes.c_void_p, ctypes.c_int32]

lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int32
lib.auradsp_plugin_slot_get_status.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]

lib.auradsp_plugin_slot_set_insert_stage.restype = ctypes.c_int32
lib.auradsp_plugin_slot_set_insert_stage.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32]

lib.auradsp_plugin_slot_get_insert_stage.restype = ctypes.c_int32
lib.auradsp_plugin_slot_get_insert_stage.argtypes = [ctypes.c_void_p, ctypes.c_int32]

lib.auradsp_plugin_slot_save_preset.restype = ctypes.c_int32
lib.auradsp_plugin_slot_save_preset.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]

lib.auradsp_plugin_slot_load_preset.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load_preset.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]

def main():
    print("=== [1] 创建引擎句柄 ===")
    h = lib.auradsp_create(48000.0, 1024)
    assert h is not None, "Failed to create auradsp handle"

    num_slots = lib.auradsp_plugin_get_num_slots(h)
    print(f"Num plugin slots supported: {num_slots}")
    assert num_slots == 2, f"Expected 2 slots, got {num_slots}"

    print("=== [2] 扫描已安装效果器 ===")
    count = lib.auradsp_plugin_scan(h, None, 0)
    print(f"Found {count} plugins")
    buf = ctypes.create_string_buffer(262144)
    lib.auradsp_plugin_get_all(h, buf, 262144)
    plugins = json.loads(buf.value.decode('utf-8'))
    print(f"Parsed {len(plugins)} plugin entries")

    if not plugins:
        print("No plugins found on this system, verifying empty slot stage controls...")
        for s in range(2):
            lib.auradsp_plugin_slot_set_insert_stage(h, s, 1)
            stage = lib.auradsp_plugin_slot_get_insert_stage(h, s)
            assert stage == 1, f"Expected stage 1 for slot {s}, got {stage}"
        lib.auradsp_destroy(h)
        print("Slot controls verified successfully!")
        return

    # 选取第一个可用插件进行多插槽挂载
    target_plugin = plugins[0]
    plugin_path = target_plugin['path'].encode('utf-8')
    plugin_id = target_plugin.get('id', '').encode('utf-8')
    print(f"Target plugin: {target_plugin['name']} at {target_plugin['path']}")

    print("=== [3] 槽位 0 与 槽位 1 并行加载 ===")
    rc0 = lib.auradsp_plugin_slot_load(h, 0, plugin_path, plugin_id)
    print(f"Slot 0 load rc: {rc0}")
    assert rc0 == 1, f"Failed to load slot 0, rc={rc0}"

    rc1 = lib.auradsp_plugin_slot_load(h, 1, plugin_path, plugin_id)
    print(f"Slot 1 load rc: {rc1}")
    assert rc1 == 1, f"Failed to load slot 1, rc={rc1}"

    print("=== [4] 检验阶段调整（Stage 0: Pre-DSP, Stage 4: Post-Limiter） ===")
    lib.auradsp_plugin_slot_set_insert_stage(h, 0, 0) # Slot 0 -> Pre-DSP
    lib.auradsp_plugin_slot_set_insert_stage(h, 1, 4) # Slot 1 -> Post-Limiter

    stg0 = lib.auradsp_plugin_slot_get_insert_stage(h, 0)
    stg1 = lib.auradsp_plugin_slot_get_insert_stage(h, 1)
    assert stg0 == 0, f"Slot 0 stage mismatch: expected 0, got {stg0}"
    assert stg1 == 4, f"Slot 1 stage mismatch: expected 4, got {stg1}"
    print(f"Slot 0 stage: {stg0} (Pre-DSP), Slot 1 stage: {stg1} (Post-Limiter) OK!")

    print("=== [5] 预设保存与加载序列化验证 ===")
    with tempfile.NamedTemporaryFile(suffix=".aurapreset", delete=False) as tmp:
        preset_path = tmp.name
    try:
        save_rc = lib.auradsp_plugin_slot_save_preset(h, 0, preset_path.encode('utf-8'))
        print(f"Save preset rc: {save_rc}, file size: {os.path.getsize(preset_path)} bytes")
        assert save_rc == 1, f"Save preset failed, rc={save_rc}"
        assert os.path.getsize(preset_path) > 0, "Preset file is empty"

        load_rc = lib.auradsp_plugin_slot_load_preset(h, 0, preset_path.encode('utf-8'))
        print(f"Load preset rc: {load_rc}")
        assert load_rc == 1, f"Load preset failed, rc={load_rc}"
    finally:
        if os.path.exists(preset_path):
            os.remove(preset_path)

    print("=== [6] 双插槽音频处理与旁路切换 ===")
    frames = 256
    in_buf = (ctypes.c_float * (frames * 2))(*([0.5] * (frames * 2)))
    out_buf = (ctypes.c_float * (frames * 2))()
    lib.auradsp_process(h, in_buf, out_buf, frames)
    print(f"Processed 256 frames with dual active slots: sample[0] L={out_buf[0]:.4f}, R={out_buf[1]:.4f}", flush=True)

    lib.auradsp_plugin_slot_set_bypass(h, 0, 1)
    lib.auradsp_plugin_slot_set_bypass(h, 1, 1)
    in_buf = (ctypes.c_float * (frames * 2))(*([0.5] * (frames * 2)))
    out_buf = (ctypes.c_float * (frames * 2))()
    lib.auradsp_process(h, in_buf, out_buf, frames)
    print(f"Processed 256 frames with bypassed slots: sample[0] L={out_buf[0]:.4f}, R={out_buf[1]:.4f}", flush=True)

    print("=== [7] 双插槽卸载验证 ===", flush=True)
    print("Calling unload 0...", flush=True)
    unl0 = lib.auradsp_plugin_slot_unload(h, 0)
    print(f"unl0 = {unl0}", flush=True)
    assert unl0 == 1, f"Failed to unload slot 0, rc={unl0}"
    print("Calling unload 1...", flush=True)
    unl1 = lib.auradsp_plugin_slot_unload(h, 1)
    print(f"unl1 = {unl1}", flush=True)
    assert unl1 == 1, f"Failed to unload slot 1, rc={unl1}"

    print("Calling destroy...", flush=True)
    lib.auradsp_destroy(h)
    print("Destroyed ok!", flush=True)
    print("ALL TESTS PASSED: Multi-slot, stage insert & preset serialization 100% OK!", flush=True)

if __name__ == '__main__':
    main()
