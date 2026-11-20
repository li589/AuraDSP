"""产物命名唯一真相源（规范化重点之一）。

历史问题：打包脚本内联拼名字，交付目录又手工改名，两处一旦漂移就出现
「同一次构建的包名不一致」或「light 覆盖 full」这类事故。这里把两类名字
都收进一个地方：

  构建名（build）   ——打包器写到 --out 的名字，带 tag，供脚本互相引用。
  交付名（delivery）——交给测试/发行的人工可读名，**不带构建批次**，
                       由 release.py 归集时使用。

命名规则（2026-11-20 定稿，与 r54–r59 实际交付一致）：

  driver    build:    AuraDSP-Driver-x64-v0.1.0.zip
            delivery: AuraDSP-Driver-Windows-x64.zip
  portable  build:    AuraDSP-Windows-x64-v0.1.0.zip
            delivery: AuraDSP-Windows-x64-Full-v0.1.0.zip   （--resources full）
                      AuraDSP-Windows-x64-Light-v0.1.0.zip  （--resources light）
                      其余档位退回 build 名
  setup     build:    AuraDSP-Setup-x64-v0.1.0.exe
            delivery: AuraDSP-Setup.exe
  sums      build:    SHA256SUMS.txt          （pack.py --sha256sums）
            delivery: SHA256SUMS-r59.txt      （release.py 交付清单）

交付清单里的哈希用**大写十六进制**（与 r58/r59 已交付件一致，也便于肉眼
比对）；包内 build-info 与资源包 SHA256SUMS 维持小写（历史口径，改动会
波及 dist_manifest 与资源流水线）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

PRODUCT = "AuraDSP"
PLATFORM = "Windows-x64"

# 交付批次目录：deliver-r59
DELIVERY_DIR_RE = re.compile(r"^deliver-r(\d+)$")

MODES = ("driver", "portable", "setup", "staging")
RESOURCE_TIERS = ("core", "full", "light", "addons", "none")


@dataclass(frozen=True)
class ArtifactNames:
    """一次构建的命名上下文。`tag` 形如 `v0.1.0`。"""

    tag: str

    # ---- 构建名（--out 目录内） ----
    def build(self, mode: str) -> str:
        if mode == "driver":
            return f"{PRODUCT}-Driver-x64-{self.tag}.zip"
        if mode == "portable":
            return f"{PRODUCT}-{PLATFORM}-{self.tag}.zip"
        if mode == "setup":
            return f"{PRODUCT}-Setup-x64-{self.tag}.exe"
        raise ValueError(f"未知打包模式: {mode}")

    # ---- 交付名（deliver-rNN/） ----
    def delivery(self, mode: str, resources: str = "core") -> str:
        if mode == "driver":
            return f"{PRODUCT}-Driver-{PLATFORM}.zip"
        if mode == "setup":
            return f"{PRODUCT}-Setup.exe"
        if mode == "portable":
            tier = {"full": "Full", "light": "Light"}.get(resources)
            if tier:
                return f"{PRODUCT}-{PLATFORM}-{tier}-{self.tag}.zip"
            return self.build("portable")
        raise ValueError(f"未知打包模式: {mode}")

    @staticmethod
    def sums(round_no: int | None = None) -> str:
        return "SHA256SUMS.txt" if round_no is None else f"SHA256SUMS-r{round_no}.txt"


def delivery_dirname(round_no: int) -> str:
    return f"deliver-r{round_no}"


def round_of(dirname: str) -> int | None:
    m = DELIVERY_DIR_RE.match(dirname)
    return int(m.group(1)) if m else None


def next_round(base: Path, explicit: int | None = None) -> int:
    """推导下一轮交付号：显式优先，否则 base 下已有 deliver-rN 的最大值 +1。

    只认 `deliver-r<数字>` 目录形态；`deliver-r54b` 之类的临时目录不参与，
    避免把一次修补当成新轮次。
    """
    if explicit is not None:
        if explicit <= 0:
            raise ValueError("--round 必须是正整数")
        return explicit
    rounds = [r for r in (round_of(p.name) for p in base.glob("deliver-r*")) if r]
    return (max(rounds) + 1) if rounds else 1
