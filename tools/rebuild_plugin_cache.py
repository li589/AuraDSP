"""rebuild_plugin_cache.py — 用引擎真实扫描结果重建 VST 插件磁盘缓存。

背景：2026-10-10 发现 %APPDATA%\\AuraDSP\\plugins\\plugin_cache.json 被写入
3 条手工伪造数据（id 连续 1/2/3，路径被截断为 C:\\VST3\\... 丢失
"Program Files\\Common Files"），而 PluginManager.loadCache() 不做任何路径
存在性校验，导致 APP 启动后只显示 3 个永远加载不了的插件（真实扫描为 76 个）。

本工具：
  1. 备份现有缓存为 plugin_cache.json.bak-<时间戳>
  2. 调用引擎真实扫描
  3. 只保留路径实际存在的条目
  4. 原子写回缓存

用法：
  python tools/rebuild_plugin_cache.py            # 重建
  python tools/rebuild_plugin_cache.py --dry-run  # 只体检不写
"""

import argparse
import ctypes
import json
import os
import shutil
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")
CACHE = os.path.join(os.environ.get("APPDATA", ""), "AuraDSP", "plugins",
                     "plugin_cache.json")

JSON_FIELDS = ("id", "name", "vendor", "version", "category", "format",
               "path", "isCompatible", "errorMessage")


def scan(sample_rate=48000.0, block=2048):
    """调用引擎扫描插件，返回 PluginMetadata 字典列表。"""
    lib = ctypes.CDLL(DLL)
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_plugin_scan.restype = ctypes.c_int32
    lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.c_int32]
    lib.auradsp_plugin_get_count.restype = ctypes.c_int32
    lib.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
    lib.auradsp_plugin_get_item.restype = ctypes.c_int32
    lib.auradsp_plugin_get_item.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                            ctypes.c_char_p, ctypes.c_int32]

    handle = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(sample_rate),
                                                block))
    if not handle:
        raise RuntimeError("auradsp_create 失败")
    try:
        lib.auradsp_plugin_scan(handle, None, 0)
        count = lib.auradsp_plugin_get_count(handle)
        buf = ctypes.create_string_buffer(65536)
        out = []
        for i in range(count):
            if lib.auradsp_plugin_get_item(handle, i, buf, 65536) <= 0:
                continue
            try:
                raw = json.loads(buf.value.decode("utf-8", "replace"))
            except ValueError:
                continue
            out.append({k: raw.get(k) for k in JSON_FIELDS})
        return out
    finally:
        lib.auradsp_destroy(handle)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(DLL):
        print("找不到引擎 DLL：%s" % DLL)
        return 1

    plugins = scan()
    valid = [p for p in plugins if p.get("path") and os.path.exists(p["path"])]
    dropped = len(plugins) - len(valid)

    print("引擎扫描：%d 个，路径存在 %d 个，剔除 %d 个"
          % (len(plugins), len(valid), dropped))

    print("\n现有缓存：%s" % CACHE)
    if os.path.exists(CACHE):
        try:
            old = json.load(open(CACHE, encoding="utf-8"))
            bad = [x for x in old
                   if not os.path.exists(x.get("path", ""))]
            print("  %d 条，其中路径不存在 %d 条" % (len(old), len(bad)))
            for x in old:
                print("   - %-24s exists=%-5s %s"
                      % (x.get("name", "?")[:24],
                         os.path.exists(x.get("path", "")),
                         x.get("path", "")))
        except ValueError as e:
            print("  解析失败（视为脏数据）：%s" % e)
    else:
        print("  不存在")

    if args.dry_run:
        print("\n[dry-run] 未写入。")
        return 0

    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    if os.path.exists(CACHE):
        backup = "%s.bak-%s" % (CACHE, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(CACHE, backup)
        print("\n已备份 -> %s" % backup)

    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(valid, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CACHE)

    print("\n已重建缓存：%d 条 -> %s" % (len(valid), CACHE))
    return 0


if __name__ == "__main__":
    sys.exit(main())