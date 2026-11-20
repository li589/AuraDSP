"""发布编排的平台接口（`installer/release.py` 的依赖倒置点）。

`release.py` 只负责「顺序、门禁打印、归集、清单、说明卡」这些与平台无关
的事；每个平台提供一份 `PlatformPlan`，回答四个问题：

  1. 打包前必须成立什么？        preflight() → 门禁表
  2. 按什么顺序打哪些档位？      tier_plans()（顺序即执行顺序）
  3. 怎么调打包器？             run_pack()
  4. 产物怎么命名与自检？        collect() / post_check()

这样加 Linux（2026-11-20）不必在 release.py 里插 if/else 分叉，将来加
macOS 也只是再加一个模块。接口刻意保持最小：任何「只对某平台成立」的
概念（Windows 的 Setup 尾块、Linux 的单档位）都封装在实现里。
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .deliver import DeliveryItem


@dataclass
class Gate:
    """一条预检结论。status ∈ OK / WARN / FAIL；FAIL 阻塞真打包。"""

    name: str
    status: str
    detail: str = ""

    @property
    def icon(self) -> str:
        return {"OK": "✓", "WARN": "!", "FAIL": "✗"}.get(self.status, "?")


class PlatformPlan(Protocol):
    """平台发布策略。实现见 `windows/release_plan.py`、`linux/release_plan.py`。"""

    name: str

    def preflight(self, tiers: list[str]) -> list[Gate]:
        """打包前门禁；不抛异常，逐条给状态。"""

    def tier_plans(self, tiers: list[str]) -> tuple[tuple[str, tuple[str, ...]], ...]:
        """(档位, 模式元组) 序列，**顺序即执行顺序**。

        入参是已收敛的档位（`normalize_tiers` 之后）：Windows 固定两档、
        Linux 单档，两者的组合方式不同，所以由实现决定。
        """

    def default_tiers(self) -> tuple[str, ...]:
        """未显式指定时打哪些档位。"""

    def normalize_tiers(self, requested: list[str]) -> list[str]:
        """校验/收敛调用方给 的档位；不合法直接 die。"""

    def versions_note(self, ver: dict[str, str]) -> str:
        """计划表「版本」行的人话说明。"""

    def prepare(self, build: bool) -> None:
        """可选的前置构建（--build）。"""

    def run_pack(self, tier: str, modes: tuple[str, ...], out_dir: Path,
                 what_if: bool) -> None:
        """调用本平台打包器；out_dir 为该档位专属目录。"""

    def expected_artifacts(self, tier: str, modes: tuple[str, ...],
                           out_dir: Path, ver: dict[str, str]) -> dict[str, Path]:
        """按命名真相源推出各模式产物路径（归集与自检靠它定位，不猜名字）。"""

    def collect(self, tier_outputs: dict[str, dict[str, Path]],
                ver: dict[str, str]) -> list[DeliveryItem]:
        """把各档位产物映射成交付物（含改名）。"""

    def post_check(self, files: list[Path], ver: dict[str, str]) -> None:
        """交付前的结构自检；失败抛 die。"""
