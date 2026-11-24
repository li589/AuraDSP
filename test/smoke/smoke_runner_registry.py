#!/usr/bin/env python3
"""登记完整性门禁（2026-11-24 审查 F-1）：test/smoke 磁盘文件、runner 的
平台分类集与执行清单 smoke_files 三者必须对齐。

事故背景：r47/r49 的 8 条 smoke 只登记进 PLATFORM_ANY 分类、从未进
smoke_files 执行清单，自登记日起从未被任何门禁跑过（静默假绿），且在
PLATFORM_ANY 里逐字重复登记了两遍。本门禁钉死：

1. test/smoke/ 下每个 smoke_*.py 都必须出现在 smoke_files 里；
2. smoke_files 里每个 smoke_*.py 条目都必须在磁盘上存在；
3. PLATFORM_ANY / PLATFORM_WINDOWS 的成员必须全部在 smoke_files 里；
4. smoke_files 无重复条目；PLATFORM_ANY 字面量无重复登记。

纯源码/文件系统检查，任意平台可跑。
"""
import ast
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
RUNNER = os.path.join(ROOT, "test", "runner.py")
SMOKE_DIR = os.path.join(ROOT, "test", "smoke")

failures = []


def check(label, ok, detail=""):
    if ok:
        print(f"  PASS {label}")
    else:
        failures.append(label)
        print(f"  FAIL {label} {detail}")


def _str_elts(node):
    return [e.value for e in node.elts if isinstance(e, ast.Constant)
            and isinstance(e.value, str)]


def main():
    tree = ast.parse(open(RUNNER, encoding="utf-8").read())
    smoke_files = None
    platform_sets = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not node.targets:
            continue
        name = getattr(node.targets[0], "id", "")
        if name == "smoke_files" and isinstance(node.value, ast.List):
            smoke_files = _str_elts(node.value)
        elif name in ("PLATFORM_ANY", "PLATFORM_WINDOWS") \
                and isinstance(node.value, ast.Set):
            platform_sets[name] = _str_elts(node.value)

    check("runner 可解析且三份清单齐全",
          smoke_files is not None and len(platform_sets) == 2)
    if smoke_files is None:
        return 1
    listed = set(smoke_files)
    disk = sorted(f for f in os.listdir(SMOKE_DIR)
                  if f.startswith("smoke_") and f.endswith(".py"))

    missing = [f for f in disk if f not in listed]
    check("磁盘 smoke 全部在执行清单内", not missing, f"missing={missing}")
    ghost = [f for f in listed
             if f.startswith("smoke_") and f not in disk]
    check("执行清单无幽灵 smoke 条目", not ghost, f"ghost={ghost}")
    for name, members in sorted(platform_sets.items()):
        outside = sorted(set(members) - listed)
        check(f"{name} 成员全部在执行清单内", not outside,
              f"outside={outside}")
        check(f"{name} 字面量无重复登记",
              len(members) == len(set(members)),
              f"dup={[m for m in set(members) if members.count(m) > 1]}")
    check("smoke_files 无重复条目", len(smoke_files) == len(listed),
          f"dup={[m for m in listed if smoke_files.count(m) > 1]}")

    if failures:
        print(f"smoke_runner_registry: {len(failures)} FAIL")
        return 1
    print("smoke_runner_registry: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
