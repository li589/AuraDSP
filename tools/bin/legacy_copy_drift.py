#!/usr/bin/env python3
"""legacy_copy_drift.py — 桌面 legacy 与 Android vendor 副本的差异可视化（CP-03）。

背景：`engine/legacy/` 是 AuraDSP 的桌面引擎（含 40+ 条本地补丁），而
`core/android/vendor-src/libjamesdsp/` 是上游 JamesDSP 的**提取时快照**
（见 `core/android/vendor-src/ORIGIN.md`）。两者当前不是同一份代码：
Android 构建脚本只编 vendor 副本，因此桌面端的 EEL2/并发/内存修复不会自动
进入 Android。

本工具不做“必须一致”的断言（差异是现状），只把差异**显式列出来**，防止
维护者在任一副本上默默改动却以为另一边同步了。

用法：
    python tools/bin/legacy_copy_drift.py            # 打印摘要 + 差异清单
    python tools/bin/legacy_copy_drift.py --strict   # vendor 侧多出文件时返回 1
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LEGACY = os.path.join(ROOT, "engine", "legacy")
VENDOR = os.path.join(ROOT, "core", "android", "vendor-src", "libjamesdsp")


def iter_files(base: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            rel = os.path.relpath(fp, base).replace(os.sep, "/")
            out[rel] = fp
    return out


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def line_delta(a_path: str, b_path: str) -> tuple[int, int]:
    """返回 (a 独有行数, b 独有行数)，忽略纯空白差异之外不做语义比较。"""
    try:
        a_lines = open(a_path, encoding="utf-8", errors="replace").read().splitlines()
        b_lines = open(b_path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return (0, 0)
    diff = difflib.unified_diff(a_lines, b_lines, lineterm="")
    added = removed = 0
    for line in diff:
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            added += 1
        elif line.startswith("-"):
            removed += 1
    return (removed, added)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--strict", action="store_true",
                    help="vendor 侧出现 legacy 没有的文件时返回 1（防误加文件）")
    args = ap.parse_args()

    if not os.path.isdir(LEGACY) or not os.path.isdir(VENDOR):
        print(f"[FAIL] 目录缺失: {LEGACY} / {VENDOR}")
        return 1

    a = iter_files(LEGACY)
    b = iter_files(VENDOR)
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    shared = sorted(set(a) & set(b))

    changed = []
    total_a_only = total_b_only = 0
    for rel in shared:
        if sha256(a[rel]) != sha256(b[rel]):
            da, db = line_delta(a[rel], b[rel])
            total_a_only += da
            total_b_only += db
            changed.append((rel, da, db))

    print(f"legacy : {LEGACY} ({len(a)} files)")
    print(f"vendor : {VENDOR} ({len(b)} files)")
    print(f"shared : {len(shared)}; changed: {len(changed)} "
          f"(legacy +{total_a_only} / vendor +{total_b_only} lines)")
    print(f"only in legacy: {len(only_a)}; only in vendor: {len(only_b)}")

    if only_a:
        print("\n[仅 legacy 有]（AuraDSP 本地新增/补丁文件）")
        for rel in only_a:
            print(f"  {rel}")
    if only_b:
        print("\n[仅 vendor 有]（预期为空；出现即说明副本被单独加料）")
        for rel in only_b:
            print(f"  {rel}")
    if changed:
        print("\n[内容不同]（delta: legacy 独有 / vendor 独有）")
        for rel, da, db in changed:
            print(f"  {rel}  (+{da} / +{db})")

    print("\n说明：vendor 副本是上游快照（ORIGIN.md），差异是现状，不是错误；"
          "Android 统一内核方案见 docs/30-审查/跨平台基础审查-2026-11-01.md CP-03。")

    if args.strict and only_b:
        print("\n[FAIL] --strict：vendor 侧存在 legacy 没有的文件")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
