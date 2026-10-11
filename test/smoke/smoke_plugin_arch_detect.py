#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_plugin_arch_detect.py — B2 专题五：32 位插件识别（D 类目标）

本机通常没有真实 32 位插件，因此用**合成最小 PE 头**验证整条链路：
  D1  多架构 bundle 探测：x86_64-win 与 x86-win 都能被发现（旧实现只认前者）
  D2  32 位条目"可发现但不可加载"：is64Bit=false + isCompatible=false
      + 明确 errorMessage，且不会从扫描结果里消失
  D3  加载路拒绝：auradsp_plugin_slot_load 对 32 位条目返回 0
      （不真的 LoadLibrary —— x64 进程加载 32 位 DLL 必 193）

合成 PE 只需解析到 IMAGE_FILE_MACHINE 为止：
  MZ | e_lfanew@0x3C -> PE\\0\\0 | Machine(WORD)@e_lfanew+4
注意 C++ 侧 f.read(sizeof(IMAGE_DOS_HEADER)) 要读满 64 字节，
文件不足 64 字节会置 failbit 导致 peMachineType 返回 0（按 64 位，
历史保守行为），因此桩文件统一补足到 128 字节。
"""

import ctypes
import json
import os
import shutil
import struct
import sys
import tempfile

DLL_PATH = r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll"

failures = []


def check(cond, msg):
    tag = "PASS" if cond else "FAIL"
    print(f"  [{tag}] {msg}")
    if not cond:
        failures.append(msg)


def make_fake_pe(path, machine):
    e_lfanew = 0x40
    buf = bytearray(128)
    buf[0:2] = b"MZ"
    struct.pack_into("<I", buf, 0x3C, e_lfanew)
    buf[e_lfanew:e_lfanew + 4] = b"PE\x00\x00"
    struct.pack_into("<H", buf, e_lfanew + 4, machine)
    with open(path, "wb") as f:
        f.write(buf)


def write_bundle(root, bundle_name, arch, inner_ext, machine):
    """构造 <bundle>/Contents/<arch>/<inner>.<ext>，返回 bundle 目录路径。"""
    bundle_dir = os.path.join(root, bundle_name)
    inner_dir = os.path.join(bundle_dir, "Contents", arch)
    os.makedirs(inner_dir, exist_ok=True)
    inner = os.path.join(inner_dir, bundle_name.replace(".vst3", "").replace(".clap", "") + inner_ext)
    make_fake_pe(inner, machine)
    return bundle_dir


def main():
    if not os.path.exists(DLL_PATH):
        print(f"[FATAL] Engine DLL not found: {DLL_PATH}")
        return 1

    dll = ctypes.CDLL(DLL_PATH)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_scan.restype = ctypes.c_int
    dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_get_count.restype = ctypes.c_int
    dll.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_all.restype = ctypes.c_int
    dll.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_slot_load.restype = ctypes.c_int
    dll.auradsp_plugin_slot_load.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p]

    IMAGE_FILE_MACHINE_I386 = 0x014C
    IMAGE_FILE_MACHINE_AMD64 = 0x8664

    root = tempfile.mkdtemp(prefix="auradsp_arch_")
    h = None
    try:
        # ---- 合成插件树 ----
        write_bundle(root, "Legacy32.vst3", "x86-win", ".vst3", IMAGE_FILE_MACHINE_I386)
        write_bundle(root, "Modern64.vst3", "x86_64-win", ".vst3", IMAGE_FILE_MACHINE_AMD64)
        # 双架构 bundle：x86_64-win 必须优先，且只报一条
        both = write_bundle(root, "Both.vst3", "x86_64-win", ".vst3", IMAGE_FILE_MACHINE_AMD64)
        both_32_dir = os.path.join(both, "Contents", "x86-win")
        os.makedirs(both_32_dir, exist_ok=True)
        make_fake_pe(os.path.join(both_32_dir, "Both.vst3"),
                     IMAGE_FILE_MACHINE_I386)
        # 单文件 32 位 CLAP（无 bundle 目录）
        clap32 = os.path.join(root, "Legacy32.clap")
        make_fake_pe(clap32, IMAGE_FILE_MACHINE_I386)

        h = dll.auradsp_create(48000.0, 1024)
        if not h:
            print("[FATAL] auradsp_create returned null")
            return 1

        def scan_and_get(deep):
            # 注意：C ABI 的 extra_dirs 是分号分隔的路径串（非 JSON 数组），
            # 见 PluginHostManager::scanPlugins 的 getline(iss, path, ';')。
            extra = root.encode("utf-8")
            rc = dll.auradsp_plugin_scan(h, extra, 1 if deep else 0)
            check(rc >= 0, f"auradsp_plugin_scan(deep={int(deep)}) 返回 {rc}")
            buf = ctypes.create_string_buffer(1 << 20)
            dll.auradsp_plugin_get_all(h, buf, len(buf))
            return json.loads(buf.value.decode("utf-8"))

        for deep in (False, True):
            print(f"\n=== {'深扫' if deep else '快扫'} ===")
            plugins = scan_and_get(deep)
            mine = [p for p in plugins if root.replace("\\", "/").lower() in p["path"].replace("\\", "/").lower()]
            by_name = {p["name"]: p for p in mine}

            # D1/D2：32 位 VST3 bundle 被发现且标记不兼容
            legacy = by_name.get("Legacy32")
            check(legacy is not None, "Legacy32.vst3（x86-win）出现在扫描结果中（D1）")
            if legacy:
                check(legacy["is64Bit"] is False, "Legacy32.vst3 is64Bit=false")
                check(legacy["isCompatible"] is False, "Legacy32.vst3 isCompatible=false")
                check("32 位" in legacy["errorMessage"],
                      f"Legacy32.vst3 errorMessage 指明位数问题：{legacy['errorMessage']!r}")
                check(legacy["vendor"] != "", "Legacy32.vst3 vendor 非空")
                check(legacy["vendor"] != "x86-win",
                      "Legacy32.vst3 vendor 不退化成名架构目录名 x86-win")

            # 对照组：64 位 bundle 正常识别
            modern = by_name.get("Modern64")
            check(modern is not None, "Modern64.vst3（x86_64-win）出现在扫描结果中")
            if modern:
                check(modern["is64Bit"] is True, "Modern64.vst3 is64Bit=true")
                check(modern["isCompatible"] is True, "Modern64.vst3 isCompatible=true")

            # 双架构 bundle：只报 64 位条目一条
            both_entries = [p for p in mine if p["name"] == "Both"]
            check(len(both_entries) == 1, f"Both.vst3 仅一条条目（实测 {len(both_entries)}）")
            if len(both_entries) == 1:
                check(both_entries[0]["is64Bit"] is True,
                      "Both.vst3 解析到 x86_64-win（本进程架构优先）")

            # 32 位单文件 CLAP：queryMetadata 早分支产出不兼容条目
            clap = by_name.get("Legacy32")
            clap_entries = [p for p in mine if p["format"] == "CLAP"]
            check(len(clap_entries) == 1, f"Legacy32.clap 恰有一条 CLAP 条目（实测 {len(clap_entries)}）")
            if clap_entries:
                c = clap_entries[0]
                check(c["is64Bit"] is False, "Legacy32.clap is64Bit=false")
                check(c["isCompatible"] is False, "Legacy32.clap isCompatible=false")
                check("32 位" in c["errorMessage"], "Legacy32.clap errorMessage 指明位数问题")

        # ---- D3：加载路拒绝（不走到 LoadLibrary） ----
        print("\n=== 加载路拒绝 ===")
        legacy_bin = os.path.join(root, "Legacy32.vst3", "Contents", "x86-win", "Legacy32.vst3")
        rc = dll.auradsp_plugin_slot_load(
            h, 0, legacy_bin.encode("utf-8"), None)
        check(rc == 0, f"auradsp_plugin_slot_load(32 位 VST3) 返回 0（实测 {rc}）")
        rc2 = dll.auradsp_plugin_slot_load(
            h, 1, clap32.encode("utf-8"), None)
        check(rc2 == 0, f"auradsp_plugin_slot_load(32 位 CLAP) 返回 0（实测 {rc2}）")

        # 扫描计数自洽：快照里我们的 4 个 bundle 共 4 条（VST3x3 + CLAPx1）
        cnt = dll.auradsp_plugin_get_count(h)
        print(f"  [INFO] 扫描总计 {cnt} 条（含系统目录真实插件）")
    finally:
        if h:
            dll.auradsp_destroy(h)
        shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        print(f"SMOKE FAILED: {len(failures)} check(s) failed")
        for f_ in failures:
            print(f"  - {f_}")
        return 1
    print("SMOKE PASSED: 32-bit plugin detection OK (D1/D2/D3)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
