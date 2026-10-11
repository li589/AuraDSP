# -*- coding: utf-8 -*-
"""
smoke_plugin_metadata.py — B1 回归：扫描值 == 加载值（逐字段）+ 元数据卫生

背景（docs/插件模块深度改良方案-2026-10-12.md rev2，B1 数据层）：
  引擎侧把 CLAP descriptor / VST3 factory 的填充实现收敛为单一真相源，
  扫描路与加载路共用；加载路以扫描种子为基准（已有非空值不覆盖），
  于是「列表里看到的 == 槽位里得到的」逐字段成立。

测试点（对每台机器上真实存在的插件，快扫/深扫各跑一遍）：
  1. 深扫模式：name/vendor/version/category/bundleName/description
     六字段扫描值与加载值严格相等（B1 验收①）；
  2. 快扫模式：vendor/category/bundleName/description 严格相等，
     name/version 允许为快扫启发式（文件名 stem / "1.0" 占位）但不得为空；
  3. vendor 不得为字面量 "Unknown"（B1 验收②）；
  4. CLAP 条目 category 必须来自 features（非空且 != description，
     即 KV-Element-FX 的 description 错位成 category 的回归，验收④），
     且 bundleName 非空；
  5. slot_load / slot_get_status / slot_unload 全链路 rc 正常。

无人值守：无插件时 SKIP（exit 0）；不弹任何 GUI。
"""
import ctypes
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")

STRICT_FIELDS = ("name", "vendor", "version", "category", "bundleName",
                 "description")
# 快扫启发式允许差异的字段（值仍不得为空）
QUICK_HEURISTIC = ("name", "version")

MAX_VST3_TARGETS = 8
MAX_CLAP_TARGETS = 4


def load_lib():
    assert os.path.exists(DLL), f"Engine DLL not found: {DLL}"
    lib = ctypes.CDLL(DLL)
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
    lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int32
    lib.auradsp_plugin_slot_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]
    return lib


def scan_all(lib, handle, deep):
    lib.auradsp_plugin_scan(handle, None, 1 if deep else 0)
    buf = ctypes.create_string_buffer(1 << 21)
    n = lib.auradsp_plugin_get_all(handle, buf, 1 << 21)
    assert n > 0, "auradsp_plugin_get_all failed"
    return json.loads(buf.value.decode("utf-8"))


def slot_status(lib, handle, slot=0):
    buf = ctypes.create_string_buffer(1 << 20)
    n = lib.auradsp_plugin_slot_get_status(handle, slot, buf, 1 << 20)
    assert n > 0, "auradsp_plugin_slot_get_status failed"
    return json.loads(buf.value.decode("utf-8"))


def pick_targets(items):
    vst3 = [p for p in items if p.get("format") == "VST3"][:MAX_VST3_TARGETS]
    clap = [p for p in items if p.get("format") == "CLAP"][:MAX_CLAP_TARGETS]
    return vst3 + clap


def check_one(lib, handle, scan_entry, deep, failures):
    name = scan_entry.get("name") or scan_entry.get("path")
    path = scan_entry["path"].encode("utf-8")
    pid = (scan_entry.get("id") or "").encode("utf-8")

    rc = lib.auradsp_plugin_slot_load(handle, 0, path, pid)
    if rc != 1:
        failures.append(f"[{name}] slot_load rc={rc}")
        lib.auradsp_plugin_slot_unload(handle, 0)
        return
    status = slot_status(lib, handle)
    lib.auradsp_plugin_slot_unload(handle, 0)
    loaded = status.get("plugin") or {}
    if not loaded:
        failures.append(f"[{name}] slot status 无 plugin 元数据")
        return

    def bad(msg):
        failures.append(f"[{name}] {msg}")

    # 1. 逐字段一致性
    for f in STRICT_FIELDS:
        sv = scan_entry.get(f) or ""
        lv = loaded.get(f) or ""
        if sv == lv:
            continue
        if not deep and f in QUICK_HEURISTIC:
            continue  # 快扫启发式：文件名/占位版本允许与加载值不同
        bad(f"{f}: scan={sv!r} load={lv!r}")

    # 2. 快扫启发式字段不得为空
    for f in QUICK_HEURISTIC:
        if not (loaded.get(f) or "").strip():
            bad(f"{f} 加载值为空")

    # 3. vendor 卫生
    if (loaded.get("vendor") or "") in ("", "Unknown"):
        bad(f"vendor={loaded.get('vendor')!r}（验收②：不得为空/Unknown）")

    # 4. CLAP 专项
    if scan_entry.get("format") == "CLAP":
        cat = loaded.get("category") or ""
        desc = loaded.get("description") or ""
        if not cat:
            bad("CLAP category 为空（应来自 features）")
        if cat and cat == desc:
            bad(f"CLAP category == description（{cat!r}，E-4 错位回归）")
        if not (loaded.get("bundleName") or "").strip():
            bad("CLAP bundleName 为空")


def main():
    lib = load_lib()
    handle = lib.auradsp_create(48000.0, 1024)
    assert handle, "auradsp_create failed"

    failures = []
    checked = 0
    for deep in (False, True):
        items = scan_all(lib, handle, deep)
        targets = pick_targets(items)
        mode = "深扫" if deep else "快扫"
        print(f"=== [{mode}] 共 {len(items)} 条，抽检 {len(targets)} 条 ===")
        if not targets:
            print(f"[SKIP] {mode}未发现可测试插件（本机无 VST3/CLAP）")
            continue
        for entry in targets:
            check_one(lib, handle, entry, deep, failures)
            checked += 1

    lib.auradsp_destroy(handle)

    if checked == 0:
        print("[SKIP] 本机无可用插件，元数据一致性测试跳过（不视为失败）")
        return 0

    if failures:
        print(f"\n[FAIL] {len(failures)} 项不一致：")
        for f in failures:
            print("  - %s" % f)
        return 1
    print(f"\n[PASS] {checked} 个插件加载实例全部满足「扫描值 == 加载值」")
    return 0


if __name__ == "__main__":
    sys.exit(main())
