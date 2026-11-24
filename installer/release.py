#!/usr/bin/env python3
"""AuraDSP 统一发布编排（跨平台，2026-11-20）。

定位：**只编排，不发明**。构建、打包、自检、命名都各有归属，本脚本负责
「顺序、门禁、归集、清单」这几件靠手工最容易出错的事：

  1. 预检   平台门禁表（各平台自己定义要看什么）
  2. 构建   （可选，--build）
  3. 打包   按平台档位计划顺序执行
  4. 归集   <out-root>/deliver-rNN/ 按交付名摆齐
  5. 清单   SHA256SUMS-rNN.txt（大写、LF）+ RELEASE-rNN.txt 说明卡
  6. 自检   平台封装结构校验（Windows: Setup 尾块；Linux: dpkg-deb/tar）

平台差异全部在 `packkit/<platform>/release_plan.py` 里，本文件不含任何
`if platform == ...` 分支——加 macOS 只需再写一份策略。

Windows 的「先 light 后 full」与 Linux 的「单档位」都是各自的硬约束，
分别由两个策略模块保证（见各自 docstring）。

发布（上传 Release / 投放）**未接线**：`--publish` 会明确失败，避免有人
以为它已经把包传出去了。
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

_INSTALLER_DIR = Path(__file__).resolve().parent
if str(_INSTALLER_DIR) not in sys.path:
    sys.path.insert(0, str(_INSTALLER_DIR))

from packkit import paths  # noqa: E402
from packkit.common import (  # noqa: E402
    die,
    log,
    open_progress_ui,
    reconfigure_streams,
    ui_cancelled,
    ui_step,
)
from packkit.deliver import (  # noqa: E402
    DeliveryResult,
    make_dir,
    materialize,
    write_note,
    write_sums,
)
from packkit.hashing import sha256_file  # noqa: E402
from packkit.naming import next_round  # noqa: E402
from packkit.release_api import Gate, PlatformPlan  # noqa: E402
from packkit.version import resolve_version  # noqa: E402


def _plan_for(platform: str, bundle: Path | None) -> PlatformPlan:
    """按 --platform 取策略对象（延迟导入：只加载用到的平台层）。"""
    if platform == "windows":
        from packkit.windows.release_plan import WindowsPlan

        return WindowsPlan()
    if platform == "linux":
        from packkit.linux.release_plan import LinuxPlan

        return LinuxPlan(bundle)
    raise die(f"未知平台: {platform}（可选 windows / linux）")


def _git(*argv: str) -> str:
    try:
        r = subprocess.run(["git", *argv], cwd=paths.ROOT,
                           capture_output=True, text=True, errors="replace")
    except OSError:
        # 最小化环境可能没装 git：门禁退化为 unknown，不该因此崩掉发布
        return ""
    return (r.stdout or "").strip()


def _head() -> tuple[str, bool]:
    head = _git("rev-parse", "--short", "HEAD") or "unknown"
    dirty = bool(_git("status", "--porcelain"))
    return head, dirty


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


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="AuraDSP 统一发布编排（预检 → 打包 → 归集 → 清单）")
    ap.add_argument("--platform", default="windows", choices=("windows", "linux"),
                    help="目标平台（默认 windows；linux 需在 Linux/WSL 执行）")
    ap.add_argument("--round", type=int, help="交付轮次（默认按已有 deliver-rN 自增）")
    ap.add_argument("--out-root", type=Path, default=paths.DIST_DIR,
                    help="交付根目录（默认 dist/；交付落在 <out-root>/deliver-rNN）")
    ap.add_argument("--work-dir", type=Path,
                    help="打包中间目录（默认 <out-root>/.release-rNN）")
    ap.add_argument("--resources-tiers", default=None,
                    help="资源档位，逗号分隔（Windows 默认 full,light；Linux 只能一个）")
    ap.add_argument("--bundle", type=Path, default=None,
                    help="Linux：Flutter bundle 目录（默认 build/linux/.../bundle）")
    ap.add_argument("--build", action="store_true",
                    help="先跑平台全栈构建（Windows: build_windows.ps1；Linux: cmake+flutter+sync）")
    ap.add_argument("--plan", action="store_true", help="只打印计划与门禁，不执行")
    ap.add_argument("--dry-run", action="store_true", help="用 --what-if 跑资产探测，不落产物")
    ap.add_argument("--strict", action="store_true", help="--plan 遇 FAIL 也以非零退出")
    ap.add_argument("--clean-work", action="store_true", help="完成后删除中间目录")
    ap.add_argument("--publish", action="store_true",
                    help="发布（未接线；本轮只落工具）")
    ap.add_argument("--no-progress-ui", action="store_true",
                    help="不打开进度小窗（默认打开；等效 AURADSP_NO_UI=1）")
    return ap.parse_args(argv)


_CLEAN_WORK_NAME = re.compile(r"^\.release-r\d+$")


def clean_work_dir(work_dir: Path, out_root: Path) -> None:
    """--clean-work 的受控清理（AUD-02，2026-11-20 审查）。

    --work-dir 可传任意路径，旧实现对其直接 rmtree(ignore_errors=True)：
    误传仓库根、交付目录或其他目录即不可逆删除且无声。清理只允许一种
    目标：out-root 直下、按发布约定命名的中间目录（.release-rNN，即
    默认值的形状）。路径先 resolve（符号链接按真实落点判），越界一律
    die 明确报错；目录不存在视为无事可做（未生成/已清理），不报错。
    """
    resolved_work = work_dir.resolve()
    resolved_out = out_root.resolve()
    if (resolved_work.parent != resolved_out
            or not _CLEAN_WORK_NAME.match(resolved_work.name)):
        raise die(
            f"--clean-work 拒绝清理非受控目录: {work_dir}"
            f"（解析为 {resolved_work}）。只允许清理 {resolved_out} 直下的"
            " .release-rNN 发布中间目录；如确需删除该目录请手工处理。")
    if not resolved_work.exists():
        log(f"中间目录不存在，无需清理: {work_dir}")
        return
    shutil.rmtree(resolved_work)
    log(f"已清理中间目录: {work_dir}")


def _split_tiers(raw: str | None) -> list[str] | None:
    if raw is None:
        return None
    return [t.strip() for t in raw.split(",") if t.strip()]


def main(argv: list[str]) -> int:
    # 进度小窗（2026-11-24）：编排层开窗，[pack] 日志自动镜像；子进程
    # （pack/build）置 AURADSP_UI_NESTED 抑制另开窗。UI 故障不影响编排。
    if "--no-progress-ui" in argv:
        import os

        os.environ["AURADSP_NO_UI"] = "1"
    # 只读调用不开窗（审查 F-5，2026-11-24）：--help/--plan 不落产物，
    # 开窗只会留下一扇误报「失败」的窗（argparse 的 SystemExit(0)）。
    if any(a in argv for a in ("-h", "--help", "--plan")):
        return _main_impl(argv)
    ui = open_progress_ui("AuraDSP 发布编排")
    if ui is not None:
        import os

        os.environ.setdefault("AURADSP_UI_NESTED", "1")
        # 中继（文件）模式下把事件文件路径传给子进程：build_windows.ps1
        # 的步骤横幅会 append 进同一个窗口。
        if getattr(ui, "events_path", None):
            os.environ["AURADSP_PROGRESS_EVENTS"] = ui.events_path
    try:
        rc = _main_impl(argv)
    except SystemExit as exc:
        if ui is not None:
            if exc.code in (0, None):
                ui.done(ok=True, text="")
            else:
                ui.done(ok=False, text=str(exc)[:120])
        raise
    if ui is not None:
        ui.done(ok=rc == 0, text="发布编排完成" if rc == 0 else f"退出码 {rc}")
    return rc


def _main_impl(argv: list[str]) -> int:
    reconfigure_streams()
    args = parse_args(argv)
    if args.publish:
        raise die("发布通道未接线（2026-11-20 裁定：本轮只落工具，不发布）。"
                  "产物已归集，投放/上传请手工执行并复核哈希。")

    ver = resolve_version()
    plan = _plan_for(args.platform, args.bundle)

    requested = _split_tiers(args.resources_tiers)
    tiers = plan.normalize_tiers(
        requested if requested is not None else list(plan.default_tiers()))
    tier_plans = plan.tier_plans(tiers)

    round_no = next_round(args.out_root, args.round)
    deliver_dir = args.out_root / f"deliver-r{round_no}"
    work_dir = args.work_dir or (args.out_root / f".release-r{round_no}")

    gates = plan.preflight(tiers)

    # 版本/提交不属于任何平台，编排层统一补在最前面，门禁表读起来完整
    try:
        resolve_version()
        ver_gate = Gate("版本真相源", "OK",
                        f"{ver['AURADSP_TAG']}（build {ver['AURADSP_BUILD']}）")
    except SystemExit as exc:
        ver_gate = Gate("版本真相源", "FAIL", str(exc))
    head, dirty = _head()
    gates = [ver_gate,
             Gate("git 头", "WARN" if dirty else "OK",
                  f"{head}{'（工作区有未提交改动）' if dirty else ''}"),
             *gates]

    order = " → ".join(t for t, _ in tier_plans)
    print(f"\nAuraDSP 发布计划 r{round_no}（{plan.name}）")
    print(f"  版本      {plan.versions_note(ver)}")
    print(f"  档位      {', '.join(tiers)}（执行顺序 {order}）")
    print(f"  交付目录  {deliver_dir}")
    print(f"  中间目录  {work_dir}")
    print(f"  构建      {'是' if args.build else '否（复用现有产物）'}")
    print("\n门禁：")
    print_gates(gates)

    if args.plan:
        print("\n（--plan 只读；未写任何文件）")
        return 1 if (args.strict and any(g.status == "FAIL" for g in gates)) else 0

    blocking = [g for g in gates if g.status == "FAIL"]
    if blocking and not args.dry_run:
        print()
        raise die("预检未通过：" + "；".join(f"{g.name}={g.detail}" for g in blocking))

    if not args.dry_run:
        ui_step("构建" if args.build else "准备（复用现有产物）")
        plan.prepare(args.build)
        work_dir.mkdir(parents=True, exist_ok=True)

    tier_outputs: dict[str, dict[str, Path]] = {}
    for tier, modes in tier_plans:
        out_dir = work_dir / tier
        if not args.dry_run:
            out_dir.mkdir(parents=True, exist_ok=True)
        if ui_cancelled():
            raise die("用户从进度窗取消发布")
        ui_step(f"打包档位 {tier}")
        plan.run_pack(tier, modes, out_dir, what_if=args.dry_run)
        # 产物名由各平台命名真相源给：编排层不猜名字
        tier_outputs[tier] = plan.expected_artifacts(tier, modes, out_dir, ver)

    if args.dry_run:
        print("\n（--dry-run 完成：资产探测通过，未落任何产物）")
        return 0

    ui_step("归集与清单")
    items = plan.collect(tier_outputs, ver)
    dest = make_dir(args.out_root, round_no)
    result = DeliveryResult(dir=dest)
    result.files = materialize(dest, items)
    result.sums = write_sums(dest, round_no, result.files)

    head, dirty = _head()
    result.note = write_note(dest, round_no, {
        "platform": plan.name,
        "version": ver["AURADSP_TAG"],
        "build": ver["AURADSP_BUILD"],
        "commit": head,
        "worktree_dirty": "yes" if dirty else "no",
        "resources_tiers": ",".join(tiers),
        "generated_by": "installer/release.py",
    })

    ui_step("封装自检")
    plan.post_check(result.files, ver)

    if args.clean_work:
        clean_work_dir(work_dir, args.out_root)

    print(f"\n交付就绪: {dest}")
    for p in result.files:
        print(f"  {sha256_file(p).upper()[:16]}…  {p.stat().st_size:>12}  {p.name}")
    print(f"  {result.sums.name} / {result.note.name}")
    print("\n未发布（--publish 未接线）；投放请手工执行并复核哈希。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
