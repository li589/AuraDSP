# -*- coding: utf-8 -*-
"""smoke_ci_workflow — CI 工作流结构门禁（S4 补强，2026-11-01）。

.github/workflows/ci.yml 是 S4 落地的七 job 流水线；本门禁用纯文本
断言（不依赖 PyYAML，两平台的 Python 都能跑）守住它的骨架，防止
后续编辑误删 job 或断掉依赖：
  - 七个 job id 齐全（J1..J7 与方案 §4.1 一一对应）
  - smoke-linux 与 dart-tests 都 needs build-engine-linux
    （前者要引擎产物跑功能门禁，后者有真探针断言依赖 .so 在位）
  - 触发分支含 feature/linux（分支策略：feature/linux 只向 dev 合并，
    其 push 必须被 CI 守住）
"""
import os
import re
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
WF = os.path.join(ROOT, ".github", "workflows", "ci.yml")

JOBS = ["gate-static", "build-engine-linux", "smoke-linux", "abi-linux",
        "build-engine-windows", "dart-tests", "asset-guard"]

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def job_block(text, job):
    m = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [a-z]|\Z)",
                  text, re.M | re.S)
    return m.group(1) if m else ""


def main():
    if not os.path.isfile(WF):
        check(False, f"工作流文件缺失：{WF}")
        return 1
    text = open(WF, encoding="utf-8").read()
    for job in JOBS:
        check(re.search(rf"^  {re.escape(job)}:", text, re.M) is not None,
              f"job {job} 存在")
    for job in ("smoke-linux", "dart-tests"):
        check("needs: build-engine-linux" in job_block(text, job),
              f"{job} needs build-engine-linux")
    check("feature/linux" in text, "触发分支含 feature/linux")
    print("smoke_ci_workflow: " + ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
