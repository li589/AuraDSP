"""VAIO 驱动域：产物发现、新鲜度门、按需重编。

为什么需要新鲜度门：VAIO 驱动**不在** build_windows.ps1 的目标集里（那里
只编引擎/桥/ASIO），打包器只搬 `modern/x64/Release/AuraVaioDriver` 的现成
产物。于是「谁上次编的就是什么」——源码改了、包里还是旧驱动。实测踩过：
源码含 11-08 的 ControlDevice.cpp 改动（调试日志权限加固），发出去的驱动
仍是 11-05 的构建（sha256 都不一致）。这类「二进制与源码不符」最难发现：
包能装能用，只是没有新改动。
"""

from __future__ import annotations

import subprocess
import time
from pathlib import Path

from ..common import die, log
from ..paths import DRIVER_SRC_ROOT

# 驱动产物规范名（WDK 工程实际输出，modern/x64/Release/AuraVaioDriver/）。
# 旧名 AuraVaio.* 会让新鲜度门误报「产物缺失」（2026-11-09 CI 实锤）。
DRIVER_SYS_NAME = "AuraVaioDriver.sys"
DRIVER_CAT_NAME = "auravaiodriver.cat"
DRIVER_INF_NAME = "AuraVaioDriver.inf"
DRIVER_CER_NAME = "AuraDSP_TestSign.cer"
DRIVER_PAYLOAD_SUFFIXES = (".sys", ".inf", ".cat", ".cer")


def find_driver_dir(explicit: str | None) -> Path | None:
    """定位 VAIO 驱动构建产物目录（含 .sys/.inf/.cat 的目录）。

    多份候选时取「文件类型最全（sys+inf+cat 齐备）且最新」的那份——构建
    树里常同时存在裸输出目录与打包目录，只有后者才带 .cat。
    """
    if explicit:
        p = Path(explicit)
        return p if p.is_dir() else None
    candidates: list[Path] = []
    for sysfile in DRIVER_SRC_ROOT.rglob("*.sys"):
        if "legacy" not in sysfile.parts:  # legacy 驱动不进发行包
            candidates.append(sysfile.parent)
    if not candidates:
        return None

    def score(d: Path) -> tuple[int, float]:
        kinds = {e.suffix.lower() for e in d.iterdir() if e.is_file()}
        return (len(kinds & {".sys", ".inf", ".cat"}), max(
            (e.stat().st_mtime for e in d.iterdir() if e.is_file()), default=0))

    return max(candidates, key=score)


def driver_source_files() -> list[Path]:
    """驱动相关的全部输入（源码 + IPC 头 + inf + 工程文件）。"""
    out: list[Path] = []
    for pat in ("src/**/*.cpp", "src/**/*.h", "src/*.inf"):
        out.extend(DRIVER_SRC_ROOT.glob(pat))
    out.extend((DRIVER_SRC_ROOT.parent / "common").glob("*.h"))
    out.extend(DRIVER_SRC_ROOT.glob("modern/*.vcxproj"))
    return [p for p in out if p.is_file()]


def check_driver_freshness(driver_dir: Path) -> list[str]:
    """返回「产物比源码旧」的问题列表；空列表表示新鲜。"""
    problems: list[str] = []
    products = [driver_dir / DRIVER_SYS_NAME, driver_dir / DRIVER_CAT_NAME]
    missing = [p.name for p in products if not p.is_file()]
    if missing:
        return [f"驱动产物缺失: {', '.join(missing)}"]

    oldest_product = min(p.stat().st_mtime for p in products)
    newer: list[Path] = []
    for src in driver_source_files():
        try:
            if src.stat().st_mtime > oldest_product + 1:
                newer.append(src)
        except OSError:
            continue
    if newer:
        from ..paths import ROOT

        rel = sorted(str(p.relative_to(ROOT)) for p in newer)
        problems.append(
            f"驱动产物({oldest_product and products[0].name} "
            f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(oldest_product))}) "
            f"早于 {len(newer)} 个源文件：{', '.join(rel[:6])}"
            + (" …" if len(rel) > 6 else ""))
    return problems


def build_driver(track: str = "modern", config: str = "Release") -> None:
    """按需重编 + 测试签名 VAIO 驱动（内核驱动只能用 signtool 签）。

    全面复审 S5b（2026-11-11 实测事故）：build_drivers.ps1 曾不向外传播
    MSBuild 退出码（powershell -File 默认 exit 0），check=True 形同虚设；
    随后 sign_drivers.ps1 给旧 .sys 重签名刷新了 mtime，纯 mtime 口径的
    新鲜度门被「洗绿」，pack 以退出码 0 发出了源码不符的旧驱动。脚本侧已
    修退出码传播；这里再加一条与签名无关的硬断言：构建脚本跑完后 .sys
    必须被本次构建实际重写（mtime 不早于构建开始），否则中止。
    """
    ddir = find_driver_dir(None)
    sys_path = (ddir / DRIVER_SYS_NAME) if ddir else None
    build_started = time.time()

    for script, argv in (
        ("build_drivers.ps1", ["-Track", track, "-Config", config]),
        ("sign_drivers.ps1", []),
    ):
        p = DRIVER_SRC_ROOT / script
        if not p.is_file():
            raise die(f"缺少驱动构建脚本: {p}")
        log(f"驱动构建: {script} {' '.join(argv)}")
        subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(p)] + argv,
            check=True, cwd=str(DRIVER_SRC_ROOT))
        if script == "build_drivers.ps1":
            if sys_path is None or not sys_path.is_file():
                raise die("驱动构建后未找到 AuraVaioDriver.sys，中止打包")
            if sys_path.stat().st_mtime < build_started - 2:
                raise die(
                    "驱动构建脚本报告成功，但 AuraVaioDriver.sys 未被重写"
                    "（仍是旧构建）——拒绝继续打包，避免发出与源码不符的驱动")


def describe(driver_dir: Path | None) -> str:
    """给发布预检表用的一行状态。"""
    if driver_dir is None:
        return "缺失"
    problems = check_driver_freshness(driver_dir)
    if problems:
        return f"陈旧（{problems[0][:60]}…）"
    sysf = driver_dir / DRIVER_SYS_NAME
    stamp = time.strftime("%m-%d %H:%M", time.localtime(sysf.stat().st_mtime))
    return f"就绪（{stamp}）"
