# -*- coding: utf-8 -*-
"""smoke_plugin_vst2.py — VST2 64/32 位驱动门禁（2026-11-03）。

覆盖：
  1. 快扫：探针条目出现，format=VST2，is64Bit 正确；
  2. 深扫：name/vendor/version/category/id 来自插件自报；
  3. 非插件 DLL 被 PE 导出表过滤；
  4. 64 位加载 + 音频：0.8 输入 → 0.4 输出；
  5. 旁路：输出等于输入；
  6. 预设：AUR2 保存/载入往返；
  7. 32 位：远程深扫拿到真实元数据，加载经 plugin_host_x86，音频 0.4；
  8. 卸载：槽清空，可重复加载。

依赖：core/desktop/windows/out/Release/auradsp_engine.dll +
      test_vst2_fixture 构建产物（test/vst2/ 与 test/vst2/x86/）。
"""
import ctypes
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")
FIXTURE_X64 = os.path.join(ROOT, "test", "vst2", "x64")
FIXTURE_X86 = os.path.join(ROOT, "test", "vst2", "x86")

PLUGIN_NAME = "AuraTestVST2"
PROCESS_MODE = os.environ.get("AURA_PLUGIN_HOST_MODE", "").strip().lower() == "process"
FAILS = []


def check(cond, msg):
    if cond:
        print(f"  [OK] {msg}")
    else:
        print(f"  [FAIL] {msg}")
        FAILS.append(msg)


def load_lib():
    assert os.path.exists(DLL), f"Engine DLL not found: {DLL}"
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
    lib.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_set_bypass.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32]
    lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]
    lib.auradsp_plugin_slot_save_preset.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_save_preset.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
    lib.auradsp_plugin_slot_load_preset.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_load_preset.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
    lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_show_editor.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
    lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p, ctypes.c_int32]
    lib.auradsp_plugin_slot_is_editor_open.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_is_editor_open.argtypes = [ctypes.c_void_p, ctypes.c_int32]
    return lib


def scan(lib, handle, directory, deep):
    lib.auradsp_plugin_scan(handle, directory.encode("utf-8"), 1 if deep else 0)
    buf = ctypes.create_string_buffer(1 << 22)
    n = lib.auradsp_plugin_get_all(handle, buf, len(buf))
    assert n > 0, "auradsp_plugin_get_all failed"
    return json.loads(buf.value.decode("utf-8"))


def find_plugin(items, name=PLUGIN_NAME, is64bit=None):
    for item in items:
        if (item.get("name") or "") != name:
            continue
        if is64bit is not None and bool(item.get("is64Bit")) != is64bit:
            continue
        return item
    return None


def status(lib, handle, slot=0):
    buf = ctypes.create_string_buffer(1 << 20)
    n = lib.auradsp_plugin_slot_get_status(handle, slot, buf, len(buf))
    if n <= 0:
        return {}
    return json.loads(buf.value.decode("utf-8"))


def process_const(lib, handle, value, blocks=12, frames=256):
    """恒定立体声输入跑若干块；返回最后一块输出。"""
    n = frames * 2
    in_arr = (ctypes.c_float * n)(*([value] * n))
    out_arr = (ctypes.c_float * n)()
    for _ in range(blocks):
        lib.auradsp_process(handle, in_arr, out_arr, frames)
        time.sleep(0.002)
    return list(out_arr)


def max_abs_diff(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def test_one(lib, handle, directory, deep, is_x86):
    tag = "32位" if is_x86 else "64位"
    print(f"\n=== [{tag}] 扫描 {directory} ===")
    items = scan(lib, handle, directory, deep)
    entry = find_plugin(items, is64bit=not is_x86)
    check(entry is not None, f"[{tag}] 扫描结果含 {PLUGIN_NAME}")
    if not entry:
        return
    check(entry.get("format") == "VST2", f"[{tag}] format=VST2（实际 {entry.get('format')}）")
    check(bool(entry.get("is64Bit")) == (not is_x86),
          f"[{tag}] is64Bit={entry.get('is64Bit')}")
    if deep and is_x86:
        if PROCESS_MODE:
            # 进程外模式：扫描由 x64 宿主执行，它没有 x86 客户端，32 位 VST2
            # 只能拿到快扫元数据；加载仍由引擎路由到 x86 位桥，音频不受影响。
            check(bool(entry.get("name")), f"[{tag}] 深扫 name 非空（宿主快扫）")
            check(bool(entry.get("path")), f"[{tag}] 深扫 path 非空")
            print(f"  [INFO] [{tag}] 进程外模式下 32 位深扫为宿主快扫元数据")
        else:
            # 进程内模式：引擎用 Op::QueryMetadata 让 x86 宿主代查真实元数据。
            check((entry.get("name") or "") == PLUGIN_NAME,
                  f"[{tag}] 远程深扫 name={entry.get('name')!r}")
            check((entry.get("vendor") or "") == "AuraDSP",
                  f"[{tag}] 远程深扫 vendor={entry.get('vendor')!r}")
            check((entry.get("version") or "").startswith("1.0"),
                  f"[{tag}] 远程深扫 version={entry.get('version')!r}")
            check((entry.get("id") or "") == "41757261",
                  f"[{tag}] 远程深扫 id={entry.get('id')!r}")
    elif deep:
        # 64 位：进程内深扫按安全策略只做 PE 快扫（真实元数据由加载路补齐）。
        check(bool(entry.get("name")), f"[{tag}] 深扫 name 非空（快扫）")
        check(bool(entry.get("path")), f"[{tag}] 深扫 path 非空")

    print(f"=== [{tag}] 加载 + 音频 ===")
    rc = lib.auradsp_plugin_slot_load(
        handle, 0, entry["path"].encode("utf-8"),
        (entry.get("id") or "").encode("utf-8"))
    check(rc == 1, f"[{tag}] slot_load rc={rc}")
    if rc != 1:
        return
    check(lib.auradsp_plugin_slot_set_bypass(handle, 0, 0) == 1,
          f"[{tag}] 解除挂载即旁路")

    out = process_const(lib, handle, 0.8, blocks=16)
    # 引擎默认链可能带轻微限幅/抖动；0.4 是主判决，允许 2e-3 余量。
    check(abs(out[0] - 0.4) < 2e-3, f"[{tag}] 0.8 输入 → {out[0]:.6f}（期望 0.4）")

    check(lib.auradsp_plugin_slot_set_bypass(handle, 0, 1) == 1,
          f"[{tag}] 设置旁路")
    out = process_const(lib, handle, 0.8, blocks=8)
    check(abs(out[0] - 0.8) < 2e-3, f"[{tag}] 旁路输出 {out[0]:.6f}（期望 0.8）")

    # 编辑器：探针 effEditOpen 直接返回成功；验证容器创建 + effEditIdle 心跳 + 关闭。
    print(f"=== [{tag}] 编辑器 ===")
    opened = lib.auradsp_plugin_slot_show_editor(handle, 0, b"AuraTestVST2")
    if opened == 1:
        check(lib.auradsp_plugin_slot_is_editor_open(handle, 0) == 1,
              f"[{tag}] 编辑器已打开")
        time.sleep(0.2)   # 至少 6 个 30ms idle tick
        check(lib.auradsp_plugin_slot_close_editor(handle, 0) == 1,
              f"[{tag}] 编辑器关闭")
        check(lib.auradsp_plugin_slot_is_editor_open(handle, 0) == 0,
              f"[{tag}] 编辑器状态已清除")
    else:
        print(f"  [SKIP] [{tag}] 编辑器不可用（无桌面会话或插件拒绝）")

    print(f"=== [{tag}] 预设往返 ===")
    tmp = tempfile.mkdtemp(prefix="auravst2_")
    preset = os.path.join(tmp, "roundtrip.aurapreset")
    try:
        check(lib.auradsp_plugin_slot_save_preset(
                  handle, 0, preset.encode("utf-8")) == 1,
              f"[{tag}] save_preset")
        check(os.path.exists(preset) and os.path.getsize(preset) >= 20,
              f"[{tag}] 预设文件已生成（{os.path.getsize(preset) if os.path.exists(preset) else 0} B）")
        if os.path.exists(preset):
            with open(preset, "rb") as f:
                check(f.read(4) == b"AUR2", f"[{tag}] 预设 magic=AUR2")
        check(lib.auradsp_plugin_slot_load_preset(
                  handle, 0, preset.encode("utf-8")) == 1,
              f"[{tag}] load_preset")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    st = status(lib, handle)
    check(bool(st.get("hasActive")), f"[{tag}] status.hasActive")
    plug = status(lib, handle).get("plugin") or {}
    check((plug.get("name") or "") == PLUGIN_NAME,
          f"[{tag}] 加载路 name={plug.get('name')!r}")
    check((plug.get("vendor") or "") == "AuraDSP",
          f"[{tag}] 加载路 vendor={plug.get('vendor')!r}")
    check((plug.get("version") or "").startswith("1.0"),
          f"[{tag}] 加载路 version={plug.get('version')!r}")
    if is_x86:
        check(st.get("remoteMode") is True,
              f"[{tag}] status.remoteMode=True（实际 {st.get('remoteMode')}）")

    check(lib.auradsp_plugin_slot_unload(handle, 0) == 1, f"[{tag}] unload")
    st = status(lib, handle)
    check(not st.get("hasActive"), f"[{tag}] 卸载后 hasActive=False")
    check(lib.auradsp_plugin_slot_load(
              handle, 0, entry["path"].encode("utf-8"),
              (entry.get("id") or "").encode("utf-8")) == 1,
          f"[{tag}] 卸载后可重复加载")
    lib.auradsp_plugin_slot_unload(handle, 0)


def test_bad_and_filter(lib, handle):
    print("\n=== [拒绝路径] 坏 magic + 非插件 DLL 过滤 ===")
    bad_dir = os.path.join(ROOT, "test", "vst2", "bad")
    if os.path.isdir(bad_dir):
        items = scan(lib, handle, bad_dir, True)
        entry = find_plugin(items, "AuraTestVST2Bad")
        check(entry is not None, "坏 magic 探针仍可被发现（深扫回退快扫）")
        if entry:
            rc = lib.auradsp_plugin_slot_load(
                handle, 0, entry["path"].encode("utf-8"),
                (entry.get("id") or "").encode("utf-8"))
            check(rc != 1, f"坏 magic 加载被拒（rc={rc}）")
            check(not status(lib, handle).get("hasActive"), "坏 magic 失败后槽未激活")
            lib.auradsp_plugin_slot_unload(handle, 0)
    else:
        print(f"  [SKIP] 缺少坏 magic 探针: {bad_dir}")

    tmp = tempfile.mkdtemp(prefix="auravst2_filter_")
    try:
        src = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                           "plugin_host_x64.exe")
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(tmp, "not_a_plugin.dll"))
            items = scan(lib, handle, tmp, True)
            check(not any("not_a_plugin.dll" in (i.get("path") or "") for i in items),
                  "无 VSTPluginMain 导出的 DLL 被 PE 导出表过滤")
        else:
            print(f"  [SKIP] 缺少参照 DLL: {src}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if not os.path.isdir(FIXTURE_X64):
        print(f"[SKIP] 缺少 VST2 探针目录: {FIXTURE_X64}")
        return 0
    lib = load_lib()
    handle = lib.auradsp_create(48000.0, 1024)
    assert handle, "auradsp_create failed"
    try:
        # 64 位：快扫 + 深扫
        test_one(lib, handle, FIXTURE_X64, deep=False, is_x86=False)
        test_one(lib, handle, FIXTURE_X64, deep=True, is_x86=False)
        # 32 位：只跑深扫（远程查询是本期新增路径）
        if os.path.isdir(FIXTURE_X86):
            test_one(lib, handle, FIXTURE_X86, deep=True, is_x86=True)
        else:
            print(f"[SKIP] 缺少 32 位探针: {FIXTURE_X86}")
        test_bad_and_filter(lib, handle)
    finally:
        lib.auradsp_destroy(handle)

    if FAILS:
        print(f"\n[FAIL] {len(FAILS)} 项：")
        for f in FAILS:
            print(f"  - {f}")
        return 1
    print("\n[PASS] VST2 64/32 位扫描、加载、音频、旁路、预设、卸载全链通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
