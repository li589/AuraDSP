"""版本解析：`installer/shared/version_resolver.py` 是唯一真相源。

这里只做两件事：按文件路径加载真相源（installer/ 不是包，避免引入
`__init__.py` 改变目录语义），以及处理 `--version` 覆盖时的格式校验。
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path

from .common import die
from .paths import VERSION_RESOLVER

_OVERRIDE_RE = re.compile(r"^(\d{1,2})\.(\d{1,2})\.(\d+)$")


def load_resolver():
    spec = importlib.util.spec_from_file_location("version_resolver", VERSION_RESOLVER)
    if spec is None or spec.loader is None:
        raise die(f"无法加载版本真相源: {VERSION_RESOLVER}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def resolve_version(override: str | None = None) -> dict[str, str]:
    """返回 AURADSP_VERSION / BUILD / FULL_VERSION / TAG 四个变量。"""
    values = dict(load_resolver().resolve())
    if override:
        if not _OVERRIDE_RE.match(override):
            raise die(f"--version {override!r} 不符合 vXX.XX.X 格式")
        values["AURADSP_VERSION"] = override
        values["AURADSP_TAG"] = f"v{override}"
        values["AURADSP_FULL_VERSION"] = f"{override}.{values['AURADSP_BUILD']}"
    return values


def tag_of(values: dict[str, str]) -> str:
    return values["AURADSP_TAG"]


def pubspec_version(pubspec: Path | None = None) -> str:
    """读 pubspec 的 version 行原文（release.py 记录用，不做校验）。"""
    from .paths import APP_DIR

    path = pubspec or (APP_DIR / "pubspec.yaml")
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip()
    raise die(f"pubspec.yaml 中找不到 version: 行（{path}）")
