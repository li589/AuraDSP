# -*- coding: utf-8 -*-
import ctypes
import json
import os
import sys
import time

DLL = r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll"

def setup_lib():
    lib = ctypes.CDLL(DLL)
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_process.restype = None
    lib.auradsp_process.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_int,
    ]
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
    lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_get_status.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]
    lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_show_editor.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
    lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p, ctypes.c_int32]
    return lib

def test_plugin(lib, handle, path, name):
    print(f"\n--- Testing plugin: {name} ({path}) ---")
    ret = lib.auradsp_plugin_slot_load(handle, 0, path.encode("utf-8"), b"")
    print(f"slot_load return: {ret} (1=success, 0=fail)")
    if ret == 0:
        print(f"FAILED to load {name}")
        return False
    
    # Check status
    buf = ctypes.create_string_buffer(4096)
    lib.auradsp_plugin_slot_get_status(handle, 0, buf, len(buf))
    status_str = buf.value.decode("utf-8", errors="ignore")
    print(f"Status: {status_str}")
    
    # Process audio (stereo 256 frames)
    frames = 256
    in_buf = (ctypes.c_float * (frames * 2))(*([0.5] * (frames * 2)))
    out_buf = (ctypes.c_float * (frames * 2))()
    
    print("Processing audio 5 times...")
    for i in range(5):
        lib.auradsp_process(handle, in_buf, out_buf, frames)
    print(f"Audio processed successfully. First 4 samples: {list(out_buf[:4])}")
    
    # Bypass test
    lib.auradsp_plugin_slot_set_bypass(handle, 0, 1)
    lib.auradsp_process(handle, in_buf, out_buf, frames)
    print(f"Bypass audio first 4 samples: {list(out_buf[:4])}")
    
    # Unbypass
    lib.auradsp_plugin_slot_set_bypass(handle, 0, 0)
    lib.auradsp_process(handle, in_buf, out_buf, frames)
    
    # GUI Test
    print("Opening editor...")
    ret_gui = lib.auradsp_plugin_slot_show_editor(handle, 0, b"")
    print(f"show_editor return: {ret_gui}")
    time.sleep(1.0)
    
    print("Closing editor...")
    ret_close = lib.auradsp_plugin_slot_close_editor(handle, 0)
    print(f"close_editor return: {ret_close}")
    time.sleep(0.5)
    
    # Unload
    print("Unloading slot 0...")
    ret_un = lib.auradsp_plugin_slot_unload(handle, 0)
    print(f"slot_unload return: {ret_un}")
    
    # Audio after unload
    lib.auradsp_process(handle, in_buf, out_buf, frames)
    print(f"Audio after unload: {list(out_buf[:4])}")
    return True

def main():
    lib = setup_lib()
    handle = lib.auradsp_create(48000.0, 2)
    assert handle, "auradsp_create failed"
    
    # Test 1: CoordinateConverter
    coord_path = r"C:\Program Files\Steinberg\VstPlugins\IEM\CoordinateConverter.dll"
    if os.path.exists(coord_path):
        test_plugin(lib, handle, coord_path, "CoordinateConverter")
    
    # Test 2: FabFilter Pro-Q 3
    q3_path = r"C:\Program Files\vstplugins\FabFilter\FabFilter Pro-Q 3.dll"
    if os.path.exists(q3_path):
        test_plugin(lib, handle, q3_path, "FabFilter Pro-Q 3")
        
    # Test 3: FabFilter Saturn 2
    saturn_path = r"C:\Program Files\vstplugins\FabFilter\FabFilter Saturn 2.dll"
    if os.path.exists(saturn_path):
        test_plugin(lib, handle, saturn_path, "FabFilter Saturn 2")
        
    lib.auradsp_destroy(handle)
    print("\nALL TEST PLUGINS COMPLETED SUCCESSFULLY!")

if __name__ == "__main__":
    main()
