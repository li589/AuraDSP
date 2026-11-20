"""Windows 打包 CLI（历史 `pack.py` 的命令行契约）。

**参数名、默认值、输出文案都不许改**：`installer/windows/tests/test_pack_fixture.py`
与 CI annotation 都按这些字符串断言。重构只能换实现，不能换契约。

main 的执行顺序也是契约的一部分：

  预检（staging 存在）→ 驱动（按需重编 → 新鲜度门）→ 逐模式打包+可选签名
  → staging 本体同步补齐（首个 portable/setup 之后）→ 可选 SHA256SUMS。
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from ..common import die, log
from ..hashing import merge_sha256sums
from ..manifest import refresh_dist_manifest
from ..naming import RESOURCE_TIERS
from ..paths import (
    DIST_DIR,
    PACKS_DIR,
    RESOURCE_PIPELINE,
    ROOT,
    STAGING_DIR,
)
from ..staging import check_staging
from ..version import resolve_version
from .driver import build_driver, check_driver_freshness, find_driver_dir
from .installer_build import build_staging
from .modes import MODE_FUNCS
from .payload import complete_payload_tree
from .setup_image import verify as verify_setup
from .signing import sign_file


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="AuraDSP Windows 发行打包（driver/portable/setup）")
    ap.add_argument("--mode", default="all",
                    help="driver,portable,setup,staging 或 all（逗号分隔）")
    ap.add_argument("--resources", default="core", choices=RESOURCE_TIERS)
    ap.add_argument("--rebuild-resource-packs", action="store_true")
    ap.add_argument("--packs-dir", type=Path, default=PACKS_DIR)
    ap.add_argument("--staging", type=Path, default=STAGING_DIR)
    ap.add_argument("--build-staging", action="store_true")
    ap.add_argument("--build-type", default="Release", choices=("Release", "Debug"))
    ap.add_argument("--skip-drivers", action="store_true",
                    help="透传 build_windows.ps1 -SkipDrivers")
    ap.add_argument("--allow-unsigned-driver", action="store_true",
                    help="签名门降级为警告（仅供 pack fixture 测试用假驱动；"
                         "发行打包严禁使用）")
    ap.add_argument("--build-driver", action="store_true",
                    help="打包前重编并测试签名 VAIO 驱动（默认只做新鲜度校验）")
    ap.add_argument("--driver-dir")
    ap.add_argument("--asio-driver")
    ap.add_argument("--apo-inspect")
    ap.add_argument("--apo-config")
    ap.add_argument("--apo-dll")
    ap.add_argument("--apo-engine")
    ap.add_argument("--installer-build-dir")
    ap.add_argument("--build-installer", action="store_true")
    ap.add_argument("--version")
    ap.add_argument("--out", type=Path, default=DIST_DIR)
    ap.add_argument("--zip-level", type=int, default=6)
    ap.add_argument("--sign", action="store_true")
    ap.add_argument("--signtool", default="signtool.exe")
    ap.add_argument("--cert-thumbprint")
    ap.add_argument("--sha256sums", action="store_true")
    ap.add_argument("--clean", action="store_true")
    ap.add_argument("--what-if", action="store_true")
    ap.add_argument("--verify", type=Path,
                    help="校验已生成的 Setup exe 后退出")
    return ap.parse_args(argv)


def _resolve_modes(raw: str) -> list[str]:
    if raw == "all":
        return ["driver", "portable", "setup"]
    return [m.strip() for m in raw.split(",") if m.strip()]


def _run_driver_gates(args, modes: list[str]) -> None:
    """VAIO 驱动：按需重编 → 新鲜度校验 → 不新鲜就中止。

    驱动不在 build_windows.ps1 的目标集里，所以「谁上次编的就是什么」；
    不加这道校验，包可能装着比源码旧的驱动。staging 是开发测试向的就地
    补齐，陈旧只警告；driver/setup 两条发行路径必须拒绝。
    """
    if modes == ["staging"]:
        ddir = find_driver_dir(args.driver_dir)
        if ddir is not None:
            for problem in check_driver_freshness(ddir):
                log(f"警告: {problem}（staging 不拦截；发行打包仍会拒绝）")

    if "driver" not in modes and "setup" not in modes:
        return
    if args.build_driver and not args.what_if:
        build_driver()
    ddir = find_driver_dir(args.driver_dir)
    if ddir is None:
        return
    problems = check_driver_freshness(ddir)
    if problems:
        raise die(
            "VAIO 驱动产物比源码旧，拒绝打包（避免发出与源码不符的驱动）：\n  - "
            + "\n  - ".join(problems)
            + "\n  修法：加 --build-driver 自动重编并签名；或先跑 "
              "core/desktop/windows-drivers/01_vaio_driver/build_drivers.ps1 "
              "-Track modern -Config Release")
    log(f"驱动新鲜度校验通过: {ddir}")


def _complete_staging_once(args, done: list[bool]) -> None:
    """首个 portable/setup 完成后，把 dist 绿色目录本体同步补齐。

    用户口径（2026-11-10）：dist 的每个产出都完整——直接开文件夹即可测，
    不必先解压刚打出的便携包。
    """
    if done[0]:
        return
    complete_payload_tree(args.staging, args)
    refresh_dist_manifest(args.staging)
    done[0] = True
    log(f"staging 文件夹已同步补齐: {args.staging}")


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if args.verify:
        return 0 if verify_setup(args.verify) else 1

    ver = resolve_version(args.version)
    modes = _resolve_modes(args.mode)
    log(f"版本 {ver['AURADSP_VERSION']}（{ver['AURADSP_TAG']}），模式 {modes}，"
        f"资源 {args.resources}")

    if args.build_staging and not args.what_if:
        build_staging(args)
    if args.rebuild_resource_packs and not args.what_if:
        log("重建资源包（build_packages.py）…")
        subprocess.run([sys.executable, str(RESOURCE_PIPELINE)],
                       check=True, cwd=ROOT)
    if modes != ["driver"]:  # driver 模式不需要 staging
        check_staging(args.staging)

    _run_driver_gates(args, modes)

    out: Path = args.out
    if not args.what_if:
        out.mkdir(parents=True, exist_ok=True)

    produced: list[Path] = []
    staging_completed = [False]
    for mode in modes:
        fn = MODE_FUNCS.get(mode)
        if fn is None:
            raise die(f"未知模式: {mode}（可选 {', '.join(MODE_FUNCS)} 或 all）")
        dest = fn(args, ver, out)
        produced.append(dest)
        if not args.what_if and dest.is_file():
            sign_file(args, dest)
        if not args.what_if and mode in ("portable", "setup"):
            _complete_staging_once(args, staging_completed)

    if args.sha256sums and not args.what_if and produced:
        n = merge_sha256sums(out / "SHA256SUMS.txt", produced)
        log(f"SHA256SUMS.txt 已更新（{n} 条）")

    log("完成")
    return 0
