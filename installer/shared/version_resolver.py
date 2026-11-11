#!/usr/bin/env python3
"""AuraDSP 版本真相源解析（发布规范 01 §2.1 的落点）。

从 app/auradsp_app/pubspec.yaml 读取 version:，校验发布总则的版本
格式（vXX.XX.X：主、次版本各最多两位数，修订号一位起），向打包
脚本导出统一变量：

  AURADSP_VERSION      0.1.0
  AURADSP_BUILD        1
  AURADSP_FULL_VERSION 0.1.0.1
  AURADSP_TAG          v0.1.0

用法：
  version_resolver.py              # 打印 shell export 行（可 eval）
  version_resolver.py --json       # 打印 JSON
  version_resolver.py --get TAG    # 只打印单个变量的值
  version_resolver.py --check-tag v0.1.0   # 校验标签与 pubspec 一致

任一校验失败以非零码退出并在 stderr 说明原因——发行门禁的一部分。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PUBSPEC = ROOT / "app" / "auradsp_app" / "pubspec.yaml"

# 发布总则：vXX.XX.X —— 主、次版本各最多两位数；修订号一位起
# （修订号超过 9 时应进位次版本，这里只做格式下限校验）。
VERSION_RE = re.compile(r"^(\d{1,2})\.(\d{1,2})\.(\d+)$")


def resolve() -> dict[str, str]:
    text = PUBSPEC.read_text(encoding="utf-8")
    m = re.search(r"^version:\s*(\S+)\s*$", text, re.MULTILINE)
    if not m:
        raise SystemExit(f"error: pubspec.yaml 中找不到 version: 行（{PUBSPEC}）")
    raw = m.group(1)
    version, _, build = raw.partition("+")
    build = build or "1"
    vm = VERSION_RE.match(version)
    if not vm:
        raise SystemExit(
            f"error: 版本号 {version!r} 不符合发布格式 vXX.XX.X"
            "（主、次版本各最多两位数，修订号一位起）"
        )
    if not build.isdigit():
        raise SystemExit(f"error: 构建序号 {build!r} 必须是数字")
    return {
        "AURADSP_VERSION": version,
        "AURADSP_BUILD": build,
        "AURADSP_FULL_VERSION": f"{version}.{build}",
        "AURADSP_TAG": f"v{version}",
    }


def main(argv: list[str]) -> int:
    values = resolve()
    if "--json" in argv:
        print(json.dumps(values, ensure_ascii=False))
    elif "--get" in argv:
        key = argv[argv.index("--get") + 1]
        if key not in values:
            raise SystemExit(f"error: 未知变量 {key}（可选：{', '.join(values)}）")
        print(values[key])
    elif "--check-tag" in argv:
        tag = argv[argv.index("--check-tag") + 1]
        if tag != values["AURADSP_TAG"]:
            raise SystemExit(
                f"error: 标签 {tag} 与 pubspec 版本不一致"
                f"（应为 {values['AURADSP_TAG']}），发行中止"
            )
        print(f"ok: {tag} 与 pubspec 一致")
    else:
        for k, v in values.items():
            print(f"export {k}={v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
