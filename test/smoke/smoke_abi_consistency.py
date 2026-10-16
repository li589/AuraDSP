#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_abi_consistency.py — B4 E4：C ABI / .def / Dart FFI 三处一致性

E1 的 show_editor 签名漂移（Dart FFI 3 参 vs C ABI 2 参，窗口标题被静默
丢弃）说明三处导出清单靠人肉同步不可靠。tools/bin/abi_consistency.py 做
逐条比对，本 smoke 把它挂上门禁：任何"导出未绑定 / 绑定不存在符号 /
元数不一致"都会在这里 FAIL。

另附一条活体断言：auradsp_abi 在 .def 中导出且 Dart 已绑定，
运行期版本号查询可用（Dart 侧 version() 走同一符号）。
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "tools", "bin", "abi_consistency.py")


def main() -> int:
    if not os.path.exists(SCRIPT):
        print(f"[FAIL] abi_consistency.py missing: {SCRIPT}")
        return 1
    # 子进程输出为 UTF-8（含中文 PASS 行）；显式指定编码，不跟随系统 GBK，
    # 否则调用方带 PYTHONIOENCODING=utf-8 时必现 UnicodeDecodeError。
    r = subprocess.run([sys.executable, SCRIPT], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    if r.returncode != 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
