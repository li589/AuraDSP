#!/usr/bin/env python3
"""AuraDSP 统一发布编排（跨平台，2026-11-20）。

定位：**只编排，不发明**。构建交给 `tools/windows/build_windows.ps1`，打包
交给 `installer/windows/pack.py`（同一个 packkit 内核），本脚本负责「顺序、
门禁、命名、归集、清单」这五件容易靠手工出错的事。

标准一次发布：

  1. 预检   版本真相源、git 头、staging、驱动新鲜度、ASIO/APO 四件、
            安装器构建目录、资源包档位、工具链
  2. 构建   （可选，--build）全栈构建 → dist/AuraDSP-Windows-x64
  3. 打包   先 light（改名后不覆盖）、再 full + setup + driver
  4. 归集   dist/deliver-rNN/ 四件按交付名摆齐
  5. 清单   SHA256SUMS-rNN.txt（大写、LF）+ RELEASE-rNN.txt 说明卡
  6. 自检   Setup 尾块/偏移/载荷哈希/双 zip 复算

为什么顺序是「先 light 后 full」：两者构建名相同
（`AuraDSP-Windows-x64-v0.1.0.zip`），先打 full 再打 light 会把 full 覆盖成
light（2026-11-12 实测中招，靠条目数 595/2567 才复核回来）。

发布（上传 Release / 投放）**本轮未接线**：`--publish` 会明确失败，避免
有人以为它已经把包传出去了。
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

_INSTALLER_DIR = Path(__file__).resolve().parent
if str(_INSTALLER_DIR) not in sys.path:
    sys.path.insert(0, str(_INSTALLER_DIR))

from packkit import paths  # noqa: E402
from packkit.common import die, log  # noqa: E402
from packkit.deliver import (  # noqa: E402
    DeliveryItem,
    DeliveryResult,
    make_dir,
    materialize,
    write_note,
    write_sums,
)
from packkit.hashing import sha256_file  # noqa: E402
from packkit.naming import ArtifactNames, next_round  # noqa: E402
from packkit.staging import describe_staging  # noqa: E402
from packkit.version import resolve_version  # noqa: E402
from packkit.windows import driver as driver_mod  # noqa: E402
from packkit.windows import installer_build  # noqa: E402
from packkit.windows import toolchain  # noqa: E402
from packkit.windows.setup_image import verify as verify_setup  # noqa: E402

PACK_PY = paths.WINDOWS_DIR / "pack.py"

# 档位计划：**顺序即执行顺序**（light 必须先于 full，见模块 docstring）。
TIER_PLANS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("light", ("portable",)),
    ("full", ("driver", "portable", "setup")),
)


@dataclass
class Gate:
    name: str
    status: str  # OK / WARN / FAIL
    detail: str = ""

    @property
    def icon(self) -> str:
        return {"OK": "✓", "WARN": "!", "FAIL": "✗"}.get(self.status, "?")


def _git(*argv: str) -> str:
    r = subprocess.run(["git", *argv], cwd=paths.ROOT,
                       capture_output=True, text=True, errors="replace")
    return (r.stdout or "").strip()


def _head() -> tuple[str, bool]:
    head = _git("rev-parse", "--short", "HEAD") or "unknown"
    dirty = bool(_git("status", "--porcelain"))
    return head, dirty


def preflight(tiers: list[str], need_installer: bool) -> list[Gate]:
    """所有「打包前必须成立」的条件，逐条给状态，不抛异常。"""
    gates: list[Gate] = []

    try:
        ver = resolve_version()
        gates.append(Gate("版本真相源", "OK",
                          f"{ver['AURADSP_TAG']}（build {ver['AURADSP_BUILD']}）"))
    except SystemExit as exc:
        gates.append(Gate("版本真相源", "FAIL", str(exc)))

    head, dirty = _head()
    gates.append(Gate("git 头", "WARN" if dirty else "OK",
                      f"{head}{'（工作区有未提交改动）' if dirty else ''}"))

    staging_ok = (paths.STAGING_DIR / "auradsp_app.exe").is_file()
    gates.append(Gate("staging", "OK" if staging_ok else "FAIL",
                      describe_staging(paths.STAGING_DIR)))

    ddir = driver_mod.find_driver_dir(None)
    problems = driver_mod.check_driver_freshness(ddir) if ddir else ["目录缺失"]
    gates.append(Gate("VAIO 驱动", "FAIL" if problems else "OK",
                      driver_mod.describe(ddir) if not problems else problems[0][:80]))

    asio = toolchain.find_asio_driver(None)
    gates.append(Gate("ASIO 驱动", "OK" if asio else "FAIL",
                      asio.name if asio else "找不到 auraasio_driver.dll"))

    try:
        apo = toolchain.resolve_apo_assets(_Args())
        gates.append(Gate("APO 四件", "OK", toolchain.describe_apo(apo)))
    except SystemExit as exc:
        gates.append(Gate("APO 四件", "FAIL", str(exc).split("error:")[-1].strip()[:80]))

    if need_installer:
        status = installer_build.installer_dir_status()
        gates.append(Gate(
            "安装器构建",
            "OK" if status == "就绪" else "WARN",
            status if status == "就绪" else "缺失；打包时用 --build-installer 现建"))

    for tier in tiers:
        packs = paths.PACKS_DIR
        required = {
            "light": ("auradsp-resource-core.zip", "auradsp-addon-headphone-ddc.zip"),
            "full": ("auradsp-resource-full.zip",),
        }.get(tier, ())
        missing = [n for n in required if not (packs / n).is_file()]
        gates.append(Gate(f"资源包/{tier}", "FAIL" if missing else "OK",
                          f"缺 {', '.join(missing)}" if missing else f"{len(required)} 件齐备"))

    return gates


class _Args:
    """预检时给 resolve_apo_assets 用的空参数（全部走自动发现）。"""

    apo_inspect = None
    apo_config = None
    apo_dll = None
    apo_engine = None


def _display_width(text: str) -> int:
    """终端显示宽度（CJK 全角算 2）。

    `str.ljust` 按字符数补齐，中文名会把表格挤歪；门禁表是要给人看的，
    按显示宽度对齐才真的对齐。
    """
    import unicodedata

    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def _pad(text: str, width: int) -> str:
    return text + " " * max(0, width - _display_width(text))


def print_gates(gates: list[Gate]) -> None:
    width = max(_display_width(g.name) for g in gates) + 2
    for g in gates:
        print(f"  {g.icon} {_pad(g.name, width)}{g.detail}")
    fails = [g for g in gates if g.status == "FAIL"]
    if fails:
        print(f"\n  {len(fails)} 项阻塞：{', '.join(g.name for g in fails)}")


def run_build() -> None:
    if sys.platform != "win32":
        raise die("--build 只能在 Windows 上执行（build_windows.ps1）")
    log("全栈构建（build_windows.ps1）…")
    subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
         "-File", str(paths.BUILD_WINDOWS_PS1), "-BuildType", "Release"],
        cwd=paths.ROOT, check=True)
    log("构建完成")


def run_pack(tier: str, modes: tuple[str, ...], out_dir: Path,
             what_if: bool, build_installer: bool) -> None:
    cmd = [sys.executable, str(PACK_PY),
           "--mode", ",".join(modes),
           "--resources", tier,
           "--out", str(out_dir)]
    # --what-if 不得触发真构建：构建向导要几分钟且会改写 build/installer。
    # 预检已把「安装器构建目录缺失」标成 WARN，真打时再建。
    if build_installer and not what_if:
        cmd.append("--build-installer")
    if what_if:
        cmd.append("--what-if")
    log(f"打包[{tier}]: {' '.join(cmd[2:])}")
    subprocess.run(cmd, cwd=paths.ROOT, check=True)


def collect(tier_outputs: dict[str, dict[str, Path]], names: ArtifactNames,
            tiers: list[str]) -> list[DeliveryItem]:
    """把各档位产物映射成交付物（交付名单一真相源在 naming.py）。"""
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


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="AuraDSP 统一发布编排（预检 → 打包 → 归集 → 清单）")
    ap.add_argument("--round", type=int, help="交付轮次（默认按已有 deliver-rN 自增）")
    ap.add_argument("--out-root", type=Path, default=paths.DIST_DIR,
                    help="交付根目录（默认 dist/；交付落在 <out-root>/deliver-rNN）")
    ap.add_argument("--work-dir", type=Path,
                    help="打包中间目录（默认 <out-root>/.release-rNN）")
    ap.add_argument("--resources-tiers", default="full,light",
                    help="要打的资源档位，逗号分隔（默认 full,light；light 恒先于 full）")
    ap.add_argument("--build", action="store_true", help="先跑全栈构建（Windows）")
    ap.add_argument("--plan", action="store_true", help="只打印计划与门禁，不执行")
    ap.add_argument("--dry-run", action="store_true", help="用 --what-if 跑资产探测，不落产物")
    ap.add_argument("--strict", action="store_true", help="--plan 遇 FAIL 也以非零退出")
    ap.add_argument("--clean-work", action="store_true", help="完成后删除中间目录")
    ap.add_argument("--publish", action="store_true",
                    help="发布（未接线；本轮只落工具）")
    return ap.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.publish:
        raise die("发布通道未接线（2026-11-20 裁定：本轮只落工具，不发布）。"
                  "产物已归集，投放/上传请手工执行并复核哈希。")

    ver = resolve_version()
    names = ArtifactNames(ver["AURADSP_TAG"])
    tiers = [t for t in ("light", "full")
             if t in {x.strip() for x in args.resources_tiers.split(",")}]
    if not tiers:
        raise die("--resources-tiers 至少要给一个档位（light / full）")

    round_no = next_round(args.out_root, args.round)
    deliver_dir = args.out_root / f"deliver-r{round_no}"
    work_dir = args.work_dir or (args.out_root / f".release-r{round_no}")

    need_installer = any("setup" in modes for tier, modes in TIER_PLANS
                         if tier in tiers)
    gates = preflight(tiers, need_installer)

    print(f"\nAuraDSP 发布计划 r{round_no}")
    print(f"  版本      {ver['AURADSP_TAG']}（{names.build('portable')} 等）")
    print(f"  档位      {', '.join(tiers)}（light 先于 full）")
    print(f"  交付目录  {deliver_dir}")
    print(f"  中间目录  {work_dir}")
    print(f"  构建      {'是' if args.build else '否（复用现有 staging）'}")
    print("\n门禁：")
    print_gates(gates)

    if args.plan:
        print("\n（--plan 只读；未写任何文件）")
        return 1 if (args.strict and any(g.status == "FAIL" for g in gates)) else 0

    blocking = [g for g in gates if g.status == "FAIL"]
    if blocking and not args.dry_run:
        print()
        raise die("预检未通过：" + "；".join(f"{g.name}={g.detail}" for g in blocking))

    if args.build and not args.dry_run:
        run_build()

    if not args.dry_run:
        work_dir.mkdir(parents=True, exist_ok=True)

    tier_outputs: dict[str, dict[str, Path]] = {}
    for tier, modes in TIER_PLANS:
        if tier not in tiers:
            continue
        out_dir = work_dir / tier
        if not args.dry_run:
            out_dir.mkdir(parents=True, exist_ok=True)
        run_pack(tier, modes, out_dir, what_if=args.dry_run,
                 build_installer=("setup" in modes))
        tier_outputs[tier] = {
            m: out_dir / names.build(m) for m in modes if m != "staging"}

    if args.dry_run:
        print("\n（--dry-run 完成：资产探测通过，未落任何产物）")
        return 0

    items = collect(tier_outputs, names, tiers)
    dest = make_dir(args.out_root, round_no)
    result = DeliveryResult(dir=dest)
    result.files = materialize(dest, items)
    result.sums = write_sums(dest, round_no, result.files)

    head, dirty = _head()
    result.note = write_note(dest, round_no, {
        "version": ver["AURADSP_TAG"],
        "build": ver["AURADSP_BUILD"],
        "commit": head,
        "worktree_dirty": "yes" if dirty else "no",
        "resources_tiers": ",".join(tiers),
        "generated_by": "installer/release.py",
    })

    setup_exe = next((p for p in result.files if p.name == names.delivery("setup")), None)
    if setup_exe is not None:
        log("Setup 自检…")
        if not verify_setup(setup_exe):
            raise die(f"Setup 自检失败: {setup_exe}")

    if args.clean_work:
        import shutil

        shutil.rmtree(work_dir, ignore_errors=True)
        log(f"已清理中间目录: {work_dir}")

    print(f"\n交付就绪: {dest}")
    for p in result.files:
        print(f"  {sha256_file(p).upper()[:16]}…  {p.stat().st_size:>12}  {p.name}")
    print(f"  {result.sums.name} / {result.note.name}")
    print("\n未发布（--publish 未接线）；投放请手工执行并复核哈希。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
