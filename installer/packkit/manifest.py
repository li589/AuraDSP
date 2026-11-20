"""清单刷新：包内 build-info 的追加段与 staging 全量重算。"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from .common import log, warn
from .paths import DIST_MANIFEST


def refresh_build_info(staging_copy: Path, extra: dict[str, str]) -> None:
    """在产物副本上追加 build-info 段（不改原始 staging）。"""
    info = staging_copy / "build-info.txt"
    lines = []
    if info.is_file():
        lines = info.read_text(encoding="utf-8", errors="replace").splitlines()
    lines += ["", "# pack.py 附加记录"] + [f"{k}: {v}" for k, v in extra.items()]
    info.write_text("\n".join(lines) + "\n", encoding="utf-8")


def refresh_dist_manifest(staging: Path) -> None:
    """按 dist_manifest 口径重算 staging 的 build-info（尽力而为）。"""
    if not DIST_MANIFEST.is_file():
        return
    rc = subprocess.run([sys.executable, str(DIST_MANIFEST),
                         "--dist-dir", str(staging)]).returncode
    if rc != 0:
        warn(f"build-info.txt 刷新失败（rc={rc}），清单可能过期")
