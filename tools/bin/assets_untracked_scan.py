#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""assets_untracked_scan.py — D-2 回归门禁：`.irs`/`.vdc` 大二进制不得回到 git。

背景（D-2，2026-10-31 裁定并执行）
--------------------------------
`assets/` 下的 IR 脉冲（`.irs`）与耳机校准曲线（`.vdc`）共 2443 个文件 /
241.6MB，早前被误纳入版本控制。它们按 `assets/README.md` 的既定设计**不走
git，走 release 附件**（Release v0.5.0 已挂 `auradsp-resource-full.zip` 等 5 个
资源包，`dist/AuraDSP-Windows-x64.zip` 亦内嵌 `resources/`）。本轮用
`git filter-repo` 重写了全部历史（含旧路径前缀 `resource/`）把它们从历史中
剔除，并 force-push 到远端。

为什么还需要门禁
----------------
`git rm --cached` 只脱索引、不瘦历史；而 `.gitignore` 的规则**不回溯**——
任何一次误用 `git add -f`、或有人把规则删掉，都会让 241.6MB 重新进入索引。
本门禁把"大二进制不进 git"从口头约定变成可执行断言。

断言清单
--------
A1 索引层：所有本地分支的工作区索引中，不得出现任何 `.irs` / `.vdc` 路径
A2 树层：所有本地分支的 HEAD 树中，不得出现任何 `.irs` / `.vdc` 路径
A3 忽略规则：`.gitignore` 必须同时保留 `/assets/**/*.irs` 与
             `/assets/**/*.vdc` 两条规则（防止规则被删后无意识重新入库）
A4 保留项：`assets/manifest.json` 与 `assets/README.md` 必须**仍在版本控制内**
             （清单与命名冻结说明体积极小，是资源的唯一台账，不能跟着一起删）
A5 反向自检：探测器本身必须能判红——合成的 `.irs` 路径必须被抓出，
             `.json` / `.eel` / `.md` 不得被误报（防"空转绿"）

用法：python tools/bin/assets_untracked_scan.py
退出码：0 = 全绿；1 = 有断言失败
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BINARY_EXTS = (".irs", ".vdc")
KEEP_TRACKED = ("assets/manifest.json", "assets/README.md")
GITIGNORE_RULES = ("/assets/**/*.irs", "/assets/**/*.vdc")

results = []


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", name, ("  -- " + detail) if detail else ""))
    return ok


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True).stdout


def is_binary_resource(path):
    return path.lower().endswith(BINARY_EXTS)


def scan_index_and_trees():
    """Return (index_bad, tree_bad, branches) for .irs/.vdc paths."""
    index_bad = []
    tree_bad = []
    branches = git("for-each-ref", "--format=%(refname:short)", "refs/heads").decode().split()
    for br in branches:
        for path in git("ls-tree", "-r", "-z", "--name-only", br).decode("utf-8", "surrogateescape").split("\x00"):
            if path and is_binary_resource(path):
                tree_bad.append((br, path))
        for path in git("ls-files", "-z", "--", "assets").decode("utf-8", "surrogateescape").split("\x00"):
            if path and is_binary_resource(path):
                index_bad.append((br, path))
    return index_bad, tree_bad, branches


def main():
    print("=" * 72)
    print("  D-2 assets_untracked_scan  (.irs/.vdc 不得回到 git)")
    print("=" * 72)

    index_bad, tree_bad, branches = scan_index_and_trees()

    # A1 索引层
    record("A1 索引中无 .irs/.vdc（%d 个本地分支）" % len(branches),
           not index_bad,
           ("违规 %d 条，例：%s" % (len(index_bad), index_bad[:3])) if index_bad else "")

    # A2 树层
    record("A2 分支 HEAD 树中无 .irs/.vdc", not tree_bad,
           ("违规 %d 条，例：%s" % (len(tree_bad), tree_bad[:3])) if tree_bad else "")

    # A3 忽略规则
    gi_path = os.path.join(ROOT, ".gitignore")
    gi = ""
    if os.path.isfile(gi_path):
        with open(gi_path, "r", encoding="utf-8") as f:
            gi = f.read()
    missing_rules = [r for r in GITIGNORE_RULES if r not in gi]
    record("A3 .gitignore 保留两条忽略规则", not missing_rules,
           ("缺失：%s" % missing_rules) if missing_rules else "")

    # A4 保留项
    tracked = set(git("ls-files", "-z").decode("utf-8", "surrogateescape").split("\x00"))
    lost = [p for p in KEEP_TRACKED if p not in tracked]
    record("A4 资源台账仍受版本控制（manifest.json / README.md）", not lost,
           ("已丢失：%s" % lost) if lost else "")

    # A5 反向自检（防空转绿）
    probe_pos = "assets/convolver/01_headphone_correction/probe.irs"
    probe_neg = ["assets/manifest.json", "assets/liveprog/x.eel", "docs/notes.md"]
    det_ok = is_binary_resource(probe_pos)
    det_clean = not any(is_binary_resource(p) for p in probe_neg)
    record("A5 反向自检：探测器能判红且不误报", det_ok and det_clean,
           ("正例未被抓出" if not det_ok else "") + (" / 负例被误报" if not det_clean else ""))

    print("-" * 72)
    failed = [n for n, ok, _ in results if not ok]
    print("TOTAL %d | PASS %d | FAIL %d" % (len(results), len(results) - len(failed), len(failed)))
    if failed:
        for n in failed:
            print("  FAILED: %s" % n)
        print("VERDICT: FAIL")
        return 1
    print("VERDICT: PASS - assets 大二进制未回流 git")
    return 0


if __name__ == "__main__":
    sys.exit(main())
