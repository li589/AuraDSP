#!/usr/bin/env python3
# merge_resources.py — 双平台资源合并入口（资源计划 P1，2026-11-12）。
#
# 合并逻辑只有一份：installer/packkit/resources.py 的 apply_resources
# （档位语义、SHA256SUMS 对账门、user_data 隔离、路径穿越防护、
# finalize 收尾都在其中）。Windows 打包由 packkit 进程内直调；
# Linux 的 pack.sh 经本脚本调同一实现，避免两平台各写一份合并
# 逻辑后口径漂移。
#
# 2026-11-20：实现从 installer/windows/pack.py 迁到 installer/packkit/，
# 本脚本改为直接 import 内核（不再把 pack.py 当模块加载——pack.py 已
# 降为 CLI 薄壳，不含实现）。
#
# 用法：
#   merge_resources.py --staging <bundle副本目录> \
#       --resources core|full|light|addons|none \
#       [--packs-dir dist/resources]
#
# staging 必须是可写副本（pack.sh 会先把 bundle 拷到临时目录），
# 本脚本原地加工 staging/resources/。
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_INSTALLER = ROOT / "installer"
if str(_INSTALLER) not in sys.path:
    sys.path.insert(0, str(_INSTALLER))

from packkit.resources import apply_resources  # noqa: E402  (需先注入 sys.path)


def main() -> int:
    ap = argparse.ArgumentParser(description="AuraDSP 资源合并（与 packkit 同一实现）")
    ap.add_argument("--staging", type=Path, required=True,
                    help="bundle 副本目录（原地加工其 resources/）")
    ap.add_argument("--resources", default="core",
                    choices=("core", "full", "light", "addons", "none"))
    ap.add_argument("--packs-dir", type=Path,
                    default=ROOT / "dist" / "resources")
    args = ap.parse_args()

    apply_resources(args.staging, args.resources, args.packs_dir, False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
