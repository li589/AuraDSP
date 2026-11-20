"""Linux 发布策略（2026-11-20 收编）。

与 Windows 的结构差异，全部收敛在这一个文件里：

- **四件固定组合**：deb / driver / appimage / portable 一次全出，没有
  「选几个模式」的发布概念（`pack.py --only` 是排障用的，不是发布用的）。
- **单档位**：产物名不含档位后缀（03 §5），所以一次发布只能一个资源档位。
  `normalize_tiers` 在这里把多档请求直接拒掉，而不是让后打的包静默覆盖。
- **无 Setup**：Linux 没有自研安装器，deb 由 apt 消费。
- **自检靠 dpkg/tar**：没有 Windows 那种 80 字节尾块，改为调
  `dpkg-deb --info/--contents` 与 `tar -tzf` 验证封装可读——这正是用户
  装包时 dpkg 会做的事，比自研校验更贴近真实失败面。
"""

from __future__ import annotations

import platform
import shutil
import subprocess
import sys
from pathlib import Path

from .. import paths
from ..common import die, log
from ..deliver import DeliveryItem
from ..naming import LINUX_MODES, LinuxArtifactNames
from ..release_api import Gate
from . import appimage

PACK_PY = paths.LINUX_DIR / "pack.py"

# Linux 打包的硬依赖（缺任一件都做不出可用的包）
REQUIRED_TOOLS = {
    "dpkg-deb": "deb 封装",
    "gzip": "changelog 压缩（-n 保证可复现）",
    "du": "Installed-Size 口径",
    "tar": "便携包",
}


def _tool_missing() -> list[str]:
    return [f"{c}（{why}）" for c, why in REQUIRED_TOOLS.items()
            if shutil.which(c) is None]


def _bundle_problems(bundle: Path) -> list[str]:
    """逐项列出 bundle 缺件，不抛异常（预检要一次看全，而不是看第一条）。"""
    if not bundle.is_dir():
        return [f"bundle 目录不存在: {bundle}"]
    problems = []
    for rel in paths.LINUX_BUNDLE_REQUIRED:
        p = bundle / rel
        if not p.is_file():
            problems.append(rel)
        elif rel == "auradsp_app" and not (p.stat().st_mode & 0o111):
            problems.append(f"{rel}（不可执行）")
    return problems


class LinuxPlan:
    name = "linux"

    def __init__(self, bundle: Path | None = None) -> None:
        self.bundle = bundle or paths.LINUX_BUNDLE

    # ---- 门禁 ----
    def preflight(self, tiers: list[str]) -> list[Gate]:
        gates: list[Gate] = []

        if sys.platform != "linux":
            gates.append(Gate(
                "平台", "FAIL",
                "Linux 打包需在 Linux/WSL 执行（dpkg-deb 等不可替代）"))
        else:
            gates.append(Gate("平台", "OK", f"{sys.platform}/{platform.machine()}"))

        missing = _tool_missing()
        gates.append(Gate(
            "打包工具", "FAIL" if missing else "OK",
            f"缺 {', '.join(missing)}" if missing else
            f"{len(REQUIRED_TOOLS)} 件齐备（dpkg-deb/gzip/du/tar）"))

        problems = _bundle_problems(self.bundle)
        gates.append(Gate(
            "bundle", "FAIL" if problems else "OK",
            f"缺 {', '.join(problems)}" if problems else "四件载荷齐备"))

        for tier in tiers:
            required = {
                "full": ("auradsp-resource-full.zip",),
                "light": ("auradsp-resource-core.zip",
                          "auradsp-addon-headphone-ddc.zip"),
            }.get(tier, ())
            miss = [n for n in required if not (paths.PACKS_DIR / n).is_file()]
            gates.append(Gate(f"资源包/{tier}", "FAIL" if miss else "OK",
                              f"缺 {', '.join(miss)}" if miss
                              else (f"{len(required)} 件齐备" if required
                                    else "core：bundle 自带，无需资源包")))

        # AppImage 工具：缓存未命中只是 WARN（首次构建会按 pins 下载）；
        # 钉版表缺失或 appimagetool 的 file 依赖缺失是 FAIL。
        try:
            blocking, notes = appimage.preflight()
            if blocking:
                gates.append(Gate("AppImage 工具", "FAIL", "；".join(blocking)))
            elif notes:
                gates.append(Gate("AppImage 工具", "WARN", "；".join(notes)))
            else:
                gates.append(Gate("AppImage 工具", "OK",
                                  "appimagetool/runtime 已缓存且哈希相符"))
        except SystemExit as exc:
            gates.append(Gate("AppImage 工具", "FAIL", str(exc)[:100]))

        reserved = [m.name for m in paths.LINUX_RESERVED_MANIFESTS if m.is_file()]
        gates.append(Gate(
            "预留清单", "OK" if len(reserved) == len(paths.LINUX_RESERVED_MANIFESTS) else "WARN",
            f"flatpak/snap 清单在位（{len(reserved)}/2，不产出商店包）"
            if reserved else "flatpak/snap 清单缺失"))
        return gates

    # ---- 计划 ----
    def tier_plans(self, tiers: list[str]):
        # Linux 单档：四模式一次全出
        return ((tiers[0], LINUX_MODES),)

    def default_tiers(self) -> tuple[str, ...]:
        return ("full",)

    def normalize_tiers(self, requested: list[str]) -> list[str]:
        unique = list(dict.fromkeys(requested))
        if len(unique) > 1:
            raise die(
                "Linux 一次只能打一个资源档位（产物名不含档位，"
                f"多档会互相覆盖）：收到 {', '.join(unique)}。\n"
                "  要出两档请分两次发布（--resources-tiers 只给一个）。")
        return unique or ["core"]

    def versions_note(self, ver: dict[str, str]) -> str:
        names = LinuxArtifactNames(version=ver["AURADSP_VERSION"],
                                   tag=ver["AURADSP_TAG"])
        return (f"{ver['AURADSP_TAG']}（{names.build('deb')} / "
                f"{names.build('appimage')} 等四件）")

    # ---- 执行 ----
    def prepare(self, build: bool) -> None:
        if not build:
            return
        from . import build as build_mod
        build_mod.build_linux()

    def run_pack(self, tier: str, modes: tuple[str, ...], out_dir: Path,
                 what_if: bool) -> None:
        cmd = [sys.executable, str(PACK_PY),
               "--only", ",".join(modes),
               "--resources", tier,
               "--bundle", str(self.bundle),
               "--out", str(out_dir)]
        if what_if:
            cmd.append("--what-if")
        log(f"打包[{tier}]: {' '.join(cmd[2:])}")
        subprocess.run(cmd, cwd=paths.ROOT, check=True)

    def expected_artifacts(self, tier: str, modes: tuple[str, ...],
                           out_dir: Path, ver: dict[str, str]) -> dict[str, Path]:
        names = LinuxArtifactNames(version=ver["AURADSP_VERSION"],
                                   tag=ver["AURADSP_TAG"])
        return {m: out_dir / names.build(m) for m in modes}

    def collect(self, tier_outputs, ver: dict[str, str]) -> list[DeliveryItem]:
        names = LinuxArtifactNames(version=ver["AURADSP_VERSION"],
                                   tag=ver["AURADSP_TAG"])
        notes = {
            "deb": "正式安装包（apt/dpkg）",
            "driver": "snd-aloop 驱动配置包",
            "appimage": "便携 AppImage（无 FUSE 用 --appimage-extract）",
            "portable": "便携 tar.gz（补充形态）",
        }
        items: list[DeliveryItem] = []
        for tier, outs in tier_outputs.items():
            for mode in LINUX_MODES:
                if mode in outs:
                    items.append(DeliveryItem(outs[mode],
                                              names.delivery(mode), notes[mode]))
        return items

    def post_check(self, files: list[Path], ver: dict[str, str]) -> None:
        names = LinuxArtifactNames(version=ver["AURADSP_VERSION"],
                                   tag=ver["AURADSP_TAG"])
        for p in files:
            if p.name.endswith(".deb"):
                log(f"deb 自检: {p.name}")
                for flag in ("--info", "--contents"):
                    r = subprocess.run(["dpkg-deb", flag, str(p)],
                                       capture_output=True, text=True)
                    if r.returncode != 0:
                        raise die(f"dpkg-deb {flag} 失败: {p.name}："
                                  f"{r.stderr.strip()[:300]}")
            elif p.name.endswith(".tar.gz"):
                log(f"tar 自检: {p.name}")
                r = subprocess.run(["tar", "-tzf", str(p)],
                                   capture_output=True, text=True)
                if r.returncode != 0:
                    raise die(f"tar -tzf 失败: {p.name}：{r.stderr.strip()[:300]}")
                if "AuraDSP-Linux-x64/" not in r.stdout:
                    raise die(f"便携包缺顶层目录 AuraDSP-Linux-x64/: {p.name}")
            elif p.name == names.delivery("appimage"):
                log(f"AppImage 自检: {p.name}")
                if not (p.stat().st_mode & 0o111):
                    raise die(f"AppImage 不可执行: {p.name}")
                with p.open("rb") as fh:
                    if fh.read(4) != b"\x7fELF":
                        raise die(f"AppImage 不是 ELF 可执行文件: {p.name}")


__all__ = ["LinuxPlan"]
