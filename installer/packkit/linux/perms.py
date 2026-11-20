"""权限规范化与可执行文件识别（Linux 打包的公共底座）。

历史实现用 `find -exec sh -c 'if file "$f" | grep -q ELF'` 逐文件判型，两个
真实缺陷：

1. **依赖 `file` 命令**。最小化容器/WSL 里常常没装 `file`（本次实测的
   Debian WSL 就没有）：`file` 不存在时管道判型恒假，于是 ELF 二进制被
   chmod 644——装出来的程序不可执行，而且没有任何报错。发行包里一半是
   二进制，这个失败模式代价极高。
2. **每文件 fork 一次 `file`**。bundle 有数千个文件，等于数千次进程创建。

这里改成读 ELF magic（`\\x7fELF`）：零外部依赖、单遍遍历、判定比 `file`
的字符串匹配更严格（不会把正文里出现 "ELF" 的文本误判为二进制）。

规范化口径（与 2026-11-06 起的历史产物逐位一致）：

    目录     755
    ELF 文件 755
    其余文件 644

显式可执行清单（维护者脚本、启动器）由调用方在规范化之后用
[`make_executable`] 单独恢复，因为它们既不是 ELF（shell 脚本），也不该
靠内容猜测。
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

ELF_MAGIC = b"\x7fELF"

DIR_MODE = 0o755
EXEC_MODE = 0o755
FILE_MODE = 0o644


def is_elf(path: Path) -> bool:
    """按 magic 判 ELF。读不到（空文件/设备/权限）一律视为非 ELF。"""
    try:
        with path.open("rb") as fh:
            return fh.read(4) == ELF_MAGIC
    except OSError:
        return False


def make_executable(path: Path) -> None:
    path.chmod(EXEC_MODE)


def normalize_tree(root: Path) -> dict[str, int]:
    """就地规范化 root 下整棵树，返回统计（目录/ELF/普通文件/链接）。

    符号链接一律跳过：`find -type f`/`-type d` 本来就不匹配链接，Debian
    打包要求链接保持原样（`/usr/bin/auradsp` 就是链接）。
    """
    stats = {"dirs": 0, "elf": 0, "files": 0, "symlinks": 0}

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        d = Path(dirpath)
        # os.walk 已按目录递归；这里只处理当前层的目录项权限
        os.chmod(d, DIR_MODE)
        stats["dirs"] += 1

        # 目录形式的符号链接不参与递归，但要计入统计并从 dirnames 摘掉
        keep: list[str] = []
        for name in dirnames:
            child = d / name
            if child.is_symlink():
                stats["symlinks"] += 1
            else:
                keep.append(name)
        dirnames[:] = keep

        for name in filenames:
            p = d / name
            if p.is_symlink():
                stats["symlinks"] += 1
                continue
            try:
                mode = p.stat().st_mode
            except OSError:
                continue
            if not stat.S_ISREG(mode):
                continue
            if is_elf(p):
                p.chmod(EXEC_MODE)
                stats["elf"] += 1
            else:
                p.chmod(FILE_MODE)
                stats["files"] += 1

    return stats


def describe(stats: dict[str, int]) -> str:
    return (f"目录 {stats['dirs']} / ELF {stats['elf']} / "
            f"普通 {stats['files']} / 链接 {stats['symlinks']}")
