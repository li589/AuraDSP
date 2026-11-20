"""哈希与清单写入（换行/大小写两个历史坑的固化点）。

两条被真机验证过的硬约束：

1. **必须钉死 LF**：Windows 文本模式默认把 `\\n` 翻成 CRLF，产物在
   GNU `sha256sum -c` 下全行不匹配（2026-11-09 真机登记）。
2. **大小写分域**：包内清单（build-info、资源包 SHA256SUMS）沿用历史
   小写；交付清单（SHA256SUMS-rNN.txt）用大写，与 r58 起已交付件一致。
"""

from __future__ import annotations

import hashlib
from collections.abc import Iterable, Mapping
from pathlib import Path


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_sha256sums(path: Path) -> dict[str, str]:
    """读 `SHA256SUMS.txt` → {文件名: 小写哈希}；不存在返回空 dict。"""
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2 and len(parts[0]) == 64:
            out[Path(parts[-1]).name] = parts[0].lower()
    return out


def merge_sha256sums(sums_path: Path, files: Iterable[Path]) -> int:
    """pack.py `--sha256sums` 的语义：读旧清单、按文件名覆盖、排序、LF、小写。

    返回清单总条数（含历史条目）。
    """
    existing = {}
    if sums_path.is_file():
        for line in sums_path.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) >= 2:
                existing[parts[-1]] = line
    for p in files:
        existing[p.name] = f"{sha256_file(p)}  {p.name}"
    sums_path.write_text(
        "\n".join(existing[k] for k in sorted(existing)) + "\n",
        encoding="utf-8", newline="\n")
    return len(existing)


def write_delivery_sums(path: Path, entries: Mapping[str, str]) -> None:
    """交付清单：调用方给定顺序、大写哈希、LF。"""
    lines = [f"{digest.upper()}  {name}" for name, digest in entries.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
