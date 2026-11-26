#!/usr/bin/env python3
"""发布目录 staging / post-check / 原子提交契约测试。"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

_INSTALLER = Path(__file__).resolve().parents[1]
if str(_INSTALLER) not in sys.path:
    sys.path.insert(0, str(_INSTALLER))

import release  # noqa: E402
from packkit.deliver import DeliveryItem  # noqa: E402

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f"  {detail}"))
    if not cond:
        FAILURES.append(name)


def make_item(base: Path) -> DeliveryItem:
    source = base / "source.bin"
    source.write_bytes(b"release payload")
    return DeliveryItem(source, "artifact.bin", "test artifact")


def staging_dirs(out_root: Path, round_no: int) -> list[Path]:
    return list(out_root.glob(f".deliver-r{round_no}.staging-*"))


class FailingPlan:
    def __init__(self) -> None:
        self.failure = RuntimeError("injected post-check failure")

    def post_check(self, files, version):
        raise self.failure


class RecordingPlan:
    def __init__(self, out_root: Path, round_no: int) -> None:
        self.out_root = out_root
        self.round_no = round_no
        self.called = False
        self.final_existed = None
        self.complete_at_check = False
        self.version = None

    def post_check(self, files, version):
        self.called = True
        self.version = version
        self.final_existed = (self.out_root / f"deliver-r{self.round_no}").exists()
        if files:
            staging = files[0].parent
            self.complete_at_check = (
                staging.name.startswith(f".deliver-r{self.round_no}.staging-")
                and all(p.is_file() for p in files)
                and (staging / f"SHA256SUMS-r{self.round_no}.txt").is_file()
                and (staging / f"RELEASE-r{self.round_no}.txt").is_file()
            )


class FinalCreatingPlan(RecordingPlan):
    def post_check(self, files, version):
        super().post_check(files, version)
        final = self.out_root / f"deliver-r{self.round_no}"
        final.mkdir()
        (final / "keep.txt").write_text("keep", encoding="utf-8")


def test_stage_delivery_creates_only_nonce_staging():
    with tempfile.TemporaryDirectory() as td:
        out_root = Path(td) / "dist"
        result = release.stage_delivery(out_root, 7, [make_item(Path(td))])
        staging = staging_dirs(out_root, 7)
        check("stage 只创建一个 nonce staging", staging == [result.dir])
        check("stage 不创建正式 deliver-r7", not (out_root / "deliver-r7").exists())
        check("stage 完成 materialize", (result.dir / "artifact.bin").is_file())
        check("stage 完成 sums", (result.dir / "SHA256SUMS-r7.txt").is_file())
        check("stage 结果引用 staging", result.files == [result.dir / "artifact.bin"])


def test_failed_post_check_never_publishes_delivery():
    with tempfile.TemporaryDirectory() as td:
        out_root = Path(td)
        plan = FailingPlan()
        try:
            release.publish_delivery(out_root, 7, [], plan)
        except RuntimeError as exc:
            check("post_check 异常身份原样传播", exc is plan.failure)
        else:
            check("post_check 异常身份原样传播", False, "未抛出注入异常")
        check("失败自检不产生正式 deliver-r7", not (out_root / "deliver-r7").exists())
        staging = staging_dirs(out_root, 7)
        check("失败 staging 保留供诊断", len(staging) == 1)
        if staging:
            check("失败前 sums 与 note 已生成",
                  (staging[0] / "SHA256SUMS-r7.txt").is_file()
                  and (staging[0] / "RELEASE-r7.txt").is_file())


def test_successful_publish_commits_only_after_all_work():
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        out_root = base / "dist"
        plan = RecordingPlan(out_root, 7)
        version = {"AURADSP_TAG": "v1.2.3"}
        result = release.publish_delivery(
            out_root, 7, [make_item(base)], plan,
            note_payload={"commit": "abc123"}, ver=version)
        final = out_root / "deliver-r7"
        check("成功发布产生正式目录", result.dir == final and final.is_dir())
        check("post_check 已执行且当时正式目录不存在",
              plan.called and plan.final_existed is False)
        check("materialize/sums/note 均先于 post_check", plan.complete_at_check)
        check("平台自检收到原版本对象", plan.version is version)
        check("发布后结果路径全部重定位到正式目录",
              result.files == [final / "artifact.bin"]
              and result.sums == final / "SHA256SUMS-r7.txt"
              and result.note == final / "RELEASE-r7.txt")
        check("现有提交元数据写入说明卡",
              "commit: abc123" in result.note.read_text(encoding="utf-8"))
        check("成功发布后无 staging 残留", staging_dirs(out_root, 7) == [])


def test_existing_final_is_never_replaced():
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        out_root = base / "dist"
        final = out_root / "deliver-r7"
        final.mkdir(parents=True)
        (final / "keep.txt").write_text("keep", encoding="utf-8")
        plan = RecordingPlan(out_root, 7)
        try:
            release.publish_delivery(out_root, 7, [make_item(base)], plan)
        except SystemExit:
            check("已有正式目录导致拒绝发布", True)
        else:
            check("已有正式目录导致拒绝发布", False, "未拒绝已有目录")
        check("已有正式目录内容未被替换",
              (final / "keep.txt").read_text(encoding="utf-8") == "keep"
              and not (final / "artifact.bin").exists())
        check("已有正式目录时不执行打包后自检", not plan.called)
        check("已有正式目录时不遗留新 staging", staging_dirs(out_root, 7) == [])


def test_final_appearing_during_post_check_is_not_replaced():
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        out_root = base / "dist"
        plan = FinalCreatingPlan(out_root, 7)
        try:
            release.publish_delivery(out_root, 7, [make_item(base)], plan)
        except SystemExit:
            check("提交前出现的正式目录导致拒绝 rename", True)
        else:
            check("提交前出现的正式目录导致拒绝 rename", False, "覆盖了竞争目录")
        final = out_root / "deliver-r7"
        check("竞争出现的正式目录内容保留",
              (final / "keep.txt").read_text(encoding="utf-8") == "keep"
              and not (final / "artifact.bin").exists())
        check("竞争失败 staging 保留供诊断", len(staging_dirs(out_root, 7)) == 1)


def main() -> int:
    tests = (
        test_stage_delivery_creates_only_nonce_staging,
        test_failed_post_check_never_publishes_delivery,
        test_successful_publish_commits_only_after_all_work,
        test_existing_final_is_never_replaced,
        test_final_appearing_during_post_check_is_not_replaced,
    )
    for fn in tests:
        print(f"== {fn.__name__} ==")
        try:
            fn()
        except Exception as exc:
            check(f"{fn.__name__} 执行", False, f"{type(exc).__name__}: {exc}")
        print()
    if FAILURES:
        print("RELEASE ATOMIC FAILURES:", FAILURES)
        return 1
    print("release atomic: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
