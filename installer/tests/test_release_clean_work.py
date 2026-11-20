#!/usr/bin/env python3
"""release.py --clean-work 清理边界单测（AUD-02，2026-11-20）。

旧实现对用户传入的 --work-dir 直接 rmtree(ignore_errors=True)，误传
仓库根/交付目录即不可逆删除且无声。本文件只在临时目录内操作，断言：

- out-root 直下、按约定命名的 .release-rNN 中间目录可被清理；
- 其余一切目标（out-root 本身、deliver-rNN、外部同名目录、深层嵌套、
  无点前缀名、指向外部的符号链接）一律拒绝且目标完好；
- 目标不存在时是无声无事的 no-op（不报错）。

不引入 pytest：本仓测试一律 `python <file>` 直跑，CI 亦同。
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

_INSTALLER = Path(__file__).resolve().parents[1]
if str(_INSTALLER) not in sys.path:
    sys.path.insert(0, str(_INSTALLER))

import release  # noqa: E402

FAIL: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        FAIL.append(name)


def expect_refused(name: str, work: Path, out_root: Path) -> None:
    try:
        release.clean_work_dir(work, out_root)
    except SystemExit:
        check(name, work.exists() or work.is_symlink(),
              "拒绝了但目标已消失")
        return
    check(name, False, "未拒绝（已执行清理或静默通过）")


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        out_root = base / "dist"
        out_root.mkdir()

        # 1. 合法目标：out-root 直下的 .release-rNN，含内容
        good = out_root / ".release-r7"
        (good / "tier").mkdir(parents=True)
        (good / "tier" / "f.bin").write_bytes(b"x")
        release.clean_work_dir(good, out_root)
        check("合法 .release-rNN 被清理", not good.exists())
        check("out-root 本身保留", out_root.exists())

        # 2. work == out-root 本身
        expect_refused("拒绝清理 out-root 本身", out_root, out_root)

        # 3. 交付目录 deliver-rNN
        deliver = out_root / "deliver-r7"
        deliver.mkdir()
        expect_refused("拒绝清理 deliver-rNN", deliver, out_root)

        # 4. out-root 之外的同名目录（兄弟目录）
        outside = base / ".release-r7"
        outside.mkdir()
        expect_refused("拒绝清理 out-root 外的同名目录", outside, out_root)

        # 5. 深层嵌套（非直下）
        nested = out_root / "sub" / ".release-r7"
        nested.mkdir(parents=True)
        expect_refused("拒绝清理深层嵌套目录", nested, out_root)

        # 6. 无点前缀的名字
        nodot = out_root / "release-r7"
        nodot.mkdir()
        expect_refused("拒绝清理无点前缀目录", nodot, out_root)

        # 7. 符号链接逃逸：out-root 内 .release-rNN 是指向外部的链接
        target = base / "elsewhere"
        target.mkdir()
        (target / "keep.txt").write_text("keep")
        link = out_root / ".release-r9"
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError:
            print("SKIP  符号链接用例（平台不允许创建）")
        else:
            expect_refused("拒绝经符号链接清理外部目录", link, out_root)
            check("符号链接目标内容完好", (target / "keep.txt").exists())

        # 8. 不存在的合法形状目录：no-op，不抛
        try:
            release.clean_work_dir(out_root / ".release-r3", out_root)
        except SystemExit as exc:
            check("不存在目录为 no-op", False, f"不应报错: {exc}")
        else:
            check("不存在目录为 no-op", True)

    print()
    if FAIL:
        print("CLEAN-WORK FAILURES:", FAIL)
        return 1
    print("release clean-work: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
