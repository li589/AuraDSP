"""完整载荷布局：ASIO 本体进根 + `driver/` 恒保留。

portable / setup 的临时副本与 staging 绿色目录本体共用这一份组装，保证
三处布局逐字一致。缺资产一律 die——「三模式同口径」是细审 R-C L-6 的整改
结论，不允许某条路径悄悄少件。
"""

from __future__ import annotations

from pathlib import Path

from ..common import die
from ..paths import INSTALL_DRIVER_PS1
from .driver import find_driver_dir
from .driver_payload import copy2_overwrite, stage_driver_files
from .toolchain import ASIO_DLL_NAME, find_asio_driver, resolve_apo_assets


def complete_payload_tree(work: Path, args, *, sign_warn_only: bool = False) -> None:
    """把完整载荷布局落到 work。"""
    if not INSTALL_DRIVER_PS1.is_file():
        raise die(f"缺 install_driver.ps1: {INSTALL_DRIVER_PS1}")

    apo = resolve_apo_assets(args)
    asio = find_asio_driver(args.asio_driver)
    driver_dir = find_driver_dir(args.driver_dir)
    if asio is None:
        raise die("找不到 auraasio_driver.dll；先跑 build_windows.ps1 全量构建"
                  "（含 auraasio_driver 目标），或用 --asio-driver 指定")
    if driver_dir is None:
        raise die("找不到 VAIO 驱动产物目录（含 .sys 的目录）；"
                  "先在 Windows 构建驱动，或用 --driver-dir 指定")

    copy2_overwrite(asio, work / ASIO_DLL_NAME)
    stage_driver_files(
        work / "driver", driver_dir, asio, INSTALL_DRIVER_PS1, apo,
        include_asio_dll=True,
        sign_warn_only=sign_warn_only or getattr(
            args, "allow_unsigned_driver", False))
