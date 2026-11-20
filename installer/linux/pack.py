#!/usr/bin/env python3
"""AuraDSP Linux 发行打包入口（薄壳）。

实现已收进 `installer/packkit/linux/`（2026-11-20 工具链规范化，与 Windows
侧同一内核）：

  packkit/            平台无关内核：版本、命名、哈希、资源档位、默认层
  packkit/linux/      Linux 平台层：deb / 驱动 deb / AppImage / tar.gz /
                      权限规范化 / 构建链 / 模式调度
  installer/release.py 统一发布编排（--platform linux）

**参数与 `pack.sh` 逐字兼容**：`--build` / `--bundle` / `--out` / `--only` /
`--resources` / `--packs-dir` 语义不变，另加 `--what-if` 与 `--version`
（与 pack.py 对齐）。`pack.sh` 保留为转发壳，老命令行照旧可用。

产物（03 号规格 §5）：

  deb       auradsp_<ver>_amd64.deb                 正式安装包
  driver    auradsp-driver-loopback_<ver>_all.deb   snd-aloop 配置包
  appimage  AuraDSP-v<ver>-x86_64.AppImage          便携包
  portable  AuraDSP-Linux-x64-v<ver>.tar.gz         便携包（补充形态）

资源档位与 Windows 同名同义，但**一次只允许一个档位**：Linux 产物名不含
档位后缀（规格口径），两档同名会互相覆盖。多档请分两次发布。

Flatpak / Snap 仍为预留：本入口只校验清单在位，不产出商店包。
"""

from __future__ import annotations

import sys
from pathlib import Path

# installer/ 不是包（无 __init__.py）：把 installer 目录挂到 sys.path 首部
# 即可 `import packkit`。用 parents[1] 而非 CWD，保证从任意目录执行都能
# 找到内核（与 windows/pack.py 同一手法）。
_INSTALLER_DIR = Path(__file__).resolve().parents[1]
if str(_INSTALLER_DIR) not in sys.path:
    sys.path.insert(0, str(_INSTALLER_DIR))

from packkit.linux.cli import main  # noqa: E402  (需先完成 sys.path 注入)

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
