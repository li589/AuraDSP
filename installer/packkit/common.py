"""日志与失败口径。

发行工具链的输出是要被人读、被 CI 抓取的：所有日志统一 `[pack]` 前缀，
所有致命错误统一 `[pack] error:` 前缀并由调用方 `raise die(...)`。
fixture 测试与 CI annotation 都按这两个前缀筛选，改名即破坏契约。
"""

from __future__ import annotations

import sys

LOG_PREFIX = "[pack]"


def reconfigure_streams() -> None:
    """把标准流钉成 UTF-8。

    Windows 上标准流默认走本地代码页（en-US 为 cp1252），print 中文直接
    UnicodeEncodeError 崩掉（windows-installer CI 实测踩中；zh-CN 机器是
    cp936 能过，本地从不暴露）。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        except (AttributeError, ValueError):
            pass


def log(msg: str) -> None:
    print(f"{LOG_PREFIX} {msg}")


def die(msg: str) -> SystemExit:
    """返回（而非抛出）SystemExit，调用方写 `raise die(...)` 以保留栈语义。"""
    return SystemExit(f"{LOG_PREFIX} error: {msg}")


def warn(msg: str) -> None:
    log(f"警告: {msg}")
