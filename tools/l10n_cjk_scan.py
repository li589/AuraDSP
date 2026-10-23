#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""l10n_cjk_scan.py — 硬编码中文扫描/基线生成（P2-2，2026-10-23）

用途：
    python tools/l10n_cjk_scan.py            # 打印各文件当前硬编码中文条数
    python tools/l10n_cjk_scan.py --baseline # 重写 test/l10n_cjk_baseline.txt

规则（与 test/l10n_cjk_guard_test.dart 完全一致）：
    1. 去掉 /* ... */ 块注释；
    2. 跳过以 // 或 /// 开头的整行（注释里的示例串不算）；
    3. 统计「字符串字面量内含 CJK」的出现次数（'...' / "..."）。

棘轮语义：基线只允许**变小**。新增硬编码 → 守卫测试红；还清债务 → 手动
重跑 --baseline 把数字降下来（提交时基线文件随代码一起改）。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN_DIRS = [os.path.join(ROOT, "app", "auradsp_app", "lib", d)
              for d in ("features", "ui")]
BASE = os.path.join(ROOT, "app", "auradsp_app", "test", "l10n_cjk_baseline.txt")

BLOCK = re.compile(r"/\*.*?\*/", re.S)
CJK = re.compile(r"'[^'\n]*[\u4e00-\u9fff][^'\n]*'|\"[^\"\n]*[\u4e00-\u9fff][^\"\n]*\"")


def count_text(text):
    text = BLOCK.sub("", text)
    n = 0
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("//"):
            continue
        n += len(CJK.findall(line))
    return n


def scan():
    out = {}
    for base in SCAN_DIRS:
        for dirpath, _dirs, files in os.walk(base):
            for f in files:
                if not f.endswith(".dart"):
                    continue
                p = os.path.join(dirpath, f)
                rel = os.path.relpath(p, os.path.join(ROOT, "app", "auradsp_app")).replace("\\", "/")
                n = count_text(io.open(p, encoding="utf-8").read())
                if n > 0:
                    out[rel] = n
    return out


def main():
    res = scan()
    total = sum(res.values())
    if "--baseline" in sys.argv:
        lines = ["# 硬编码中文基线（P2-2 棘轮）：条目只允许减少。",
                 "# 重生成：python tools/l10n_cjk_scan.py --baseline",
                 "# 格式：<相对路径> <条数>"]
        for k in sorted(res):
            lines.append("%s %d" % (k, res[k]))
        io.open(BASE, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
        print("baseline written: %d files, %d strings" % (len(res), total))
        return 0
    for k in sorted(res, key=lambda x: -res[x]):
        print("%5d  %s" % (res[k], k))
    print("TOTAL %d strings / %d files" % (total, len(res)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
