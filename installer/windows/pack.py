#!/usr/bin/env python3
"""AuraDSP Windows 发行打包入口（薄壳）。

实现已拆分到 `installer/packkit/`（2026-11-20 工具链规范化）：

  packkit/            平台无关内核：版本、命名、哈希、归档、资源档位、
                      默认层、staging、交付归集
  packkit/windows/    Windows 平台层：驱动域、签名门、Setup 单体、模式、CLI
  installer/release.py 统一发布编排（预检 → 构建 → 分档打包 → 交付归集）

本文件只保留命令行契约与文档，**参数、默认值、输出文案均不得改动**——
`installer/windows/tests/test_pack_fixture.py` 与 CI annotation 按这些
字符串断言，重构只能换实现、不能换契约。

一个入口产出 Windows 完整发行的四件（可任意组合）：

  driver   AuraDSP-Driver-x64-v<ver>.zip
           VAIO 驱动全套 + install_driver.ps1 + auraasio_driver.dll
           + register_asio.ps1（生成的注册/反注册脚本）
  portable AuraDSP-Windows-x64-v<ver>.zip
           staging 整目录（按 --resources 策略加工）+ build-info 刷新
  setup    AuraDSP-Setup-x64-v<ver>.exe
           引导壳 PE + ZIP-W（向导运行时）+ ZIP-P（产品载荷）
           + 80B 尾块（magic/偏移/SHA256@载荷），--verify 可自检
  staging  就地补齐 staging 文件夹（dist/AuraDSP-Windows-x64）：
           根 ASIO + driver/ 与便携/安装载荷同布局，使 dist 的文件夹
           产出本身即可直接打开运行测试；portable/setup 完成后亦自动
           对 staging 本体执行同一补齐。

资源策略（--resources）：

  core   staging 自带资源原样
  full   合并 dist/resources/auradsp-resource-full.zip 覆盖 resources/
  light  合并 resource-core + addon-headphone-ddc（全类别齐全，卷积轻档）
  addons 依次合并 resource-core → resource-full → 全部 addon 包
  none   剔除 resources（保留 manifest.json 与占位说明）

版本真相源：installer/shared/version_resolver.py（pubspec + 格式校验）；
--version 可覆盖（仍校验）。逻辑层与平台无关，可在任意系统以 fixture
staging 自测（installer/windows/tests/）。
"""

from __future__ import annotations

import sys
from pathlib import Path

# installer/ 不是包（无 __init__.py，且不希望改变目录语义）：把 installer
# 目录挂到 sys.path 首部，即可 `import packkit`。用 parents[1] 而非 CWD，
# 保证从任意工作目录执行本脚本都能找到内核。
_INSTALLER_DIR = Path(__file__).resolve().parents[1]
if str(_INSTALLER_DIR) not in sys.path:
    sys.path.insert(0, str(_INSTALLER_DIR))

from packkit.windows.cli import main  # noqa: E402  (需先完成 sys.path 注入)

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
