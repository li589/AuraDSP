"""交付目录归集（deliver-rNN）。

交付目录不是打包器的职责，而是「一轮交付」的职责：把同一次构建产出的
四件按**交付名**摆齐，附一份大写哈希清单与一张说明卡。历史教训是这步
靠手工 cp + 手写哈希，于是有了「light 覆盖 full」「r54b 轮次混乱」这类
事故。这里把它变成纯函数式的一步：给定来源与名字，产出可复核的目录。
"""

from __future__ import annotations

import shutil
from dataclasses import dataclass, field
from pathlib import Path

from .common import die, log
from .hashing import sha256_file, write_delivery_sums
from .naming import ArtifactNames, delivery_dirname


@dataclass(frozen=True)
class DeliveryItem:
    """一件交付物：来源文件 + 交付名 + 说明。"""

    source: Path
    name: str
    note: str = ""


@dataclass
class DeliveryResult:
    dir: Path
    files: list[Path] = field(default_factory=list)
    sums: Path | None = None
    note: Path | None = None

    @property
    def total_bytes(self) -> int:
        return sum(p.stat().st_size for p in self.files)

    def digests(self) -> dict[str, str]:
        return {p.name: sha256_file(p) for p in self.files}


def make_dir(base: Path, round_no: int, what_if: bool = False) -> Path:
    dest = base / delivery_dirname(round_no)
    if what_if:
        log(f"what-if: 将归集交付目录 {dest}")
        return dest
    dest.mkdir(parents=True, exist_ok=True)
    return dest


def materialize(dest: Path, items: list[DeliveryItem],
                what_if: bool = False) -> list[Path]:
    """按交付名拷贝（不是移动）：打包工作目录保留原件便于复算。"""
    produced: list[Path] = []
    for item in items:
        if not item.source.is_file():
            raise die(f"交付物缺失: {item.source}")
        target = dest / item.name
        if what_if:
            log(f"what-if: 归集 {item.source.name} → {target.name}")
            produced.append(target)
            continue
        if target.exists():
            target.chmod(0o666)
            target.unlink()
        shutil.copy2(item.source, target)
        log(f"交付: {target.name}（{target.stat().st_size / 1e6:.1f} MB）")
        produced.append(target)
    return produced


def write_sums(dest: Path, round_no: int, files: list[Path],
               what_if: bool = False) -> Path:
    path = dest / ArtifactNames.sums(round_no)
    if what_if:
        log(f"what-if: 将写哈希清单 {path.name}（{len(files)} 条）")
        return path
    digests = {p.name: sha256_file(p) for p in files}
    write_delivery_sums(path, digests)
    log(f"哈希清单: {path.name}（{len(digests)} 条，大写，LF）")
    return path


def write_note(dest: Path, round_no: int, payload: dict,
               what_if: bool = False) -> Path:
    """交付说明卡：一眼看清这轮装的是哪个提交、哪几个档位。"""
    path = dest / f"RELEASE-r{round_no}.txt"
    if what_if:
        log(f"what-if: 将写交付说明 {path.name}")
        return path
    lines = [f"AuraDSP 交付 r{round_no}", ""]
    lines += [f"{k}: {v}" for k, v in payload.items()]
    lines += ["", "artifacts:"]
    for p in sorted(dest.glob("*")):
        if p.name == path.name or not p.is_file():
            continue
        lines.append(f"  {sha256_file(p).upper()}  {p.stat().st_size:>12}  {p.name}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return path
