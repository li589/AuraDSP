"""Windows 平台层：驱动域、签名门、Setup 单体、四个打包模式与 CLI。

平台边界只在 `packkit/windows/` 之内：内核层（`packkit/*.py`）不得 import
本包，以便 Linux 侧后续复用命名/哈希/交付归集时不被 Windows 依赖拖住。
"""

from __future__ import annotations
