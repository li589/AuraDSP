"""staging 校验与打包副本（平台无关部分）。

约定：**原 staging 永不被资源合并污染**。full/light 合并发生在
`prepare_staging_copy` 造出的临时副本上；只有「补齐驱动资产」是就地写
staging 的（那是 dist 绿色目录的自包含要求，见 windows/payload.py）。
"""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

from .common import die
from .defaults import apply_defaults
from .manifest import refresh_build_info
from .resources import apply_resources


def check_staging(staging: Path) -> None:
    if not staging.is_dir():
        raise die(f"staging 目录不存在: {staging}"
                  "（先跑 build_windows.ps1 或 --build-staging）")
    if not (staging / "auradsp_app.exe").is_file():
        raise die(f"staging 缺 auradsp_app.exe: {staging}")


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


def describe_staging(staging: Path) -> str:
    """给发布计划用的一行摘要。"""
    if not staging.is_dir():
        return "缺失"
    exe = staging / "auradsp_app.exe"
    size = sum(p.stat().st_size for p in staging.rglob("*") if p.is_file())
    return f"{'就绪' if exe.is_file() else '缺 auradsp_app.exe'}（{size / 1e6:.0f} MB）"
