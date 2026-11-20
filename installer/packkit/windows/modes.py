"""Windows 四个打包模式：driver / portable / setup / staging。

模式只负责「把输入变成一件产物」，门禁判定留在 `cli.py` 的 main 流程里
（那里是唯一能同时看到全部模式、决定拦截还是降级的地方）。
"""

from __future__ import annotations

import hashlib
import tempfile
from pathlib import Path

from ..archives import zip_dir
from ..common import die, log
from ..defaults import apply_defaults
from ..manifest import refresh_dist_manifest
from ..naming import ArtifactNames
from ..paths import INSTALL_DRIVER_PS1
from ..staging import prepare_staging_copy
from .driver import find_driver_dir
from .driver_payload import stage_driver_files
from .installer_build import resolve_installer_dir
from .payload import complete_payload_tree
from .setup_image import assemble, build_wizard_zip
from .toolchain import find_asio_driver, resolve_apo_assets


def mode_driver(args, ver: dict[str, str], out: Path) -> Path:
    names = ArtifactNames(ver["AURADSP_TAG"])
    driver_dir = find_driver_dir(args.driver_dir)
    asio = find_asio_driver(args.asio_driver)
    if driver_dir is None:
        raise die("找不到 VAIO 驱动产物目录（含 .sys 的目录）；"
                  "先在 Windows 构建驱动，或用 --driver-dir 指定")
    if asio is None:
        raise die("找不到 auraasio_driver.dll；先跑 build_windows.ps1 全量构建"
                  "（含 auraasio_driver 目标），或用 --asio-driver 指定")
    if not INSTALL_DRIVER_PS1.is_file():
        raise die(f"缺 install_driver.ps1: {INSTALL_DRIVER_PS1}")

    apo = resolve_apo_assets(args)
    dest = out / names.build("driver")
    if args.what_if:
        log(f"what-if: driver 包 ← {driver_dir} + {INSTALL_DRIVER_PS1.name} + {asio}")
        return dest

    with tempfile.TemporaryDirectory(prefix="auradsp-driver-") as td:
        stage = Path(td) / "driver"
        stage_driver_files(
            stage, driver_dir, asio, INSTALL_DRIVER_PS1, apo,
            include_asio_dll=True,
            sign_warn_only=getattr(args, "allow_unsigned_driver", False))
        n = zip_dir(stage, dest, args.zip_level)
    log(f"driver: {dest.name}（{n} 条目，{dest.stat().st_size / 1e6:.1f} MB）")
    return dest


def mode_portable(args, ver: dict[str, str], out: Path) -> Path:
    names = ArtifactNames(ver["AURADSP_TAG"])
    dest = out / names.build("portable")
    # 资产校验前置到 what-if 之前（细审 R-C L-6）：--what-if 预检也要报
    # 缺资产，与 driver 模式同口径；组装时复用。
    if not INSTALL_DRIVER_PS1.is_file():
        raise die(f"缺 install_driver.ps1: {INSTALL_DRIVER_PS1}")
    resolve_apo_assets(args)
    if args.what_if:
        log(f"what-if: portable 包 ← {args.staging}（resources={args.resources}）")
        return dest

    td, work = prepare_staging_copy(args)
    with td:
        # 与 setup 载荷同布局：ASIO 本体进根 + driver/ 恒保留。便携与安装
        # 跑同一个 app，缺 driver/ 时 VAIO/ASIO/APO 面板找不到随包工具
        # （真机报告 2026-11-09：便携包无 apo_config.exe）。
        complete_payload_tree(work, args)
        n = zip_dir(work, dest, args.zip_level)
    log(f"portable: {dest.name}（{n} 条目，{dest.stat().st_size / 1e6:.1f} MB）")
    return dest


def mode_staging(args, ver: dict[str, str], out: Path) -> Path:
    """就地补齐 staging 文件夹本体（dist 绿色目录）。

    该文件夹既是打包输入、也是日常测试入口：此前 driver/ 只进 zip/安装
    载荷的临时副本，文件夹本体恒缺，测驱动面板必须先解压便携包（用户
    2026-11-10 报告）。build_windows.ps1 Step 5 亦调用本模式。
    """
    complete_payload_tree(args.staging, args, sign_warn_only=True)
    apply_defaults(args.staging, args.what_if)
    refresh_dist_manifest(args.staging)
    log(f"staging: {args.staging} 已补齐（根 ASIO + driver/），"
        "可直接打开文件夹运行测试")
    return args.staging


def mode_setup(args, ver: dict[str, str], out: Path) -> Path:
    names = ArtifactNames(ver["AURADSP_TAG"])
    dest = out / names.build("setup")

    asio = find_asio_driver(args.asio_driver)
    if asio is None:
        raise die("setup 模式必须有 auraasio_driver.dll；先跑 build_windows.ps1 "
                  "全量构建（含 auraasio_driver 目标），或用 --asio-driver 指定")
    driver_dir = find_driver_dir(args.driver_dir)
    if driver_dir is None:
        raise die("setup 模式必须有 VAIO 驱动产物（payload 的 driver/ 子目录）；"
                  "用 --driver-dir 指定")
    inst_dir = resolve_installer_dir(args)
    # 资产校验前置到 what-if 之前（细审 R-C L-6，同 portable）。
    if not INSTALL_DRIVER_PS1.is_file():
        raise die(f"缺 install_driver.ps1: {INSTALL_DRIVER_PS1}")
    resolve_apo_assets(args)
    if args.what_if:
        log(f"what-if: setup ← shell {inst_dir} + staging {args.staging} "
            f"+ asio {asio} + driver {driver_dir}")
        return dest

    td, work = prepare_staging_copy(args)
    with td:
        # 载荷增补：ASIO 驱动本体（安装目录根，供 FFI 注册）+ driver/ 子目录
        # （恒保留，含手动安装脚本、驱动与签名说明）。
        complete_payload_tree(work, args)

        payload_zip = Path(td.name) / "payload.zip"
        zip_dir(work, payload_zip, args.zip_level, arc_prefix="payload/")
        payload_bytes = payload_zip.read_bytes()
        payload_sha = hashlib.sha256(payload_bytes).hexdigest()

        wizard_zip = Path(td.name) / "wizard.zip"
        build_wizard_zip(inst_dir / "wizard", wizard_zip, ver, payload_sha)
        wizard_bytes = wizard_zip.read_bytes()
        shell_bytes = (inst_dir / "bootstrapper.exe").read_bytes()

        assemble(dest, shell_bytes, wizard_bytes, payload_bytes)

    log(f"setup: {dest.name}（{dest.stat().st_size / 1e6:.1f} MB，"
        f"payload sha256 {payload_sha[:12]}…）")
    return dest


MODE_FUNCS = {
    "driver": mode_driver,
    "portable": mode_portable,
    "setup": mode_setup,
    "staging": mode_staging,
}
