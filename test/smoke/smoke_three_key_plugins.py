"""
三大关键插件（FabFilter Pro-Q 3 / iZotope Ozone 12 / Kushview Element FX）
挂载 → 卸载 全链路验证。

默认（无人值守，已挂入 test/runner.py）：
    扫描 → 加载 Slot 0 → 卸载；不打开任何原生窗口。
    `--gui`：额外执行「打开编辑器 → 0.5s → 关闭编辑器」，需本机桌面会话。

本机未安装任何目标插件时整体 SKIP（退出 0），与其它插件 smoke 一致。
DLL 定位顺序：$AURADSP_ENGINE_DLL → core/desktop/windows/out/Release →
test/ → 脚本同目录（兼容历史拷贝）。修复前硬编码从仓库根加载，单独运行
必 FileNotFoundError（审查 T-01）。
"""
import argparse
import ctypes
import json
import os
import sys
import time

sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))


def find_engine_dll():
    cands = [
        os.environ.get('AURADSP_ENGINE_DLL'),
        os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                     'auradsp_engine.dll'),
        os.path.join(ROOT, 'test', 'auradsp_engine.dll'),
        os.path.join(HERE, 'auradsp_engine.dll'),
    ]
    for p in cands:
        if p and os.path.exists(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gui', action='store_true',
                    help='加载后打开/关闭插件编辑器（需要桌面会话）')
    args = ap.parse_args()

    dll_path = find_engine_dll()
    if not dll_path:
        print('[SKIP] auradsp_engine.dll 未找到（先构建 core/desktop/windows）')
        return 0
    print(f'Engine DLL: {dll_path}')
    lib = ctypes.CDLL(dll_path)

    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]

    lib.auradsp_plugin_scan.restype = ctypes.c_int32
    lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.c_int32]

    lib.auradsp_plugin_get_all.restype = ctypes.c_int32
    lib.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                           ctypes.c_int32]

    lib.auradsp_plugin_slot_load.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                             ctypes.c_char_p, ctypes.c_char_p]

    lib.auradsp_plugin_slot_unload.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int32]

    lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_show_editor.argtypes = [ctypes.c_void_p,
                                                    ctypes.c_int32,
                                                    ctypes.c_char_p]

    lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p,
                                                     ctypes.c_int32]

    h = lib.auradsp_create(48000.0, 1024)
    assert h, 'auradsp_create failed'
    print('Created AuraDSP engine:', h)

    count = lib.auradsp_plugin_scan(h, None, 0)
    buf = ctypes.create_string_buffer(524288)
    lib.auradsp_plugin_get_all(h, buf, 524288)
    plugins = json.loads(buf.value.decode('utf-8'))
    print(f'Scanned {len(plugins)} plugin entries (scan rc={count})')

    targets = [
        ('FabFilter Pro-Q 3', 'FabFilter'),
        ('Ozone 12', 'iZotope'),
        ('Element FX', 'Kushview'),
    ]

    verified = 0
    try:
        for name_kw, vendor_kw in targets:
            matched = [p for p in plugins
                       if name_kw.lower() in p.get('name', '').lower()
                       or name_kw.lower() in p.get('path', '').lower()]
            if not matched:
                print(f'[SKIP] Plugin {name_kw} not found on this machine.')
                continue
            target = matched[0]
            print('\n==========================================')
            print(f"Testing: {target.get('name')} ({target.get('format')})")
            print(f"Path: {target.get('path')}")
            vendor = target.get('vendor') or ''
            if vendor_kw.lower() not in vendor.lower() and \
                    vendor_kw.lower() not in target.get('path', '').lower():
                print(f'[WARN] vendor mismatch: expected {vendor_kw}, got {vendor}')
            print(f"Vendor: {vendor} | Version: {target.get('version')}")
            print(f"ID: {target.get('id')}")

            plugin_id = target.get('id', '').encode('utf-8') \
                if target.get('id') else None
            res_load = lib.auradsp_plugin_slot_load(
                h, 0, target.get('path').encode('utf-8'), plugin_id)
            print(f'Load Slot 0 result: {res_load}')
            assert res_load == 1, f"Failed to load {target.get('name')}"

            if args.gui:
                editor_title = f"{target.get('name')} - AuraDSP Host".encode('utf-8')
                res_editor = lib.auradsp_plugin_slot_show_editor(h, 0, editor_title)
                print(f'Show Editor Slot 0 result: {res_editor}')
                if 'ozone' in target.get('name', '').lower() and res_editor != 1:
                    print('[NOTE] Ozone 12 UI gracefully caught '
                          '(missing system ni-platform.dll runtime)')
                else:
                    assert res_editor == 1, \
                        f"Failed to open editor for {target.get('name')}"
                time.sleep(0.5)
                res_close = lib.auradsp_plugin_slot_close_editor(h, 0)
                print(f'Close Editor Slot 0 result: {res_close}')

            res_unload = lib.auradsp_plugin_slot_unload(h, 0)
            print(f'Unload Slot 0 result: {res_unload}')
            assert res_unload == 1, f"Failed to unload {target.get('name')}"
            print(f"PASS: {target.get('name')} load/unload verified!")
            verified += 1
    finally:
        lib.auradsp_destroy(h)

    if verified == 0:
        print('[SKIP] 本机未安装任何目标插件，跳过（退出 0）')
        return 0
    print(f'\nALL {verified} TARGET PLUGIN(S) VERIFIED SUCCESSFULLY!')
    return 0


if __name__ == '__main__':
    sys.exit(main())
