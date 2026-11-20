"""归档原语。

只有一条纪律：条目**排序后写入**、路径统一正斜杠、what-if 不落盘。
排序让同一输入的 zip 逐字节可复现（哈希比对才有意义）。
"""

from __future__ import annotations

import zipfile
from pathlib import Path

from .common import log


def zip_dir(
    src: Path,
    dest_zip: Path,
    level: int,
    arc_prefix: str = "",
    what_if: bool = False,
) -> int:
    """把目录内容压成 zip，返回条目数。"""
    files = sorted(p for p in src.rglob("*") if p.is_file())
    if what_if:
        log(f"what-if: 将打包 {src} → {dest_zip}（{len(files)} 文件）")
        return len(files)
    comp = zipfile.ZIP_DEFLATED if level > 0 else zipfile.ZIP_STORED
    with zipfile.ZipFile(dest_zip, "w", comp, compresslevel=level or None) as zf:
        for f in files:
            arc = arc_prefix + f.relative_to(src).as_posix()
            zf.write(f, arc)
    return len(files)


def write_stored_zip(dest: Path, entries) -> None:
    """写 STORED（不压缩）zip。

    Setup 的 ZIP-W 必须 STORED：引导壳零第三方依赖，只解 stored 条目
    （实施设计 §3）；ZIP-P 才用 deflate。
    """
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_STORED) as zf:
        for arc, file_path in entries:
            zf.write(file_path, arc)
