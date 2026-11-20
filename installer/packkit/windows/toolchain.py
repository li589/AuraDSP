"""原生构建产物发现（ASIO 驱动、APO 四件、引擎产物）。

这里是「打包器怎么在构建树里找到该打进去的二进制」的唯一实现。所有
查找都遵循同一优先级：**显式参数 > 标准输出目录 > 递归找最新**，且都
返回 None 而不抛异常，由调用方决定缺件是否致命——driver 与 setup 对
资产的要求不同（setup 必须齐四件，driver 包同样齐，portable 亦然）。
"""

from __future__ import annotations

from pathlib import Path
from typing import NamedTuple

from ..common import die
from ..paths import BRIDGES_OUT, DRIVERS_ROOT, ENGINE_OUT

# ASIO 驱动 DLL 的规范文件名（ADR-008：CMake 目标 auraasio_driver 的产物
# 名即文件名，驱动侧 register_driver.ps1 与冒烟门均以此为准）。
# AuraAsioDriver.dll 是早期安装器口径的别名，仅作兼容发现/输入，进入
# 产物时一律归一化为规范名。
ASIO_DLL_NAME = "auraasio_driver.dll"
ASIO_DLL_ALIASES = (ASIO_DLL_NAME, "AuraAsioDriver.dll")


def find_asio_driver(explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    for name in ASIO_DLL_ALIASES:
        hits = [p for p in DRIVERS_ROOT.rglob(name)]
        if hits:
            return max(hits, key=lambda p: p.stat().st_mtime)
    return None


def find_built(name: str, explicit: str | None) -> Path | None:
    """在 windows-drivers 构建产物（out/<Config>）中定位单个文件。"""
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    for cfg in ("Release", "Debug"):
        p = BRIDGES_OUT / cfg / name
        if p.is_file():
            return p
    if BRIDGES_OUT.is_dir():
        hits = [p for p in BRIDGES_OUT.rglob(name)]
        if hits:
            return max(hits, key=lambda p: p.stat().st_mtime)
    return None


def find_engine_apo(explicit: str | None) -> Path | None:
    """APO 纪律版引擎 auradsp_engine_apo.dll（windows 引擎产物目录）。"""
    name = "auradsp_engine_apo.dll"
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    for cfg in ("Release", "Debug"):
        p = ENGINE_OUT / cfg / name
        if p.is_file():
            return p
    if ENGINE_OUT.is_dir():
        hits = [p for p in ENGINE_OUT.rglob(name)]
        if hits:
            return max(hits, key=lambda p: p.stat().st_mtime)
    return None


def find_apo_inspect(explicit: str | None) -> Path | None:
    """端点探测工具 apo_inspect.exe。

    app 的设备刷新链靠它枚举 WASAPI 端点：缺了它安装版点刷新静默无效
    （真机报告 V-02 关联项），故列为随包必备。
    """
    return find_built("apo_inspect.exe", explicit)


class ApoAssets(NamedTuple):
    """APO 运维资产四件（同组进 driver/）。"""

    config_exe: Path   # apo_config.exe：原生移植版（§2.3 方案 A）
    apo_dll: Path      # AuraApo.dll：APO 本体（此前从未随包，附加必败）
    inspect: Path      # apo_inspect.exe：端点枚举
    engine_dll: Path   # auradsp_engine_apo.dll：真处理引擎纪律版


def resolve_apo_assets(args) -> ApoAssets:
    """APO 资产：脚本（仓库）+ 构建产物（windows-drivers / windows out）。

    app 侧 System APO 附加/状态查询与设备刷新都依赖它们；历史上从未进过
    载荷（真机报告 V-03 首因），自 2026-11-09 F4 起同组装。无 DLL 时脚本
    与工具在安装布局里无对象可挂，附加必然不生效——所以缺件即拒绝。
    """
    apo_inspect = find_apo_inspect(args.apo_inspect)
    if apo_inspect is None:
        raise die("找不到 apo_inspect.exe；先构建 windows-drivers 目标"
                  "（build_windows.ps1 含 apo_inspect 目标），"
                  "或用 --apo-inspect 指定")
    config_exe = find_built("apo_config.exe", args.apo_config)
    if config_exe is None:
        raise die("找不到 apo_config.exe；先构建 windows-drivers 目标"
                  "（含 apo_config 目标），或用 --apo-config 指定")
    apo_dll = find_built("AuraApo.dll", args.apo_dll)
    if apo_dll is None:
        raise die("找不到 AuraApo.dll；先构建 windows-drivers 目标"
                  "（含 AuraApo 目标），或用 --apo-dll 指定")
    engine_dll = find_engine_apo(args.apo_engine)
    if engine_dll is None:
        raise die("找不到 auradsp_engine_apo.dll；先构建 windows 引擎"
                  "目标（含 auradsp_engine_apo 目标，J5 同款），"
                  "或用 --apo-engine 指定")
    return ApoAssets(config_exe, apo_dll, apo_inspect, engine_dll)


def describe_apo(apo: ApoAssets) -> str:
    return (f"apo_config={apo.config_exe.name} apo={apo.apo_dll.name} "
            f"inspect={apo.inspect.name} engine={apo.engine_dll.name}")
