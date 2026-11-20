"""按目标系统规范输出文本文件（换行与编码）。

真实踩到的坑（2026-11-20）：`installer/linux/shared/auradsp.desktop` 在
git 里存的是 LF，但 Windows 工作区 checkout 成 CRLF（`git ls-files --eol`
显示 `i/lf w/crlf`）。在 WSL 里从 `/mnt/d` 直接打包时，CRLF 的 desktop
文件被塞进 AppDir，appimagetool 校验直接失败：

    ERROR: Desktop file contains errors.

而同一个文件进 deb 时不会报错，只是装到系统上属于不合规的 desktop entry。
所以**不能指望工作区换行**：凡是被目标系统按行解析的文本，出包前一律
按 LF 写。

不做全局 `.gitattributes` 改造是有意的：那会让所有开发者下次 checkout
遇到大面积换行 diff，收益远小于代价。在出口处规范化更稳。
"""

from __future__ import annotations

from pathlib import Path


def read_text_lf(path: Path) -> str:
    """按 UTF-8 读文本并把 CRLF/CR 统一成 LF（去 BOM）。"""
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    return text.replace("\r\n", "\n").replace("\r", "\n")


def write_text_lf(path: Path, text: str) -> None:
    """写 UTF-8（无 BOM）+ LF，不受平台默认换行影响。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def copy_text_lf(src: Path, dest: Path) -> None:
    """复制文本并规范化换行为 LF。"""
    write_text_lf(dest, read_text_lf(src))
