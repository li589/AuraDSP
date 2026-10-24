#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""patch_id_scan.py — D6 补丁编号门禁（审查 §7-4）

背景
----
改造前代码里有 77 处 `PATCHED-AuraDSP` 标记，其中 43 处**没有 `P-NNN` 编号**，
只写了工程专项代号（`B1-c` / `B4` / `D7` / `Z13` / `M3.5-c` / `P2.4` …）。后果：

  · `engine/legacy/PATCHES.md` 号称是补丁唯一真相源，实际九套编号并存，
    `P2.4` 在整个仓库里只命中一处 PDF 二进制——等于没有任何登记；
  · 拿着代码里的 `B5` 去查登记表，查不到（`B5` 从未在 PATCHES.md 出现过）；
  · 想做「这个补丁改过哪些文件」的统计，得先猜编号体系。

修法（本门禁强制）
------------------
  G1  每个代码级 `PATCHED-AuraDSP` 必须紧跟 `P-\\d{3}` 编号
  G2  该编号必须在 `engine/legacy/PATCHES.md` 有 `## P-NNN` 章节
  G3  同一别名（编号之后紧跟的专项代号）不得映射到两个编号
  G4  登记表内不得出现重复的 `## P-NNN` 章节

编号语义：`P-NNN` 单调递增、永不复用，是**唯一权威标识**；工程专项代号降级为
别名，只用于和审查报告章节对照（`P-018 B1-c`）。

扫描范围：代码文件（.c/.cpp/.cc/.h/.hpp/.dart），排除 .git/build/out/
node_modules/.dart_tool/.tmp/archive。**不扫 .md**：文档里的 `[PATCHED-AuraDSP P-xxx]`
是模板占位（本文件的规则说明、AGENT.md 的约定都需要它），把模板判成违规会让
门禁无法自洽。

用法
----
    python tools/bin/patch_id_scan.py          # 检查，有违规则退出码 1
    python tools/bin/patch_id_scan.py -v       # 逐条列出标记
    python tools/bin/patch_id_scan.py --json   # 机器可读
"""
import argparse
import io
import json
import os
import re
import sys

CODE_EXTS = ('.c', '.cc', '.cpp', '.h', '.hpp', '.dart')
SKIP_DIRS = {'.git', 'build', 'out', 'node_modules', '.dart_tool',
             '.tmp', 'archive', '__pycache__'}

PATCHES_REL = os.path.join('engine', 'legacy', 'PATCHES.md')

MARKER_RE = re.compile(r'\[PATCHED-AuraDSP([^\]]*)\]')
ID_RE = re.compile(r'P-\d{3}')
HEADING_RE = re.compile(r'^##\s+(P-\d{3})\b(.*)$', re.M)


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))


def iter_code(root):
    for dirpath, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for fn in fns:
            if fn.endswith(CODE_EXTS):
                yield os.path.join(dirpath, fn)


def load_registry(root):
    """返回 {编号: 标题} + 重复编号列表。"""
    path = os.path.join(root, PATCHES_REL)
    if not os.path.exists(path):
        return {}, [], None
    text = io.open(path, encoding='utf-8', errors='replace').read()
    reg, dup = {}, []
    for m in HEADING_RE.finditer(text):
        num = m.group(1)
        if num in reg:
            dup.append(num)
            continue
        reg[num] = m.group(2).strip()
    return reg, dup, text


def alias_of(tail):
    """标记里编号之后紧跟的专项代号（如 ` P-018 B1-c]` → `B1-c`）。

    没有别名返回 ''；`P-018]` / `P-018 （说明）]` 都算无别名。
    """
    m = re.match(r'\s*P-\d{3}\s*(.*)$', tail, re.S)
    if not m:
        return ''
    rest = m.group(1).strip()
    if not rest:
        return ''
    tok = rest.split()[0]
    # 别名只认「像代号的」：字母/数字/点/连字符，且不含中文
    if re.fullmatch(r'[A-Za-z][A-Za-z0-9.\-]*', tok):
        return tok
    return ''


def evaluate(tail, registry):
    """纯函数：判定一处标记（方括号内的文本）。冒烟测试直接喂片段进来。

    返回 (编号, 别名, violations)。

    **编号必须紧跟标记**（`[PATCHED-AuraDSP P-018 B1-c]`）。写在后面的说明文字里
    不算——`[PATCHED-AuraDSP 2026-10-09] …（P-002，见 PATCHES.md）` 这种写法
    按行 grep 看起来"有编号"，实际标记位是空的：搜 `PATCHED-AuraDSP P-` 找不到它，
    统计脚本也会漏。这类漏网在本专项里真实存在过两处。
    """
    m = re.match(r'\s*(P-\d{3})', tail)
    num = m.group(1) if m else ''
    alias = alias_of(tail) if num else ''
    violations = []
    if not num:
        violations.append(
            'G1 标记未紧跟 P-NNN 编号（当前：%r）' % tail.strip()[:40])
    elif num not in registry:
        violations.append('G2 编号 %s 未在 %s 登记' % (num, PATCHES_REL))
    return num, alias, violations


def scan(root):
    reg, dup, _text = load_registry(root)
    sites, alias_map = [], {}
    for p in iter_code(root):
        rel = os.path.relpath(p, root).replace('\\', '/')
        try:
            src = io.open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for m in MARKER_RE.finditer(src):
            tail = m.group(1)
            line = src.count('\n', 0, m.start()) + 1
            num, alias, violations = evaluate(tail, reg)
            if num and alias:
                prev = alias_map.get(alias)
                if prev and prev != num:
                    violations.append(
                        'G3 别名 %s 映射到多个编号（%s / %s）' % (alias, prev, num))
                else:
                    alias_map[alias] = num
            sites.append({
                'file': rel, 'line': line, 'id': num, 'alias': alias,
                'tail': tail.strip()[:80], 'violations': violations,
            })
    dup_viol = ['G4 登记表重复编号 %s' % d for d in dup]
    return sites, reg, dup_viol


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    root = repo_root()
    sites, reg, dup_viol = scan(root)
    bad = [s for s in sites if s['violations']]

    if args.json:
        print(json.dumps({
            'markers': len(sites), 'violations': len(bad) + len(dup_viol),
            'registry': len(reg), 'sites': sites, 'registry_violations': dup_viol,
        }, ensure_ascii=False, indent=2))
        return 1 if (bad or dup_viol) else 0

    print('D6 补丁编号门禁 —— 代码标记 %d 处 / 登记表 %d 条' % (len(sites), len(reg)))
    if not sites:
        print('违规：代码里找不到任何 PATCHED-AuraDSP 标记——扫描器可能没扫到东西')
        return 1

    aliased = sum(1 for s in sites if s['alias'])
    print('  带专项代号别名 %d 处，别名去重 %d 个'
          % (aliased, len({s['alias'] for s in sites if s['alias']})))

    total = len(bad) + len(dup_viol)
    if total:
        print('\n违规 %d 处：' % total)
        for s in bad:
            print('  %s:%d' % (s['file'], s['line']))
            for v in s['violations']:
                print('      - %s' % v)
        for v in dup_viol:
            print('  %s' % v)
        return 1

    print('\n全部通过：每个标记都有已登记的 P-NNN，别名映射唯一。')
    if args.verbose:
        for s in sites:
            print('  %s:%d  %s%s' % (s['file'], s['line'], s['id'],
                                     (' ' + s['alias']) if s['alias'] else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
