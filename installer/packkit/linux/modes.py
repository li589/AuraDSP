"""模式调度与资源档位门禁。

执行顺序固定为 `deb → driver → appimage → portable`，与历史 `want()` 顺序
一致：先出正式安装包，再出驱动包，最后才是两个便携形态（AppImage 最慢，
放最后便于中途 Ctrl-C 时已有可用产物）。

**Linux 单档门禁**：Linux 产物名不含资源档位（03 §5 定稿），light 与 full
会产出同名文件。因此一次调用只允许一个档位；`release.py` 的跨平台编排也
必须遵守这条，否则后打的档位静默覆盖前一个。Windows 侧靠 `-Full-`/
`-Light-` 后缀解决，Linux 侧靠这条门禁解决。
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from ..common import die, log
from ..naming import LINUX_MODES, LinuxArtifactNames
from . import appimage, deb, driver_deb, portable


@dataclass
class BuildResult:
    version: str
    tag: str
    artifacts: dict[str, Path] = field(default_factory=dict)

    def ordered(self) -> list[Path]:
        return [self.artifacts[m] for m in LINUX_MODES if m in self.artifacts]


def parse_only(value: str) -> tuple[str, ...]:
    """解析 `--only deb,driver`；空值表示全量。未知模式直接拒绝。"""
    if not value:
        return LINUX_MODES
    parts = [p.strip() for p in value.split(",") if p.strip()]
    unknown = [p for p in parts if p not in LINUX_MODES]
    if unknown:
        raise die(f"--only 含未知模式: {', '.join(unknown)}"
                  f"（可选 {', '.join(LINUX_MODES)}）")
    # 去重但保留固定顺序：调用方写 --only portable,deb 也按标准顺序执行
    return tuple(m for m in LINUX_MODES if m in parts)


def resolve_tiers(tiers: list[str]) -> str:
    """Linux 一次只能一个资源档位（产物名不含档位，见模块 docstring）。"""
    unique = list(dict.fromkeys(tiers))
    if len(unique) > 1:
        raise die(
            "Linux 一次只能打一个资源档位（产物名不含档位，"
            f"多档会互相覆盖）：收到 {', '.join(unique)}。\n"
            "  要出两档请分两次发布，或改用 Windows 的 -Full-/-Light- 命名。")
    return unique[0] if unique else "core"


def run(modes: tuple[str, ...], bundle: Path, version: str, tag: str,
        out_dir: Path, cache_dir: Path | None = None) -> BuildResult:
    names = LinuxArtifactNames(version=version, tag=tag)
    result = BuildResult(version=version, tag=tag)

    builders: dict[str, Callable[[], Path]] = {
        "deb": lambda: deb.build(bundle, version, out_dir),
        "driver": lambda: driver_deb.build(version, out_dir),
        "appimage": lambda: appimage.build(bundle, version, out_dir, cache_dir),
        "portable": lambda: portable.build(bundle, version, out_dir),
    }

    for mode in modes:
        log(f"== {mode} ==")
        produced = builders[mode]()
        expected = names.build(mode)
        if produced.name != expected:
            # 命名漂移在打包器内部就该炸，而不是等交付时人工发现
            raise die(f"{mode} 产物名与命名真相源不符："
                      f"{produced.name} ≠ {expected}")
        result.artifacts[mode] = produced
    return result
