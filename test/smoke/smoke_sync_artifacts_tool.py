# -*- coding: utf-8 -*-
"""smoke_sync_artifacts_tool — 产物同步工具门禁（S4 补强，2026-11-01）。

tools/sync_artifacts.py 是 S4 跨平台化的产物同步真源（PS1 已降为
wrapper）。本门禁保证它在当前平台可被解释执行且语义稳定：
  - 文件可 py_compile
  - --what-if 干跑不抛异常；退出码只能是 0（全到位）或 2（有跳过，
    在未构建/未打包的工作区是常态），其它退出码判 FAIL
跨平台（PLATFORM_ANY）：Windows 与 Linux 都应通过。
"""
import os
import py_compile
import subprocess
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
SCRIPT = os.path.join(ROOT, "tools", "sync_artifacts.py")

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    try:
        py_compile.compile(SCRIPT, doraise=True)
        check(True, "sync_artifacts.py 可编译")
    except py_compile.PyCompileError as e:
        check(False, f"sync_artifacts.py 编译失败：{e}")
        return 1
    r = subprocess.run([sys.executable, SCRIPT, "--what-if"],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", cwd=ROOT)
    out = r.stdout + r.stderr
    check("Traceback" not in out, "--what-if 无异常堆栈")
    check(r.returncode in (0, 2),
          f"--what-if 退出码 {r.returncode} ∈ (0, 2)")
    check("Sync result" in out, "--what-if 输出含汇总行")
    print("smoke_sync_artifacts_tool: " + ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
