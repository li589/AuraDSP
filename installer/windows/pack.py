#!/usr/bin/env python3
"""AuraDSP Windows 发行打包入口（实施设计：docs/20-执行/Windows安装程序
与打包脚本实施设计-2026-11-06.md §6）。

一个脚本产出 Windows 完整发行的三件（可任意组合）：

  driver   AuraDSP-Driver-x64-v<ver>.zip
           VAIO 驱动全套 + install_driver.ps1 + auraasio_driver.dll
           + register_asio.ps1（生成的注册/反注册脚本）
  portable AuraDSP-Windows-x64-v<ver>.zip
           staging 整目录（按 --resources 策略加工）+ build-info 刷新
  setup    AuraDSP-Setup-x64-v<ver>.exe
           引导壳 PE + ZIP-W（向导运行时）+ ZIP-P（产品载荷）
           + 80B 尾块（magic/偏移/SHA256@载荷），--verify 可自检
  staging  就地补齐 staging 文件夹（dist/AuraDSP-Windows-x64）：
           根 ASIO + driver/ 与便携/安装载荷同布局，使 dist 的
           文件夹产出本身即可直接打开运行测试（不必解压便携
           包）；portable/setup 完成后亦自动对 staging 本体
           执行同一补齐——dist 的每个产出都完整（用户口径）。

资源策略（--resources）：
  core   staging 自带资源原样
  full   合并 dist/resources/auradsp-resource-full.zip 覆盖 resources/
         （标准发行包档位，资源计划 P1 / 业主 Q2 裁定）
  light  轻量发行包：合并 resource-core + addon-headphone-ddc——
         全类别齐全，卷积只用 core 轻档，脚本/VDC 全量（Q2 裁定）
  addons 依次合并 resource-core → resource-full → 全部 addon 包
  none   剔除 resources（保留 manifest.json 与占位说明）
非 none 档位在合并后统一生成 resources/builtin_dirs.json（内置
目录登记，App 侧 P2 消费）并补齐 plugins/{clap,vst2,vst3} 空占位。
合并在 staging 的临时副本上进行，不污染原 staging；资源包根即
resources 内容布局（build_packages.py 口径，覆盖幂等）。

版本：installer/shared/version_resolver.py（pubspec 真相源 + 格式
校验）；--version 可覆盖（仍校验）。逻辑层与平台无关，可在任意
系统以 fixture staging 自测（installer/windows/tests/）。
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import NamedTuple

# Windows 上标准流默认走本地代码页（如 en-US 的 cp1252），print 中文
# 日志会直接 UnicodeEncodeError 崩溃（windows-installer CI 实测踩中；
# zh-CN 机器是 cp936 能过，所以本地从不暴露）。一律重配为 UTF-8。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

ROOT = Path(__file__).resolve().parents[2]
FOOTER_MAGIC = b"AURASTP1"
FOOTER_FMT = "<8sIIQQQQ32s"  # magic, fmtVer, flags, offW, lenW, offP, lenP, sha256P
FOOTER_SIZE = struct.calcsize(FOOTER_FMT)
assert FOOTER_SIZE == 80, FOOTER_SIZE


def log(msg: str) -> None:
    print(f"[pack] {msg}")


def die(msg: str) -> "SystemExit":
    return SystemExit(f"[pack] error: {msg}")


# ---------------------------------------------------------------------------
# 版本
# ---------------------------------------------------------------------------

def load_resolver():
    path = ROOT / "installer" / "shared" / "version_resolver.py"
    spec = importlib.util.spec_from_file_location("version_resolver", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def resolve_version(override: str | None) -> dict[str, str]:
    values = load_resolver().resolve()
    if override:
        import re

        if not re.match(r"^(\d{1,2})\.(\d{1,2})\.(\d+)$", override):
            raise die(f"--version {override!r} 不符合 vXX.XX.X 格式")
        values["AURADSP_VERSION"] = override
        values["AURADSP_TAG"] = f"v{override}"
        values["AURADSP_FULL_VERSION"] = f"{override}.{values['AURADSP_BUILD']}"
    return values


# ---------------------------------------------------------------------------
# 输入探测
# ---------------------------------------------------------------------------

def find_driver_dir(explicit: str | None) -> Path | None:
    """定位 VAIO 驱动构建产物目录（含 .sys/.inf/.cat 的目录）。"""
    if explicit:
        p = Path(explicit)
        return p if p.is_dir() else None
    base = ROOT / "core" / "desktop" / "windows-drivers" / "01_vaio_driver"
    candidates: list[Path] = []
    for sysfile in base.rglob("*.sys"):
        if "legacy" not in sysfile.parts:  # legacy 驱动不进发行包
            candidates.append(sysfile.parent)
    if not candidates:
        return None
    # 取文件最全（sys+inf+cat 齐备）且最新的目录
    def score(d: Path) -> tuple[int, float]:
        kinds = {e.suffix.lower() for e in d.iterdir() if e.is_file()}
        return (len(kinds & {".sys", ".inf", ".cat"}), max(
            (e.stat().st_mtime for e in d.iterdir() if e.is_file()), default=0))

    return max(candidates, key=score)


# ---------------------------------------------------------------------------
# VAIO 驱动的新鲜度校验与按需重编
# ---------------------------------------------------------------------------
# 为什么需要：VAIO 驱动**不在** build_windows.ps1 的构建目标里（那里只编引擎/
# 桥/ASIO），pack.py 也只是把 `modern/x64/Release/AuraVaioDriver` 的**现成产物**
# 打进 zip。于是「谁上次编的就是什么」——源码改了驱动，发行包里的驱动还是旧的。
# 实测：源码含 11-08 的 ControlDevice.cpp 改动（调试日志权限加固），而发出去的
# 驱动包仍是 11-05 的构建（sha256 都不一致）。这类"发出去的二进制与源码不符"
# 最难发现：包能装、能用，只是没有新改动。
#
# 对策：打包前做新鲜度校验——驱动产物必须比所有驱动源文件都新；否则要么按需
# 重编（--build-driver），要么直接中止，绝不默默发旧驱动。

DRIVER_SRC_ROOT = ROOT / "core" / "desktop" / "windows-drivers" / "01_vaio_driver"


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
    products = [driver_dir / "AuraVaioDriver.sys", driver_dir / "auravaiodriver.cat"]
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
        rel = sorted(str(p.relative_to(ROOT)) for p in newer)
        problems.append(
            f"驱动产物({oldest_product and products[0].name} "
            f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(oldest_product))}) "
            f"早于 {len(newer)} 个源文件：{', '.join(rel[:6])}"
            + (" …" if len(rel) > 6 else ""))
    return problems


def build_driver(track: str = "modern", config: str = "Release") -> None:
    """按需重编 + 测试签名 VAIO 驱动（内核驱动只能用 signtool 签）。"""
    # 全面复审 S5b（2026-11-11 实测事故）：build_drivers.ps1 曾不向外
    # 传播 MSBuild 退出码（powershell -File 默认 exit 0)，编译失败后
    # 本函数的 check=True 形同虚设；随后 sign_drivers.ps1 给旧 .sys
    # 重签名刷新了 mtime，下方新鲜度门（纯 mtime 口径）被「洗绿」，
    # pack 以退出码 0 发出了源码不符的旧驱动。脚本侧已修退出码传播；
    # 这里再加一条与签名无关的硬断言：构建脚本跑完后，.sys 必须被
    # 本次构建实际重写（mtime 不早于构建开始），否则直接中止。
    ddir = find_driver_dir(None)
    sys_path = (ddir / "AuraVaioDriver.sys") if ddir else None
    build_started = time.time()
    for script, args in (
        ("build_drivers.ps1", ["-Track", track, "-Config", config]),
        ("sign_drivers.ps1", []),
    ):
        p = DRIVER_SRC_ROOT / script
        if not p.is_file():
            raise die(f"缺少驱动构建脚本: {p}")
        log(f"驱动构建: {script} {' '.join(args)}")
        subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(p)] + args,
            check=True, cwd=str(DRIVER_SRC_ROOT))
        if script == "build_drivers.ps1":
            if sys_path is None or not sys_path.is_file():
                raise die("驱动构建后未找到 AuraVaioDriver.sys，中止打包")
            if sys_path.stat().st_mtime < build_started - 2:
                raise die(
                    "驱动构建脚本报告成功，但 AuraVaioDriver.sys 未被重写"
                    "（仍是旧构建）——拒绝继续打包，避免发出与源码不符的驱动")


# ASIO 驱动 DLL 的规范文件名（ADR-008：CMake 目标 auraasio_driver 的
# 产物名即文件名，驱动侧 register_driver.ps1 与冒烟门均以此为准）。
# AuraAsioDriver.dll 是早期安装器口径的别名，仅作兼容发现/输入，
# 进入产物时一律归一化为规范名。
ASIO_DLL_NAME = "auraasio_driver.dll"
ASIO_DLL_ALIASES = (ASIO_DLL_NAME, "AuraAsioDriver.dll")


def find_asio_driver(explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    base = ROOT / "core" / "desktop" / "windows-drivers"
    for name in ASIO_DLL_ALIASES:
        hits = [p for p in base.rglob(name)]
        if hits:
            return max(hits, key=lambda p: p.stat().st_mtime)
    return None


def _find_built(name: str, explicit: str | None) -> Path | None:
    """在 windows-drivers 构建产物（out/<Config>）中定位单个文件。"""
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    base = ROOT / "core" / "desktop" / "windows-drivers" / "out"
    for cfg in ("Release", "Debug"):
        p = base / cfg / name
        if p.is_file():
            return p
    if base.is_dir():
        hits = [p for p in base.rglob(name)]
        if hits:
            return max(hits, key=lambda p: p.stat().st_mtime)
    return None


def _find_engine_apo(explicit: str | None) -> Path | None:
    """在 windows 引擎构建产物（core/desktop/windows/out/<Config>）
    中定位 auradsp_engine_apo.dll（APO 纪律版引擎，P2a 目标）。"""
    name = "auradsp_engine_apo.dll"
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    base = ROOT / "core" / "desktop" / "windows" / "out"
    for cfg in ("Release", "Debug"):
        p = base / cfg / name
        if p.is_file():
            return p
    if base.is_dir():
        hits = [p for p in base.rglob(name)]
        if hits:
            return max(hits, key=lambda p: p.stat().st_mtime)
    return None


def find_apo_inspect(explicit: str | None) -> Path | None:
    """端点探测工具 apo_inspect.exe（windows-drivers CMake 目标产物）。

    app 的设备刷新链靠它枚举 WASAPI 端点：缺了它安装版点刷新静默
    无效（真机报告 V-02 关联项），故列为随包必备，找不到即拒绝打包。
    """
    return _find_built("apo_inspect.exe", explicit)


class ApoAssets(NamedTuple):
    """APO 运维资产四件（同组进 driver/）。"""
    config_exe: Path   # apo_config.exe：原生移植版（§2.3 方案 A）
    apo_dll: Path      # AuraApo.dll：APO 本体（此前从未随包，附加必败）
    inspect: Path      # apo_inspect.exe：端点枚举
    engine_dll: Path   # auradsp_engine_apo.dll：真处理引擎纪律版
                       # （2026-11-10 立项 P2；APO 按同目录优先
                       # 搜索它，缺失则 APO 恒透传——故列为必备）


def resolve_apo_assets(args) -> ApoAssets:
    """APO 运维资产：脚本（仓库）+ 三件构建产物（windows-drivers out/）。

    app 侧 System APO 附加/状态查询与设备刷新都依赖它们；历史上
    从未进过载荷（真机报告 V-03 首因），自 2026-11-09 F4 起同组装。
    2026-11-09 §2.3 方案 A 补齐原生 apo_config.exe 与 AuraApo.dll：
    无 DLL 时脚本/工具在安装布局里无对象可挂，附加必然未生效。
    """
    apo_inspect = find_apo_inspect(args.apo_inspect)
    if apo_inspect is None:
        raise die("找不到 apo_inspect.exe；先构建 windows-drivers 目标"
                  "（build_windows.ps1 含 apo_inspect 目标），"
                  "或用 --apo-inspect 指定")
    config_exe = _find_built("apo_config.exe", args.apo_config)
    if config_exe is None:
        raise die("找不到 apo_config.exe；先构建 windows-drivers 目标"
                  "（含 apo_config 目标），或用 --apo-config 指定")
    apo_dll = _find_built("AuraApo.dll", args.apo_dll)
    if apo_dll is None:
        raise die("找不到 AuraApo.dll；先构建 windows-drivers 目标"
                  "（含 AuraApo 目标），或用 --apo-dll 指定")
    engine_dll = _find_engine_apo(args.apo_engine)
    if engine_dll is None:
        raise die("找不到 auradsp_engine_apo.dll；先构建 windows 引擎"
                  "目标（含 auradsp_engine_apo 目标，J5 同款），"
                  "或用 --apo-engine 指定")
    return ApoAssets(config_exe, apo_dll, apo_inspect, engine_dll)


def check_staging(staging: Path) -> None:
    if not staging.is_dir():
        raise die(f"staging 目录不存在: {staging}（先跑 build_windows.ps1 或 --build-staging）")
    if not (staging / "auradsp_app.exe").is_file():
        raise die(f"staging 缺 auradsp_app.exe: {staging}")


# ---------------------------------------------------------------------------
# 资源策略
# ---------------------------------------------------------------------------

def resource_pack_paths(kind: str, packs_dir: Path) -> list[Path]:
    if kind in ("core", "none"):
        return []
    full = packs_dir / "auradsp-resource-full.zip"
    if kind == "full":
        return [full] if full.is_file() else []
    if kind == "light":
        # 轻量包（Q2 裁定）：core（卷积轻档 + 全部脚本）打底，
        # headphone-ddc 补齐 VDC 全量；其余 addon（声学空间/社区
        # 调音等卷积大包）不进轻量包。
        ordered = []
        for name in ("auradsp-resource-core.zip",
                     "auradsp-addon-headphone-ddc.zip"):
            p = packs_dir / name
            if p.is_file():
                ordered.append(p)
        return ordered
    # addons：core → full → addons（文件名序）
    ordered = []
    for name in ("auradsp-resource-core.zip", "auradsp-resource-full.zip"):
        p = packs_dir / name
        if p.is_file():
            ordered.append(p)
    ordered += sorted(packs_dir.glob("auradsp-addon-*.zip"))
    return ordered


# 内置目录登记（资源计划 P1 / 计划书 Part B1）：打包期生成，
# App 启动读取，把安装目录 resources/ 下四类内容登记为内置扫
# 描位置。rel 相对 exe 目录；文件随包携带，App 只读不写。
BUILTIN_DIRS_JSON = {
    "version": 1,
    "dirs": [
        {"kind": "convolver", "rel": "resources/convolver"},
        {"kind": "ddc", "rel": "resources/ddc"},
        {"kind": "liveprog", "rel": "resources/liveprog"},
        {"kind": "plugins", "rel": "resources/plugins"},
    ],
}

PLUGIN_PLACEHOLDER_KEEP = (
    "AuraDSP bundled plugin placeholder (resource plan P1, 2026-11-12).\n"
    "This directory intentionally ships empty for now; future open-source\n"
    "free plugins may be bundled here.\n")


def finalize_resources(res_dir: Path, what_if: bool) -> None:
    """合并后的统一收尾：插件空占位目录 + builtin_dirs.json。

    staging 若来自旧构建（无 plugins/）或资源 zip 覆盖后占位丢
    失，这里兜底补齐，保证任何档位（core/full/light/addons）
    的 resources/ 结构恒完整。
    """
    if what_if:
        log("resources: what-if 跳过 finalize（占位 + builtin_dirs.json）")
        return
    for sub in ("clap", "vst2", "vst3"):
        keep = res_dir / "plugins" / sub / ".keep"
        if not keep.is_file():
            keep.parent.mkdir(parents=True, exist_ok=True)
            keep.write_text(PLUGIN_PLACEHOLDER_KEEP, encoding="utf-8")
    (res_dir / "builtin_dirs.json").write_text(
        json.dumps(BUILTIN_DIRS_JSON, indent=1) + "\n", encoding="utf-8")
    log("resources: builtin_dirs.json 已生成 + plugins 占位已补齐")


def load_sha256sums(packs_dir: Path) -> dict[str, str]:
    """读取 packs_dir 下的 SHA256SUMS.txt（build_packages.py 生成、
    随资源 Release 发布）→ {文件名: sha256 小写}。文件不存在返回空
    dict（本地自建包流程不强制）；存在则 apply_resources 逐包对账，
    这是发行规范 §4「验哈希再导入」在打包侧的执行点（2026-11-08
    审计·预设低3：此前该契约只有文档、无代码执行）。"""
    sums_file = packs_dir / "SHA256SUMS.txt"
    if not sums_file.is_file():
        return {}
    out: dict[str, str] = {}
    for line in sums_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2 and len(parts[0]) == 64:
            out[Path(parts[-1]).name] = parts[0].lower()
    return out


def apply_resources(work_staging: Path, kind: str, packs_dir: Path,
                    what_if: bool) -> list[dict[str, str]]:
    """在 staging 副本上应用资源策略，返回合并记录（写入 build-info）。"""
    records: list[dict[str, str]] = []
    res_dir = work_staging / "resources"
    if kind == "none":
        if res_dir.exists():
            manifest = res_dir / "manifest.json"
            keep = manifest.read_bytes() if manifest.is_file() else None
            shutil.rmtree(res_dir)
            res_dir.mkdir(parents=True)
            if keep is not None:
                (res_dir / "manifest.json").write_bytes(keep)
            (res_dir / "README.txt").write_text(
                "Resources were excluded from this package (--resources none).\n"
                "Download the resource packs from the GitHub Release and\n"
                "extract them into this directory.\n", encoding="utf-8")
        log("resources: none（已剔除，保留 manifest.json）")
        return records
    packs = resource_pack_paths(kind, packs_dir)
    if kind in ("full", "addons", "light") and not packs:
        raise die(f"--resources {kind} 需要资源包，但 {packs_dir} 下没有找到"
                  "（先跑 build_packages.py 或加 --rebuild-resource-packs）")
    expected_sums = load_sha256sums(packs_dir)
    for pack in packs:
        sha = hashlib.sha256(pack.read_bytes()).hexdigest()
        if expected_sums:
            want = expected_sums.get(pack.name)
            if want is None:
                raise die(f"SHA256SUMS.txt 未登记资源包 {pack.name}，"
                          "拒绝合并（发行完整性对账）")
            if want != sha:
                raise die(f"资源包 {pack.name} 的 SHA-256 与 "
                          "SHA256SUMS.txt 不符，拒绝合并")
        count = 0
        if not what_if:
            with zipfile.ZipFile(pack) as zf:
                for info in zf.infolist():
                    name = info.filename
                    # user_data 隔离按大小写不敏感判定（2026-11-08 审计
                    # F5）：Windows 文件系统大小写不敏感，USER_DATA/ 变体
                    # 会落进同一目录，敏感前缀检查不得被大小写绕开。
                    if name.endswith("/") or name.lower().startswith("user_data/"):
                        continue  # 用户私有数据隔离（管线既定口径）
                    # 单条目整读内存，设上限防一方包里的异常大条目吃爆
                    # 构建机内存（审计 F5）。资源条目量级在 MB 级，
                    # 512MiB 留足余量。
                    if info.file_size > 512 * 1024 * 1024:
                        raise die(f"资源包 {pack.name} 条目超上限: {name}"
                                  f"（{info.file_size} 字节）")
                    target = res_dir / name
                    if not target.resolve().is_relative_to(res_dir.resolve()):
                        raise die(f"资源包 {pack.name} 含越界路径: {name}")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(zf.read(info))
                    count += 1
        records.append({"pack": pack.name, "sha256": sha, "files": str(count)})
        log(f"resources: 合并 {pack.name}（{count} 文件，sha256 {sha[:12]}…）")
    if kind == "core":
        log("resources: core（staging 自带）")
    finalize_resources(res_dir, what_if)
    return records


def apply_defaults(work_staging: Path, what_if: bool) -> None:
    """在 staging 根生成 defaults/ 默认层（资源计划 Part D）。

    生成器是 App 自己的契约测试 test/defaults_emit_test.dart
    （AURADSP_EMIT_DEFAULTS 触发产出）：config.default.json 由
    AppConfig 代码本尊导出，生成物与代码默认永不漂移；presets
    复制出厂资产。flutter 不可用时直接 die——发行构建机必备
    Flutter，静默跳过会发出「有分层之名、无默认层之实」的包。
    """
    if what_if:
        log("defaults: what-if 跳过生成")
        return
    flutter = shutil.which("flutter")
    if flutter is None:
        raise die("生成 defaults/ 需要 flutter 在 PATH 中"
                  "（默认层由 App 代码经契约测试导出）")
    app_dir = ROOT / "app" / "auradsp_app"
    env = dict(os.environ,
               AURADSP_EMIT_DEFAULTS=str(work_staging / "defaults"))
    log("defaults: 经 App 契约测试生成默认层…")
    # stdout 必须落真实文件、不能用 PIPE：flutter test 的测试子进程经
    # Python 管道继承句柄时会在加载阶段断连（"Connection closed before
    # test suite loaded"，2026-11-12 开发机实证）；文件重定向无此问题。
    import tempfile
    with tempfile.TemporaryFile(mode="w+b") as lf:
        r = subprocess.run(
            [flutter, "test", "test/defaults_emit_test.dart"],
            cwd=str(app_dir), env=env,
            stdout=lf, stderr=subprocess.STDOUT)
        if r.returncode != 0:
            lf.seek(0)
            tail = "\n".join(
                lf.read().decode("utf-8", "replace").splitlines()[-15:])
            raise die(f"defaults 生成失败（flutter test rc={r.returncode}）：\n{tail}")
    manifest = work_staging / "defaults" / "manifest.json"
    if not manifest.is_file():
        raise die("defaults 生成未产出 manifest.json")
    log("defaults: 默认层已生成（config.default.json + presets + manifest）")


# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------

def zip_dir(src: Path, dest_zip: Path, level: int, arc_prefix: str = "",
            what_if: bool = False) -> int:
    """把目录内容压成 zip（条目排序、路径统一正斜杠），返回条目数。"""
    files = sorted(p for p in src.rglob("*") if p.is_file())
    if what_if:
        log(f"what-if: 将打包 {src} → {dest_zip}（{len(files)} 文件）")
        return len(files)
    comp = zipfile.ZIP_DEFLATED if level > 0 else zipfile.ZIP_STORED
    with zipfile.ZipFile(dest_zip, "w", comp, compresslevel=level or None) as zf:
        for f in files:
            arc = (arc_prefix + f.relative_to(src).as_posix())
            zf.write(f, arc)
    return len(files)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def refresh_build_info(staging_copy: Path, extra: dict[str, str]) -> None:
    """在产物副本上刷新 build-info.txt（复用 dist_manifest 的口径追加段）。"""
    info = staging_copy / "build-info.txt"
    lines = []
    if info.is_file():
        lines = info.read_text(encoding="utf-8", errors="replace").splitlines()
    lines += ["", "# pack.py 附加记录"] + [f"{k}: {v}" for k, v in extra.items()]
    info.write_text("\n".join(lines) + "\n", encoding="utf-8")


REGISTER_ASIO_PS1 = """\
# AuraDSP ASIO 驱动注册/反注册（pack.py 生成，随驱动包分发）
# 用法（管理员 PowerShell）：
#   .\register_asio.ps1            注册 auraasio_driver.dll
#   .\register_asio.ps1 -Unregister 反注册
# -ResultFile：把成败 JSON 写回指定文件（提权进程的输出
# 跨不过 UAC 边界，App 靠此文件读真实失败原因）。
param([switch]$Unregister, [string]$ResultFile = "")
$ErrorActionPreference = "Stop"
function Write-AsioResult([bool]$Ok, [string]$Message) {
  if ($ResultFile) {
    @{ ok = $Ok; message = $Message } | ConvertTo-Json -Compress |
      Set-Content -LiteralPath $ResultFile -Encoding UTF8
  }
}
try {
  $dll = Join-Path $PSScriptRoot "auraasio_driver.dll"
  if (-not (Test-Path $dll)) {
    $alt = Join-Path (Split-Path -Parent $PSScriptRoot) "auraasio_driver.dll"
    if (Test-Path $alt) { $dll = $alt }
  }
  if (-not (Test-Path $dll)) { throw "auraasio_driver.dll 不在脚本目录或其上级目录" }
  $regsvr = "$env:SystemRoot\System32\regsvr32.exe"
  # DLL 路径必须带引号（第六轮项 2 实证）：Start-Process 的
  # -ArgumentList 数组以空格拼接、不自动加引号，安装路径含
  # 空格（默认 Program Files）时路径被拆断、regsvr32 必败。
  $args = if ($Unregister) { @("/s", "/u", "`"$dll`"") } else { @("/s", "`"$dll`"") }
  $p = Start-Process $regsvr -ArgumentList $args -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "regsvr32 退出码 $($p.ExitCode)" }
  $done = "AuraASIO $(if ($Unregister) { '反注册' } else { '注册' })完成: $dll"
  Write-AsioResult $true $done
  Write-Host $done
} catch {
  Write-AsioResult $false $_.Exception.Message
  throw
}
"""

# 随包手动安装资产（入库模板；driver zip 与 Setup 载荷共用同一组装函数）。
# 用户取消勾选驱动时这些文件仍保留在 安装目录/driver/，供事后手动补装。
DRIVER_TEMPLATE_DIR = ROOT / "installer" / "windows" / "custom_installer" / "driver"
DRIVER_TEMPLATE_FILES = ("install_vaio.ps1", "README.txt")


def _copy2_overwrite(src: Path, dst: Path) -> None:
    """覆盖拷贝到可能已存在的 staging 目标。

    build_windows.ps1 Step 5 会先用本模块补齐 dist 的 driver/；随后
    portable/setup 复制 staging 再组装时，目标里的 devcon.exe 带着
    ReadOnly（copy2 保留源属性），裸 open(dst,'wb') 会 PermissionError。
    这里先清只读再删除，保证重复补齐幂等。
    """
    if dst.exists():
        try:
            dst.chmod(0o666)
        except OSError:
            pass
        dst.unlink()
    shutil.copy2(src, dst)


def stage_driver_files(
    dest: Path,
    driver_dir: Path,
    asio: Path,
    install_ps1: Path,
    apo: ApoAssets,
    *,
    include_asio_dll: bool,
) -> int:
    """组装随包 driver/ 目录：驱动产物 + 测试证书 + devcon + 手动脚本 + 说明。

    返回拷贝的驱动产物数；缺模板直接失败（避免产出不可手动安装的包）。
    README 以 UTF-8 BOM 落盘，兼容旧版记事本读取中文。
    """
    # 入口统一校验（细审 R-C L-6）：三模式此前只有 driver
    # 模式在调用前验 install_ps1，portable/setup 缺失时
    # copy2 抛未捕获 FileNotFoundError——在此单点 die，
    # 三模式同口径。
    if not install_ps1.is_file():
        raise die(f"缺 install_driver.ps1: {install_ps1}")
    dest.mkdir(parents=True, exist_ok=True)
    copied = 0
    for f in sorted(driver_dir.iterdir()):
        if not f.is_file():
            continue
        is_payload = f.suffix.lower() in (".sys", ".inf", ".cat", ".cer")
        is_devcon = f.name.lower() == "devcon.exe"
        if is_payload or is_devcon:
            _copy2_overwrite(f, dest / f.name)
            copied += 1
    if copied == 0:
        raise die(f"驱动目录没有任何 .sys/.inf/.cat/.cer: {driver_dir}")
    _copy2_overwrite(install_ps1, dest / install_ps1.name)
    # APO 运维资产：app 侧附加/状态工具 apo_config.exe（原生版，
    # 已替代 python 脚本）+ APO 本体 AuraApo.dll + 设备端点刷新
    # （apo_inspect.exe），与手动安装资产同组进 driver/。
    _copy2_overwrite(apo.config_exe, dest / apo.config_exe.name)
    _copy2_overwrite(apo.apo_dll, dest / apo.apo_dll.name)
    _copy2_overwrite(apo.inspect, dest / apo.inspect.name)
    # 真处理引擎与 AuraApo.dll 同级落位（APO 的 D1 搜索首选）。
    _copy2_overwrite(apo.engine_dll, dest / apo.engine_dll.name)
    if include_asio_dll:
        _copy2_overwrite(asio, dest / ASIO_DLL_NAME)
    # .ps1 必须带 UTF-8 BOM 落盘（资源计划 Stage 0 / §8.4 定罪）：
    # PowerShell 5.1 对无 BOM 的 .ps1 按系统 ANSI（中文 Windows
    # = GBK）解码，脚本内中文字符串字节错位可吞掉引号导致解析
    # 期 ParserError、脚本永不执行（register_asio.ps1 实测中
    # 招：注册/反注册双向恒失败）。一律字节级补 BOM，正文不动。
    (dest / "register_asio.ps1").write_bytes(
        b"\xef\xbb\xbf" + REGISTER_ASIO_PS1.encode("utf-8"))
    for name in DRIVER_TEMPLATE_FILES:
        src = DRIVER_TEMPLATE_DIR / name
        if not src.is_file():
            raise die(f"缺随包驱动模板: {src}")
        if name.lower().endswith(".txt"):
            (dest / name).write_text(
                src.read_text(encoding="utf-8"), encoding="utf-8-sig")
        elif name.lower().endswith(".ps1"):
            raw = src.read_bytes()
            if not raw.startswith(b"\xef\xbb\xbf"):
                raw = b"\xef\xbb\xbf" + raw
            (dest / name).write_bytes(raw)
        else:
            _copy2_overwrite(src, dest / name)
    return copied


# ---------------------------------------------------------------------------
# 模式：driver
# ---------------------------------------------------------------------------

def mode_driver(args, ver: dict[str, str], out: Path) -> Path:
    driver_dir = find_driver_dir(args.driver_dir)
    asio = find_asio_driver(args.asio_driver)
    if driver_dir is None:
        raise die("找不到 VAIO 驱动产物目录（含 .sys 的目录）；"
                  "先在 Windows 构建驱动，或用 --driver-dir 指定")
    if asio is None:
        raise die("找不到 auraasio_driver.dll；先跑 build_windows.ps1 全量构建"
                  "（含 auraasio_driver 目标），或用 --asio-driver 指定")
    install_ps1 = (ROOT / "core" / "desktop" / "windows-drivers" /
                   "01_vaio_driver" / "install_driver.ps1")
    if not install_ps1.is_file():
        raise die(f"缺 install_driver.ps1: {install_ps1}")
    apo = resolve_apo_assets(args)
    dest = out / f"AuraDSP-Driver-x64-{ver['AURADSP_TAG']}.zip"
    if args.what_if:
        log(f"what-if: driver 包 ← {driver_dir} + {install_ps1.name} + {asio}")
        return dest
    with tempfile.TemporaryDirectory(prefix="auradsp-driver-") as td:
        stage = Path(td) / "driver"
        stage_driver_files(stage, driver_dir, asio, install_ps1,
                           apo,
                           include_asio_dll=True)
        n = zip_dir(stage, dest, args.zip_level)
    log(f"driver: {dest.name}（{n} 条目，{dest.stat().st_size / 1e6:.1f} MB）")
    return dest



def complete_payload_tree(work: Path, args) -> None:
    """把完整载荷布局落到 work：ASIO 本体进根 + driver/ 恒保留。

    portable / setup 的临时副本与 staging 文件夹本体共用同一
    组装，保证三处布局逐字一致；资产缺失即 die（三模式既有
    口径）。
    """
    install_ps1 = (ROOT / "core" / "desktop" / "windows-drivers" /
                   "01_vaio_driver" / "install_driver.ps1")
    if not install_ps1.is_file():
        raise die(f"缺 install_driver.ps1: {install_ps1}")
    apo = resolve_apo_assets(args)
    asio = find_asio_driver(args.asio_driver)
    driver_dir = find_driver_dir(args.driver_dir)
    if asio is None:
        raise die("找不到 auraasio_driver.dll；先跑 build_windows.ps1 全量构建"
                  "（含 auraasio_driver 目标），或用 --asio-driver 指定")
    if driver_dir is None:
        raise die("找不到 VAIO 驱动产物目录（含 .sys 的目录）；"
                  "先在 Windows 构建驱动，或用 --driver-dir 指定")
    _copy2_overwrite(asio, work / ASIO_DLL_NAME)
    stage_driver_files(work / "driver", driver_dir, asio, install_ps1,
                       apo, include_asio_dll=True)


def refresh_dist_manifest(staging: Path) -> None:
    """补齐后刷新 build-info.txt（与 sync_artifacts 同口径，尽力而为）。"""
    script = ROOT / "tools" / "bin" / "dist_manifest.py"
    if not script.is_file():
        return
    rc = subprocess.run([sys.executable, str(script),
                         "--dist-dir", str(staging)]).returncode
    if rc != 0:
        log(f"警告: build-info.txt 刷新失败（rc={rc}），清单可能过期")


def mode_staging(args, ver: dict[str, str], out: Path) -> Path:
    """就地补齐 staging 文件夹本体（dist 绿色目录）。

    该文件夹既是打包输入、也是日常测试入口：此前 driver/ 只
    进 zip/安装载荷的临时副本，文件夹本体恒缺，测驱动面板
    必须先解压便携包（用户 2026-11-10 报告）。build_windows
    .ps1 Step 5 亦调用本模式，绿色目录与绿色 zip 同样完整。
    """
    complete_payload_tree(args.staging, args)
    apply_defaults(args.staging, args.what_if)
    refresh_dist_manifest(args.staging)
    log(f"staging: {args.staging} 已补齐（根 ASIO + driver/），"
        "可直接打开文件夹运行测试")
    return args.staging


# ---------------------------------------------------------------------------
# 模式：portable
# ---------------------------------------------------------------------------

def prepare_staging_copy(args) -> tuple[tempfile.TemporaryDirectory, Path]:
    """把 staging 复制到临时目录并应用资源策略（原 staging 不动）。"""
    td = tempfile.TemporaryDirectory(prefix="auradsp-staging-")
    work = Path(td.name) / "staging"
    shutil.copytree(args.staging, work)
    records = apply_resources(work, args.resources, args.packs_dir, args.what_if)
    apply_defaults(work, args.what_if)
    refresh_build_info(work, {
        "pack.resources": args.resources,
        **{f"pack.resource.{r['pack']}": r["sha256"] for r in records},
    })
    return td, work


def mode_portable(args, ver: dict[str, str], out: Path) -> Path:
    dest = out / f"AuraDSP-Windows-x64-{ver['AURADSP_TAG']}.zip"
    # 资产校验前置到 what-if 之前（细审 R-C L-6）：--what-if
    # 预检也要报缺资产，与 driver 模式同口径；组装时复用。
    install_ps1 = (ROOT / "core" / "desktop" / "windows-drivers" /
                   "01_vaio_driver" / "install_driver.ps1")
    if not install_ps1.is_file():
        raise die(f"缺 install_driver.ps1: {install_ps1}")
    apo = resolve_apo_assets(args)
    if args.what_if:
        log(f"what-if: portable 包 ← {args.staging}（resources={args.resources}）")
        return dest
    td, work = prepare_staging_copy(args)
    with td:
        # 与 setup 载荷同布局：ASIO 本体进根 + driver/ 恒保留。
        # 便携与安装跑同一个 app，缺 driver/ 时 VAIO/ASIO/APO
        # 面板找不到任何随包工具（真机报告 2026-11-09：便携包
        # 无 apo_config.exe），故便携包同组装驱动资产。
        complete_payload_tree(work, args)
        n = zip_dir(work, dest, args.zip_level)
    log(f"portable: {dest.name}（{n} 条目，{dest.stat().st_size / 1e6:.1f} MB）")
    return dest


# ---------------------------------------------------------------------------
# 模式：setup（单体 EXE 拼装）
# ---------------------------------------------------------------------------

def build_installer_artifacts(args) -> Path:
    """--build-installer：构建引导壳与向导，汇集到 build/installer/dist。"""
    if os.name != "nt":
        raise die("--build-installer 只能在 Windows 上执行"
                  "（引导壳需 MSVC、向导需 flutter build windows）")
    dist = ROOT / "build" / "installer" / "dist"
    boot_src = ROOT / "installer" / "windows" / "custom_installer" / "bootstrapper"
    boot_build = ROOT / "build" / "installer" / "bootstrapper"
    log("构建引导壳（cmake）…")
    subprocess.run(["cmake", "-S", str(boot_src), "-B", str(boot_build),
                    "-A", "x64"], check=True)
    subprocess.run(["cmake", "--build", str(boot_build), "--config", "Release"],
                   check=True)
    shell = boot_build / "Release" / "bootstrapper.exe"
    if not shell.is_file():
        raise die(f"引导壳构建完成但产物缺失: {shell}")
    wizard_dir = ROOT / "installer" / "windows" / "custom_installer" / "wizard"
    log("构建向导（flutter build windows）…")
    # 经 win_env_sanitize 启动：Windows 上 flutter 是 .bat 垫片，
    # subprocess 直接 spawn 批处理会 FileNotFoundError（CreateProcess 只补 .exe）；
    # 同时该脚本会归一化环境变量大小写重复键——否则 MSBuild 会因
    # ArgumentException('path') 起不来编译器，编译"成功"却产出陈旧二进制。
    env_sanitizer = ROOT / "tools" / "bin" / "win_env_sanitize.py"
    subprocess.run([sys.executable, str(env_sanitizer), "flutter", "build",
                    "windows", "--release", "--no-tree-shake-icons"],
                   cwd=wizard_dir, check=True)
    runner = wizard_dir / "build" / "windows" / "x64" / "runner" / "Release"
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
    p = Path(args.installer_build_dir) if args.installer_build_dir else \
        ROOT / "build" / "installer" / "dist"
    if not (p / "bootstrapper.exe").is_file() or not (p / "wizard").is_dir():
        raise die(f"installer 构建目录不完整（需 bootstrapper.exe + wizard/）: {p}"
                  "；先 --build-installer 或用 --installer-build-dir 指定")
    return p


def mode_setup(args, ver: dict[str, str], out: Path) -> Path:
    dest = out / f"AuraDSP-Setup-x64-{ver['AURADSP_TAG']}.exe"
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
    install_ps1 = (ROOT / "core" / "desktop" / "windows-drivers" /
                   "01_vaio_driver" / "install_driver.ps1")
    if not install_ps1.is_file():
        raise die(f"缺 install_driver.ps1: {install_ps1}")
    apo = resolve_apo_assets(args)
    if args.what_if:
        log(f"what-if: setup ← shell {inst_dir} + staging {args.staging} "
            f"+ asio {asio} + driver {driver_dir}")
        return dest

    td, work = prepare_staging_copy(args)
    with td:
        # 载荷增补：ASIO 驱动本体（安装目录根，供 FFI 注册）
        # + driver/ 子目录（恒保留，含手动安装脚本、驱动与签名说明）
        complete_payload_tree(work, args)

        payload_zip = Path(td.name) / "payload.zip"
        zip_dir(work, payload_zip, args.zip_level, arc_prefix="payload/")
        payload_bytes = payload_zip.read_bytes()
        payload_sha = hashlib.sha256(payload_bytes).hexdigest()

        # 向导 zip：内容 + wizard_manifest.json（二级完整性校验）
        wizard_src = inst_dir / "wizard"
        manifest = {"product": "AuraDSP",
                    "version": ver["AURADSP_VERSION"],
                    "fullVersion": ver["AURADSP_FULL_VERSION"],
                    "payloadSha256": payload_sha,
                    "files": {}}
        for f in sorted(p for p in wizard_src.rglob("*") if p.is_file()):
            manifest["files"][f.relative_to(wizard_src).as_posix()] = sha256_file(f)
        manifest_path = Path(td.name) / "wizard_manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=1), encoding="utf-8")
        wizard_zip = Path(td.name) / "wizard.zip"
        # ZIP-W 必须 STORED 不压缩：引导壳零第三方依赖、只解 stored 条目
        # （实施设计 §3）；ZIP-P 保持 deflate（向导用 archive 包解压）。
        with zipfile.ZipFile(wizard_zip, "w", zipfile.ZIP_STORED) as zf:
            for f in sorted(p for p in wizard_src.rglob("*") if p.is_file()):
                zf.write(f, f.relative_to(wizard_src).as_posix())
            zf.write(manifest_path, "wizard_manifest.json")
        wizard_bytes = wizard_zip.read_bytes()

        shell_bytes = (inst_dir / "bootstrapper.exe").read_bytes()
        off_w = len(shell_bytes)
        off_p = off_w + len(wizard_bytes)
        footer = struct.pack(FOOTER_FMT, FOOTER_MAGIC, 1, 0,
                             off_w, len(wizard_bytes), off_p,
                             len(payload_bytes),
                             bytes.fromhex(payload_sha))
        with dest.open("wb") as fh:
            fh.write(shell_bytes)
            fh.write(wizard_bytes)
            fh.write(payload_bytes)
            fh.write(footer)
    log(f"setup: {dest.name}（{dest.stat().st_size / 1e6:.1f} MB，"
        f"payload sha256 {payload_sha[:12]}…）")
    return dest


# ---------------------------------------------------------------------------
# --verify：Setup EXE 自检
# ---------------------------------------------------------------------------

def verify_setup(path: Path) -> bool:
    data_len = path.stat().st_size
    with path.open("rb") as fh:
        fh.seek(max(0, data_len - FOOTER_SIZE))
        footer = fh.read(FOOTER_SIZE)
    if len(footer) != FOOTER_SIZE:
        log("verify: 文件小于尾块尺寸")
        return False
    magic, fmt, _flags, off_w, len_w, off_p, len_p, sha = struct.unpack(
        FOOTER_FMT, footer)
    ok = True
    def check(name: str, cond: bool, extra: str = "") -> None:
        nonlocal ok
        ok = ok and cond
        log(f"verify: {name} {'OK' if cond else 'FAIL'} {extra}")
    check("magic", magic == FOOTER_MAGIC)
    check("fmtVer", fmt == 1, f"(={fmt})")
    check("offsets", 0 < off_w < off_p and off_p + len_p + FOOTER_SIZE == data_len,
          f"(W@{off_w}+{len_w}, P@{off_p}+{len_p}, file={data_len})")
    with path.open("rb") as fh:
        fh.seek(off_p)
        payload = fh.read(len_p)
    digest = hashlib.sha256(payload).hexdigest()
    check("payload sha256", digest.encode() == sha.hex().encode(),
          f"({digest[:12]}…)")
    for label, off, ln in (("wizard", off_w, len_w), ("payload", off_p, len_p)):
        with path.open("rb") as fh:
            fh.seek(off)
            blob = fh.read(ln)
        try:
            zf = zipfile.ZipFile(io.BytesIO(blob))
            bad = zf.testzip()
            check(f"{label} zip", bad is None, f"({len(zf.namelist())} 条目)")
            if label == "wizard":
                man = json.loads(zf.read("wizard_manifest.json"))
                check("manifest payloadSha256",
                      man.get("payloadSha256") == digest)
        except Exception as exc:  # noqa: BLE001
            check(f"{label} zip", False, f"({exc})")
    return ok


# ---------------------------------------------------------------------------
# 构建联动与签名钩子
# ---------------------------------------------------------------------------

def build_staging(args) -> None:
    if os.name != "nt":
        raise die("--build-staging 只能在 Windows 上执行（build_windows.ps1）")
    cmd = ["powershell", "-ExecutionPolicy", "Bypass", "-File",
           str(ROOT / "tools" / "windows" / "build_windows.ps1"),
           "-BuildType", args.build_type]
    if args.skip_drivers:
        cmd.append("-SkipDrivers")
    log(f"构建 staging: {' '.join(cmd)}")
    subprocess.run(cmd, check=True, cwd=ROOT)


def sign_file(args, path: Path) -> None:
    if not args.sign:
        return
    if os.name != "nt":
        log(f"sign: 非 Windows 平台跳过 {path.name}（钩子仅在 Windows 生效）")
        return
    thumb = args.cert_thumbprint or os.environ.get("AURADSP_CERT_THUMBPRINT", "")
    pfx = os.environ.get("AURADSP_SIGN_PFX", "")
    if not thumb and not pfx:
        log(f"sign: 未配置证书（--cert-thumbprint 或 AURADSP_SIGN_PFX），跳过 {path.name}")
        return
    cmd = [args.signtool, "sign", "/fd", "SHA256", "/tr",
           "http://timestamp.digicert.com", "/td", "SHA256"]
    if thumb:
        cmd += ["/sha1", thumb]
    else:
        cmd += ["/f", pfx, "/p", os.environ.get("AURADSP_SIGN_PASS", "")]
    cmd.append(str(path))
    log(f"sign: {path.name}")
    subprocess.run(cmd, check=True)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="AuraDSP Windows 发行打包（driver/portable/setup）")
    ap.add_argument("--mode", default="all",
                    help="driver,portable,setup,staging 或 all（逗号分隔）")
    ap.add_argument("--resources", default="core",
                    choices=("core", "full", "light", "addons", "none"))
    ap.add_argument("--rebuild-resource-packs", action="store_true")
    ap.add_argument("--packs-dir", type=Path, default=ROOT / "dist" / "resources")
    ap.add_argument("--staging", type=Path,
                    default=ROOT / "dist" / "AuraDSP-Windows-x64")
    ap.add_argument("--build-staging", action="store_true")
    ap.add_argument("--build-type", default="Release", choices=("Release", "Debug"))
    ap.add_argument("--skip-drivers", action="store_true",
                    help="透传 build_windows.ps1 -SkipDrivers")
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
    ap.add_argument("--out", type=Path, default=ROOT / "dist")
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


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.verify:
        return 0 if verify_setup(args.verify) else 1

    ver = resolve_version(args.version)
    modes = (["driver", "portable", "setup"] if args.mode == "all"
             else [m.strip() for m in args.mode.split(",") if m.strip()])
    log(f"版本 {ver['AURADSP_VERSION']}（{ver['AURADSP_TAG']}），模式 {modes}，"
        f"资源 {args.resources}")

    if args.build_staging and not args.what_if:
        build_staging(args)
    if args.rebuild_resource_packs and not args.what_if:
        log("重建资源包（build_packages.py）…")
        subprocess.run([sys.executable,
                        str(ROOT / "tools" / "resource_pipeline" / "build_packages.py")],
                       check=True, cwd=ROOT)
    if modes != ["driver"]:  # driver 模式不需要 staging
        check_staging(args.staging)

    # VAIO 驱动：按需重编 → 新鲜度校验 → 不新鲜就中止。
    # 驱动不进 build_windows.ps1 的目标集，所以「谁上次编的就是什么」；
    # 不加这道校验，打出来的包可能装着比源码旧的驱动（实测踩过：源码含
    # 11-08 的调试日志权限加固，包里仍是 11-05 的构建）。
    if modes == ["staging"]:
        # staging 是开发测试向的就地补齐：驱动陈旧只警告不拦截
        # （发行模式 driver/setup 的硬闸门不变，仍拒绝发旧驱动）。
        ddir = find_driver_dir(args.driver_dir)
        if ddir is not None:
            for problem in check_driver_freshness(ddir):
                log(f"警告: {problem}（staging 不拦截；发行打包仍会拒绝）")
    if "driver" in modes or "setup" in modes:
        if args.build_driver and not args.what_if:
            build_driver()
        ddir = find_driver_dir(args.driver_dir)
        if ddir is not None:
            problems = check_driver_freshness(ddir)
            if problems:
                raise die(
                    "VAIO 驱动产物比源码旧，拒绝打包（避免发出与源码不符的驱动）：\n  - "
                    + "\n  - ".join(problems)
                    + "\n  修法：加 --build-driver 自动重编并签名；或先跑 "
                      "core/desktop/windows-drivers/01_vaio_driver/build_drivers.ps1 "
                      "-Track modern -Config Release")
            log(f"驱动新鲜度校验通过: {ddir}")

    out: Path = args.out
    if not args.what_if:
        out.mkdir(parents=True, exist_ok=True)
    produced: list[Path] = []
    staging_completed = False
    for mode in modes:
        if mode != "staging":
            dest_name = {"driver": f"AuraDSP-Driver-x64-{ver['AURADSP_TAG']}.zip",
                         "portable": f"AuraDSP-Windows-x64-{ver['AURADSP_TAG']}.zip",
                         "setup": f"AuraDSP-Setup-x64-{ver['AURADSP_TAG']}.exe"}[mode]
            if args.clean and (out / dest_name).exists() and not args.what_if:
                (out / dest_name).unlink()
        fn = {"driver": mode_driver, "portable": mode_portable,
              "setup": mode_setup, "staging": mode_staging}[mode]
        produced.append(fn(args, ver, out))
        if not args.what_if and produced[-1].is_file():
            sign_file(args, produced[-1])
        if (not args.what_if and not staging_completed
                and mode in ("portable", "setup")):
            # dist 文件夹本体同步补齐：打包完直接开文件夹即可
            # 测试，不必再解压刚产出的便携包（dist 每个产出都
            # 完整的用户口径，2026-11-10）。
            complete_payload_tree(args.staging, args)
            refresh_dist_manifest(args.staging)
            staging_completed = True
            log(f"staging 文件夹已同步补齐: {args.staging}")

    if args.sha256sums and not args.what_if and produced:
        sums = out / "SHA256SUMS.txt"
        lines = {ln.split()[-1]: ln for ln in
                 (sums.read_text(encoding="utf-8").splitlines() if sums.exists() else [])}
        for p in produced:
            lines[p.name] = f"{sha256_file(p)}  {p.name}"
        # newline="\n" 钉死 LF：Windows 文本模式默认把 \n 翻译成 CRLF，
        # 产物在 GNU sha256sum -c 下全行不匹配（2026-11-09 真机登记）。
        sums.write_text("\n".join(lines[k] for k in sorted(lines)) + "\n",
                        encoding="utf-8", newline="\n")
        log(f"SHA256SUMS.txt 已更新（{len(lines)} 条）")
    log("完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
