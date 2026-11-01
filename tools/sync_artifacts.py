#!/usr/bin/env python3
"""sync_artifacts.py — 产物一键同步/覆盖（跨平台，S4）。

取代原 PowerShell 实现（tools/windows/sync_artifacts.ps1，现降为 thin
wrapper 转发到本脚本）。语义与 PS1 版严格一致：

  把真源二进制传播到各消费端：
    Windows 真源：
      core/desktop/windows/out/Release        auradsp_engine.dll +
                                              auradsp_plugin_host.exe
      core/desktop/windows-drivers/out/Release auravm/auraasio/
                                              auravaio_bridge.dll
    Windows 消费端：
      test/、app/auradsp_app/build/windows/x64/runner/Release、
      dist/AuraDSP-Windows-x64，外加一条专用拷贝
      engine.dll -> windows-drivers/out/Release（驱动工具同目录加载）
    Linux 真源：
      core/desktop/linux/out/Release          libauradsp_engine.so
    Linux 消费端：
      test/、app/auradsp_app/build/linux/x64/release/bundle/lib、
      dist/AuraDSP-Linux-x64
      （Linux 一期无桥与 plugin_host 产物，清单只有引擎 .so。）

  行为（与 PS1 一致）：
    - 任一目标目录缺失或单文件拷贝失败 => 警告并跳过，不中断其余
    - 源文件缺失 => 跳过该文件，不中断
    - 本脚本不编译；编译归各平台 build 脚本
    - --pack-zip 在同步后重打包 dist 绿色包 zip（默认关；正式 zip
      归 build_windows.ps1 Step6 / 各平台打包流程所有）

退出码：0 = 全部到位；2 = 有跳过项（需回看警告）。

用法：
    python tools/sync_artifacts.py [--what-if] [--pack-zip]
"""

import argparse
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def platform_layout():
    """返回 (源文件 [(源目录, 文件名)], 目标目录列表, 专用拷贝
    (源, 目标) 或 None, dist 目录名)。"""
    if sys.platform.startswith("win"):
        engine_src = ROOT / "core/desktop/windows/out/Release"
        drivers_src = ROOT / "core/desktop/windows-drivers/out/Release"
        sources = [
            (engine_src, "auradsp_engine.dll"),
            (engine_src, "auradsp_plugin_host.exe"),
            (drivers_src, "auravm_bridge.dll"),
            (drivers_src, "auraasio_bridge.dll"),
            (drivers_src, "auravaio_bridge.dll"),
        ]
        targets = [
            ROOT / "test",
            ROOT / "app/auradsp_app/build/windows/x64/runner/Release",
            ROOT / "dist/AuraDSP-Windows-x64",
        ]
        dedicated = (engine_src / "auradsp_engine.dll",
                     drivers_src / "auradsp_engine.dll")
        return sources, targets, dedicated, "AuraDSP-Windows-x64"
    if sys.platform.startswith("linux"):
        engine_src = ROOT / "core/desktop/linux/out/Release"
        sources = [(engine_src, "libauradsp_engine.so")]
        targets = [
            ROOT / "test",
            ROOT / "app/auradsp_app/build/linux/x64/release/bundle/lib",
            ROOT / "dist/AuraDSP-Linux-x64",
        ]
        return sources, targets, None, "AuraDSP-Linux-x64"
    raise SystemExit(f"unsupported platform: {sys.platform}")


def warn(msg):
    print(f"WARNING: {msg}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="AuraDSP 产物同步（跨平台版 sync_artifacts）")
    ap.add_argument("--what-if", action="store_true",
                    help="只打印计划，不写文件")
    ap.add_argument("--pack-zip", action="store_true",
                    help="同步后重打包 dist 绿色包 zip")
    args = ap.parse_args()

    sources, targets, dedicated, dist_name = platform_layout()

    print(f"ProjectRoot: {ROOT}")
    print(f"Source files: {len(sources)} | Target endpoints: {len(targets)}")

    for src_dir, name in sources:
        p = src_dir / name
        if not p.exists():
            warn(f"Source missing (will skip): {p}")

    planned = ok = skipped = 0

    def copy_one(src: Path, dst: Path, label: str) -> None:
        nonlocal planned, ok, skipped
        planned += 1
        if not src.exists():
            skipped += 1
            warn(f"  skip (source missing): {label}")
            return
        try:
            if args.what_if:
                print(f"  [WhatIf] {src} -> {dst}")
            else:
                shutil.copy2(src, dst)
            ok += 1
            print(f"  OK  {label}")
        except OSError as e:
            skipped += 1
            warn(f"  copy failed (skip this file): {label} -> {e}")

    for tgt in targets:
        print(f"\n--- Target: {tgt}")
        if not tgt.is_dir():
            planned += len(sources)
            skipped += len(sources)
            warn(f"Target dir missing, skip whole target: {tgt}")
            continue
        for src_dir, name in sources:
            copy_one(src_dir / name, tgt / name, name)

    # 专用拷贝（Windows：engine -> drivers out；PS1 原注：2026-10-24 VM
    # 测试抓到这条拷贝静默停留在 ABI-1 旧版，真源已到 ABI 2）
    if dedicated is not None:
        src, dst = dedicated
        if src.exists() and dst.parent.is_dir():
            if args.what_if:
                planned += 1
                ok += 1
                print(f"  [WhatIf] {src} -> {dst}")
            else:
                copy_one(src, dst, "auradsp_engine.dll -> "
                                   "windows-drivers/out/Release")

    print("\n=== Sync result ===")
    print(f"Planned {planned} files | OK {ok} | Skipped {skipped}")

    if args.pack_zip and not args.what_if:
        folder = ROOT / "dist" / dist_name
        zip_path = ROOT / "dist" / f"{dist_name}.zip"
        if folder.is_dir():
            print(f"\nRe-packing release zip: {zip_path}")
            if zip_path.exists():
                zip_path.unlink()
            with zipfile.ZipFile(zip_path, "w",
                                 zipfile.ZIP_DEFLATED) as z:
                for p in sorted(folder.rglob("*")):
                    if p.is_file():
                        z.write(p, p.relative_to(folder))
            print("Done")
        else:
            warn(f"Release dir missing, skip packing: {folder}")

    if skipped > 0:
        warn("Some items were skipped; review the warnings above.")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
