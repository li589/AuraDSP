"""Linux 打包 CLI（与历史 `pack.sh` 参数逐一对应）。

参数兼容是硬要求：README、CI 与排障手册里写的都是 `pack.sh --build`
`--only deb,driver` 这类命令行，收编实现不能改调用方式。因此
`installer/linux/pack.sh` 保留为转发壳，`--help` 文案也照抄原注释。

新增两个原有 Windows 侧具备、Linux 侧缺失的能力（不改变旧参数语义）：

  --what-if   只推演清单与路径，不落任何产物（release.py --dry-run 用）
  --version   覆盖版本号（格式 vXX.XX.X 校验，同 pack.py）
"""

from __future__ import annotations

import argparse
from pathlib import Path

from ..common import log, reconfigure_streams
from ..naming import LINUX_MODES, RESOURCE_TIERS
from ..paths import (
    DIST_DIR,
    LINUX_BUNDLE,
    LINUX_RESERVED_MANIFESTS,
    PACKS_DIR,
    ROOT,
)
from ..version import resolve_version
from . import build as build_mod
from . import bundle as bundle_mod
from . import modes


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="pack.py (linux)",
        description="AuraDSP Linux 打包入口（产物构成见 installer/docs/03 §5）")
    ap.add_argument("--build", action="store_true",
                    help="先一键构建（引擎 → Flutter bundle → sync）再打包")
    ap.add_argument("--bundle", type=Path, default=LINUX_BUNDLE,
                    help="Flutter Linux bundle 目录")
    ap.add_argument("--out", type=Path, default=DIST_DIR, help="产物输出目录")
    ap.add_argument("--only", default="",
                    help=f"只产指定模式，逗号分隔（可选 {','.join(LINUX_MODES)}）")
    ap.add_argument("--resources", default="core", choices=RESOURCE_TIERS,
                    help="资源档位（与 Windows 同名同义）")
    ap.add_argument("--packs-dir", type=Path, default=PACKS_DIR,
                    help="资源包目录（默认 dist/resources）")
    ap.add_argument("--version", dest="version_override",
                    help="覆盖版本号（vXX.XX.X）")
    ap.add_argument("--what-if", action="store_true",
                    help="只推演，不复制/不合并/不打包")
    return ap.parse_args(argv)


def _check_reserved() -> None:
    for manifest in LINUX_RESERVED_MANIFESTS:
        rel = manifest.relative_to(ROOT)
        if manifest.is_file():
            log(f"reserved manifest ok: {rel}")
        else:
            log(f"警告: 预留清单缺失: {manifest}")


def main(argv: list[str]) -> int:
    reconfigure_streams()
    args = parse_args(argv)

    ver = resolve_version(args.version_override)
    version, tag = ver["AURADSP_VERSION"], ver["AURADSP_TAG"]
    log(f"AuraDSP Linux packaging — version {version} (tag {tag})")

    selected = modes.parse_only(args.only)

    if args.build and not args.what_if:
        build_mod.build_linux()

    with bundle_mod.staged_bundle(args.bundle, args.out, args.resources,
                                  args.packs_dir, args.what_if) as work:
        if args.what_if:
            log(f"what-if: 将产出 {', '.join(selected)}（档位 {args.resources}）")
            _check_reserved()
            return 0
        result = modes.run(selected, work, version, tag, args.out)

    _check_reserved()

    print(f"\ndone. artifacts in {args.out}:")
    if not result.artifacts:
        print("  （本次未选中任何模式）")
    for mode in LINUX_MODES:
        p = result.artifacts.get(mode)
        if p is not None:
            print(f"  {p.name}  ({p.stat().st_size / 1e6:.1f} MB)")
    return 0
