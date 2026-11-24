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
    ui = _ui
    if ui is not None:
        try:
            ui.log(msg)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# 进度小窗（2026-11-24）：tools/bin/progress_ui.py 的 ProgressUI 按路径加载，
# 注册到本模块后 log() 自动镜像、入口可用 ui_step() 推进度。UI 全程旁观：
# 加载/发送任何失败都静默无窗，命令行输出一字不变（见该文件隔离纪律）。
# ---------------------------------------------------------------------------

_ui = None
_ui_cls = None


def open_progress_ui(title: str, total: int | None = None):
    """创建并注册进度窗，返回句柄（禁用/失败时返回 None，调用方无需防御）。"""
    global _ui, _ui_cls
    try:
        if _ui_cls is None:
            import importlib.util

            from packkit.paths import ROOT

            spec = importlib.util.spec_from_file_location(
                "auradsp_progress_ui", ROOT / "tools" / "bin" / "progress_ui.py")
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
            _ui_cls = mod.ProgressUI
        _ui = _ui_cls(title, total=total)
        return _ui
    except Exception:
        _ui = None
        return None


def set_ui(ui) -> None:
    global _ui
    _ui = ui


def get_ui():
    return _ui


def ui_step(text: str) -> None:
    ui = _ui
    if ui is not None:
        try:
            ui.step(text)
        except Exception:
            pass


def die(msg: str) -> SystemExit:
    """返回（而非抛出）SystemExit，调用方写 `raise die(...)` 以保留栈语义。"""
    return SystemExit(f"{LOG_PREFIX} error: {msg}")


def warn(msg: str) -> None:
    log(f"警告: {msg}")
