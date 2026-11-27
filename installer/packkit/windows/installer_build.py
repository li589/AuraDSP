"""安装器子项目构建联动（引导壳 + Flutter 向导）与 staging 全量构建。

这两个动作都只能在 Windows 上跑：引导壳需要 MSVC，向导需要
`flutter build windows`，staging 需要 `build_windows.ps1`。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from ..common import die, log
from .signing import resolve_signer_thumbprint
from ..paths import (
    BOOTSTRAPPER_SRC,
    BUILD_DIR,
    BUILD_WINDOWS_PS1,
    ENV_SANITIZER,
    INSTALLER_BUILD_DIR,
    ROOT,
    WIZARD_DIR,
)


def installer_configure_args(args) -> list[str]:
    configure = ["cmake", "-S", str(BOOTSTRAPPER_SRC),
                 "-B", str(BUILD_DIR / "installer" / "bootstrapper"),
                 "-A", "x64"]
    publisher_thumb = resolve_signer_thumbprint(args)
    unsigned_test = os.environ.get("AURADSP_SETUP_UNSIGNED_TEST_ONLY") == "1"
    if unsigned_test and publisher_thumb:
        raise die("AURADSP_SETUP_UNSIGNED_TEST_ONLY 不得与发布者指纹同时启用")
    if publisher_thumb:
        configure.append(f"-DAURADSP_PUBLISHER_THUMBPRINT={publisher_thumb}")
    configure.append(
        "-DAURADSP_SETUP_UNSIGNED_TEST_ONLY=" + ("ON" if unsigned_test else "OFF")
    )
    if unsigned_test:
        log("警告: 显式构建未签名测试 Setup；仅限本地测试，生产默认仍失败关闭")
    return configure


def build_installer_artifacts(args) -> Path:
    """--build-installer：构建引导壳与向导，汇集到 build/installer/dist。"""
    if os.name != "nt":
        raise die("--build-installer 只能在 Windows 上执行"
                  "（引导壳需 MSVC、向导需 flutter build windows）")
    dist = INSTALLER_BUILD_DIR
    boot_build = BUILD_DIR / "installer" / "bootstrapper"

    log("构建引导壳（cmake）…")
    configure = installer_configure_args(args)
    subprocess.run(configure, check=True)
    subprocess.run(["cmake", "--build", str(boot_build), "--config", "Release"],
                   check=True)
    shell = boot_build / "Release" / "bootstrapper.exe"
    if not shell.is_file():
        raise die(f"引导壳构建完成但产物缺失: {shell}")

    log("构建向导（flutter build windows）…")
    # 经 win_env_sanitize 启动：Windows 上 flutter 是 .bat 垫片，subprocess
    # 直接 spawn 批处理会 FileNotFoundError（CreateProcess 只补 .exe）；同时
    # 该脚本归一化环境变量大小写重复键——否则 MSBuild 会因
    # ArgumentException('path') 起不来编译器，编译"成功"却产出陈旧二进制。
    subprocess.run([sys.executable, str(ENV_SANITIZER), "flutter", "build",
                    "windows", "--release", "--no-tree-shake-icons"],
                   cwd=WIZARD_DIR, check=True)

    runner = WIZARD_DIR / "build" / "windows" / "x64" / "runner" / "Release"
    if not (runner / "auradsp_setup.exe").is_file():
        raise die(f"向导构建完成但产物缺失: {runner}")

    if dist.exists():
        shutil.rmtree(dist)
    (dist / "wizard").mkdir(parents=True)
    shutil.copy2(shell, dist / "bootstrapper.exe")
    shutil.copytree(runner, dist / "wizard", dirs_exist_ok=True)
    log(f"installer 构建汇集完成: {dist}")
    return dist


def resolve_installer_dir(args) -> Path:
    if args.build_installer:
        return build_installer_artifacts(args)
    p = Path(args.installer_build_dir) if args.installer_build_dir else INSTALLER_BUILD_DIR
    if not (p / "bootstrapper.exe").is_file() or not (p / "wizard").is_dir():
        raise die(f"installer 构建目录不完整（需 bootstrapper.exe + wizard/）: {p}"
                  "；先 --build-installer 或用 --installer-build-dir 指定")
    return p


def build_staging(args) -> None:
    """透传 build_windows.ps1 做全量构建（引擎/桥/ASIO/App → dist）。"""
    if os.name != "nt":
        raise die("--build-staging 只能在 Windows 上执行（build_windows.ps1）")
    cmd = ["powershell", "-ExecutionPolicy", "Bypass", "-File",
           str(BUILD_WINDOWS_PS1), "-BuildType", args.build_type]
    if args.skip_drivers:
        cmd.append("-SkipDrivers")
    log(f"构建 staging: {' '.join(cmd)}")
    subprocess.run(cmd, check=True, cwd=ROOT)


def installer_dir_status(path: Path | None = None) -> str:
    p = path or INSTALLER_BUILD_DIR
    if (p / "bootstrapper.exe").is_file() and (p / "wizard").is_dir():
        return "就绪"
    return "缺失（需 --build-installer）"
