"""Windows 发布策略（从 release.py 迁入，2026-11-20；行为逐字不变）。

Windows 的两个平台特性都封装在这里，不泄漏到通用编排：

- **两档资源 + 同名构建**：portable 在 light 与 full 下构建名相同，靠
  「先 light 后 full」+ 交付名带 `-Full-`/`-Light-` 后缀区分。
- **Setup 单体**：只有 full 档出 Setup，且打完必须做尾块自检（magic /
  偏移 / 载荷 SHA256 / 双 zip 条目数）。
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from .. import paths
from ..common import die, log
from ..deliver import DeliveryItem
from ..naming import ArtifactNames
from ..release_api import Gate
from ..staging import describe_staging
from . import driver as driver_mod
from . import installer_build, toolchain
from .setup_image import verify as verify_setup

PACK_PY = paths.WINDOWS_DIR / "pack.py"

# 档位计划：顺序即执行顺序（light 必须先于 full）。
TIER_PLANS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("light", ("portable",)),
    ("full", ("driver", "portable", "setup")),
)


class _AutoDiscoverArgs:
    """预检时给 resolve_apo_assets 用的空参数（全部走自动发现）。"""

    apo_inspect = None
    apo_config = None
    apo_dll = None
    apo_engine = None


class WindowsPlan:
    name = "windows"

    # ---- 门禁 ----
    def preflight(self, tiers: list[str]) -> list[Gate]:
        gates: list[Gate] = []

        staging_ok = (paths.STAGING_DIR / "auradsp_app.exe").is_file()
        gates.append(Gate("staging", "OK" if staging_ok else "FAIL",
                          describe_staging(paths.STAGING_DIR)))

        ddir = driver_mod.find_driver_dir(None)
        problems = driver_mod.check_driver_freshness(ddir) if ddir else ["目录缺失"]
        gates.append(Gate(
            "VAIO 驱动", "FAIL" if problems else "OK",
            driver_mod.describe(ddir) if not problems else problems[0][:80]))

        asio = toolchain.find_asio_driver(None)
        gates.append(Gate("ASIO 驱动", "OK" if asio else "FAIL",
                          asio.name if asio else "找不到 auraasio_driver.dll"))

        try:
            apo = toolchain.resolve_apo_assets(_AutoDiscoverArgs())
            gates.append(Gate("APO 四件", "OK", toolchain.describe_apo(apo)))
        except SystemExit as exc:
            gates.append(Gate("APO 四件", "FAIL",
                              str(exc).split("error:")[-1].strip()[:80]))

        if any("setup" in modes for tier, modes in TIER_PLANS if tier in tiers):
            status = installer_build.installer_dir_status()
            gates.append(Gate(
                "安装器构建",
                "OK" if status == "就绪" else "WARN",
                status if status == "就绪" else "缺失；打包时用 --build-installer 现建"))

        for tier in tiers:
            required = {
                "light": ("auradsp-resource-core.zip",
                          "auradsp-addon-headphone-ddc.zip"),
                "full": ("auradsp-resource-full.zip",),
            }.get(tier, ())
            missing = [n for n in required if not (paths.PACKS_DIR / n).is_file()]
            gates.append(Gate(f"资源包/{tier}", "FAIL" if missing else "OK",
                              f"缺 {', '.join(missing)}" if missing
                              else f"{len(required)} 件齐备"))
        return gates

    # ---- 计划 ----
    def tier_plans(self, tiers: list[str]):
        return tuple((t, m) for t, m in TIER_PLANS if t in tiers)

    def default_tiers(self) -> tuple[str, ...]:
        return ("light", "full")

    def normalize_tiers(self, requested: list[str]) -> list[str]:
        tiers = [t for t in ("light", "full") if t in set(requested)]
        if not tiers:
            raise die("--resources-tiers 至少要给一个档位（light / full）")
        return tiers

    def versions_note(self, ver: dict[str, str]) -> str:
        names = ArtifactNames(ver["AURADSP_TAG"])
        return f"{ver['AURADSP_TAG']}（{names.build('portable')} 等）"

    # ---- 执行 ----
    def prepare(self, build: bool) -> None:
        if not build:
            return
        if sys.platform != "win32":
            raise die("--build 只能在 Windows 上执行（build_windows.ps1）")
        log("全栈构建（build_windows.ps1）…")
        subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(paths.BUILD_WINDOWS_PS1), "-BuildType", "Release"],
            cwd=paths.ROOT, check=True)
        log("构建完成")

    def run_pack(self, tier: str, modes: tuple[str, ...], out_dir: Path,
                 what_if: bool) -> None:
        cmd = [sys.executable, str(PACK_PY),
               "--mode", ",".join(modes),
               "--resources", tier,
               "--out", str(out_dir)]
        # --what-if 不得触发真构建：构建向导要几分钟且会改写 build/installer。
        # 预检已把「安装器构建目录缺失」标成 WARN，真打时再建。
        if "setup" in modes and not what_if:
            cmd.append("--build-installer")
        if what_if:
            cmd.append("--what-if")
        log(f"打包[{tier}]: {' '.join(cmd[2:])}")
        subprocess.run(cmd, cwd=paths.ROOT, check=True)

    def expected_artifacts(self, tier: str, modes: tuple[str, ...],
                           out_dir: Path, ver: dict[str, str]) -> dict[str, Path]:
        names = ArtifactNames(ver["AURADSP_TAG"])
        # staging 模式就地补齐目录，没有独立产物文件
        return {m: out_dir / names.build(m) for m in modes if m != "staging"}

    def collect(self, tier_outputs, ver: dict[str, str]) -> list[DeliveryItem]:
        names = ArtifactNames(ver["AURADSP_TAG"])
        tiers = list(tier_outputs)
        items: list[DeliveryItem] = []
        if "full" in tier_outputs:
            out = tier_outputs["full"]
            if "driver" in out:
                items.append(DeliveryItem(out["driver"], names.delivery("driver"),
                                          "VAIO 驱动 + ASIO + APO 四件"))
            if "setup" in out:
                items.append(DeliveryItem(out["setup"], names.delivery("setup"),
                                          "自研安装向导（full 资源档）"))
        for tier in ("full", "light"):
            if tier in tiers and "portable" in tier_outputs.get(tier, {}):
                items.append(DeliveryItem(
                    tier_outputs[tier]["portable"],
                    names.delivery("portable", tier),
                    f"绿色便携（{tier} 资源档）"))
        return items

    def post_check(self, files: list[Path], ver: dict[str, str]) -> None:
        names = ArtifactNames(ver["AURADSP_TAG"])
        setup = next((p for p in files if p.name == names.delivery("setup")), None)
        if setup is None:
            return
        log("Setup 自检…")
        if not verify_setup(setup):
            raise die(f"Setup 自检失败: {setup}")


__all__ = ["WindowsPlan", "TIER_PLANS"]
