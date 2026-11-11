#!/usr/bin/env python3
"""薄转发 → tools/windows/perf_regression.py（Windows 专用实现）。

命令行参数原样透传：
    python tools/perf_regression.py --mode sysapo --scenario all
"""

import subprocess
import sys
from pathlib import Path


def main() -> int:
    target = Path(__file__).resolve().parent / "windows" / "perf_regression.py"
    if not target.exists():
        print(f"[ERROR] 实现脚本缺失：{target}")
        return 2
    return subprocess.call([sys.executable, str(target), *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(main())
