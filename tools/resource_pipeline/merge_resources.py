#!/usr/bin/env python3
# merge_resources.py — 双平台资源合并入口（资源计划 P1，2026-11-12）。
#
# 合并逻辑只有一份：installer/windows/pack.py 的 apply_resources
# （档位语义、SHA256SUMS 对账门、user_data 隔离、路径穿越防护、
# finalize 收尾都在其中）。Windows 打包由 pack.py 进程内直调；
# Linux 的 pack.sh 经本脚本调同一实现，避免两平台各写一份合并
# 逻辑后口径漂移。
#
# 用法：
#   merge_resources.py --staging <bundle副本目录> \
#       --resources core|full|light|addons|none \
#       [--packs-dir dist/resources]
#
# staging 必须是可写副本（pack.sh 会先把 bundle 拷到临时目录），
# 本脚本原地加工 staging/resources/。
import argparse
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    ap = argparse.ArgumentParser(description="AuraDSP 资源合并（与 pack.py 同一实现）")
    ap.add_argument("--staging", type=Path, required=True,
                    help="bundle 副本目录（原地加工其 resources/）")
    ap.add_argument("--resources", default="core",
                    choices=("core", "full", "light", "addons", "none"))
    ap.add_argument("--packs-dir", type=Path,
                    default=ROOT / "dist" / "resources")
    args = ap.parse_args()

    spec = importlib.util.spec_from_file_location(
        "auradsp_pack", ROOT / "installer" / "windows" / "pack.py")
    pack = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pack)
    pack.apply_resources(args.staging, args.resources, args.packs_dir, False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
