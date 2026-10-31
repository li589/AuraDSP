#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dart_swallow_scan.py — D4-b 静默异常门禁

背景
----
全仓曾有 109 处代码级 `catch (_) {}`（另有一处出现在文档注释里，被本扫描器
正确排除）。问题不在「吞掉异常」这件事本身——清理路径吞掉是正确语义——而在于
**没有任何机制区分「可预期的失败」和「编程错误」**：

  · 泵循环把整个迭代体包进 `catch (_) {}` + `continue`：一次类型错误就能让
    可视化永远冻结，日志里一个字都没有，排障只能靠猜；
  · 预设加载/保存失败返回 false，调用方只看见 false，不知道为什么。

分类法（扫描器按它判定）
------------------------
  C 类  循环体包壳：catch 块后紧跟 `continue` → 必须 `swallowThrottled(` 留痕。
        不接受注释豁免：这是唯一会「永远静默、永不暴露」的形态。
  A 类  兜底退化：catch 块内有语句（return 兜底等）→ 必须留痕或标记。
  B 类  清理忽略：teardown/free/close 路径 → 允许 `// swallow: <理由>` 豁免。
  D 类  test/ 下：豁免（断言辅助）。

四条规则
--------
  R1  空 catch 块必须「留痕 或 标记」二选一：
        留痕 = 块内含 swallow( / swallowThrottled( / dbgLog(
        标记 = 块内首行或 catch 前 2 行内有 `// swallow: <理由>`
  R2  循环体包壳（catch 后紧跟 continue）必须留痕，且必须是 swallowThrottled(
  R3  不得用匿名 catch 丢弃异常（`catch (_)` / `catch {}`）——绑定 `e` 或标记
  R4  理由不得敷衍：`// swallow:` 后至少 8 个字符，且不得是 ok/none/todo

R3 是本门禁最核心的一条：`catch (_)` 是「我拒绝观测」的语法，异常对象和堆栈
一起被丢掉，连挂调试器都只能靠行号。绑定 `e` 之后，至少一个断点就能拿到全貌；
真要把异常上报到别处（SnackBar / onError / lastErr）也照样合规，不强制记录。

不拦的形态（有意为之）：
  · `catch (e) { return <兜底>; }` —— 已绑定异常对象，兜底语义清晰
  · `catch (e) { onError?.call(...); }` / 弹 SnackBar —— 已上报到别处

用法
----
    python tools/dart_swallow_scan.py            # 检查，有违规则退出码 1
    python tools/dart_swallow_scan.py -v         # 逐条列出
    python tools/dart_swallow_scan.py --json     # 机器可读
"""
import argparse
import io
import json
import os
import re
import sys

LIB_REL = os.path.join('app', 'auradsp_app', 'lib')
TEST_REL = os.path.join('app', 'auradsp_app', 'test')

LOG_CALLS = ('swallow(', 'swallowThrottled(', 'dbgLog(')
MARKER = 'swallow:'
MIN_REASON_LEN = 8
LAZY_REASONS = {'ok', 'none', 'todo', 'n/a', 'na', 'xx', 'fixme', '...'}


def repo_root():
    # 本文件位于 <repo>/tools/bin/，仓库根需上跳两级
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(os.path.dirname(here))


# ---------------------------------------------------------------- 词法剥离
def strip_comments_and_strings(src):
    """返回与 src 等长的掩码串：注释/字符串字符位置替换为空格，换行保留。

    这样后续的括号配对和关键字查找不会命中注释内容或字符串字面量，
    但**字符下标与原始文件一一对应**，便于回查行号与原始文本。
    注意：必须保留长度，否则行号会漂。
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == '//':
            j = src.find('\n', i)
            if j < 0:
                j = n
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif two == '/*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif c in ('"', "'"):
            # 三引号
            if src[i:i + 3] in ('"""', "'''"):
                q = src[i:i + 3]
                j = i + 3
                while j < n and src[j:j + 3] != q:
                    j += 1
                j = min(n, j + 3)
            else:
                q = c
                j = i + 1
                while j < n:
                    if src[j] == '\\':
                        j += 2
                        continue
                    if src[j] == q:
                        j += 1
                        break
                    if src[j] == '\n':      # 未闭合，别吃掉整份文件
                        break
                    j += 1
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def match_brace(mask, open_idx):
    """mask[open_idx] == '{'，返回配对 '}' 的下标；不配对返回 -1。"""
    depth = 0
    for i in range(open_idx, len(mask)):
        ch = mask[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
    return -1


CATCH_RE = re.compile(r'\bcatch\s*(?:\(\s*([^)]*)\))?\s*\{')


def find_catches(mask):
    """在掩码串里找所有 catch 块，产出 (catch_start, body_start, body_end)。"""
    for m in CATCH_RE.finditer(mask):
        body_start = m.end() - 1            # '{' 的位置
        body_end = match_brace(mask, body_start)
        if body_end < 0:
            continue
        yield m.start(), m.group(1) or '', body_start, body_end


def line_of(src, idx):
    return src.count('\n', 0, idx) + 1


def next_token(mask, from_idx, limit=400):
    """跳过空白与注解，取下一个「单词」；用于判断 catch 块后是否紧跟 continue。"""
    i = from_idx
    end = min(len(mask), from_idx + limit)
    while i < end:
        c = mask[i]
        if c.isspace():
            i += 1
            continue
        m = re.match(r'[A-Za-z_]\w*', mask[i:])
        if m:
            return m.group(0)
        return c
    return ''


def preceding_lines(src, idx, count=2):
    start = src.rfind('\n', 0, idx)
    lines = []
    pos = start
    for _ in range(count):
        prev = src.rfind('\n', 0, pos) if pos > 0 else -1
        if prev < 0:
            if pos > 0:
                lines.append(src[:pos])
            break
        lines.append(src[prev + 1:pos])
        pos = prev
    return lines


def has_marker(src, body_start, body_end):
    """标记可以写在 catch 块内首行，或 catch 之前 2 行内。"""
    body = src[body_start:body_end]
    if MARKER in body:
        return True, body
    for ln in preceding_lines(src, body_start):
        if MARKER in ln:
            return True, ln
    return False, ''


def marker_reason_ok(text):
    """校验标记理由是否敷衍。返回 (ok, reason)。"""
    pos = text.find(MARKER)
    if pos < 0:
        return False, ''
    tail = text[pos + len(MARKER):]
    tail = tail.replace('*/', '').replace('//', '').strip()
    if len(tail) < MIN_REASON_LEN:
        return False, tail
    if tail.lower().strip(' .!。') in LAZY_REASONS:
        return False, tail
    return True, tail


def iter_dart_files(root, rel):
    base = os.path.join(root, rel)
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in filenames:
            if fn.endswith('.dart'):
                yield os.path.join(dirpath, fn)


def scan_file(path, root):
    with io.open(path, 'r', encoding='utf-8', errors='replace') as f:
        src = f.read()
    rel = os.path.relpath(path, root).replace('\\', '/')
    return analyze_source(src, rel)


def analyze_source(src, rel='<mem>'):
    """对一段 Dart 源码做规则判定。纯函数——冒烟测试直接喂片段进来验证规则。

    返回每处 catch 块的判定结果；`violations` 非空即为违规。
    """
    mask = strip_comments_and_strings(src)
    sites = []
    for cstart, params, bstart, bend in find_catches(mask):
        body = src[bstart + 1:bend]
        body_code = mask[bstart + 1:bend]
        empty = body_code.strip() == ''
        logged = [c for c in LOG_CALLS if c in body_code]
        marked, marker_text = has_marker(src, bstart, bend)
        reason_ok, reason = marker_reason_ok(marker_text) if marked else (False, '')
        tok = next_token(mask, bend + 1)
        in_loop = (tok == 'continue')
        anon = params.strip() in ('_', '')

        violations = []
        if in_loop:
            cls = 'C'
            if 'swallowThrottled(' not in logged:
                violations.append(
                    'R2 循环体包壳必须 swallowThrottled( 留痕（当前留痕=%s）'
                    % (','.join(logged) or '无'))
        else:
            cls = 'B' if (empty and marked) else 'A'

        if not in_loop:
            if empty and not logged and not marked:
                cls = 'A'
                violations.append('R1 空 catch 块既未留痕也未标记（最差形态）')
            if anon and not marked:
                violations.append('R3 匿名 catch 丢弃异常（`_`），应绑定 `e` 或标记')
            if marked and not reason_ok:
                violations.append('R4 标记理由不成立（%r）' % reason)

        sites.append({
            'file': rel,
            'line': line_of(src, cstart),
            'class': cls,
            'anonymous': anon,
            'empty': empty,
            'logged': logged,
            'marked': marked,
            'reason': reason,
            'in_loop': in_loop,
            'violations': violations,
        })
    return sites


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--include-test', action='store_true',
                    help='连 test/ 一起扫（默认 test/ 属 D 类豁免）')
    args = ap.parse_args()

    root = repo_root()
    all_sites = []
    for p in iter_dart_files(root, LIB_REL):
        all_sites.extend(scan_file(p, root))
    test_sites = []
    if args.include_test:
        for p in iter_dart_files(root, TEST_REL):
            test_sites.extend(scan_file(p, root))

    bad = [s for s in all_sites if s['violations']]
    by_class = {}
    for s in all_sites:
        by_class[s['class']] = by_class.get(s['class'], 0) + 1

    result = {
        'total': len(all_sites),
        'by_class': by_class,
        'violations': len(bad),
        'test_total': len(test_sites),
        'sites': all_sites,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1 if bad else 0

    print('D4-b 静默异常扫描 —— lib/ 共 %d 处 catch 块' % len(all_sites))
    print('  分类：' + '  '.join('%s=%d' % (k, by_class[k])
                                for k in sorted(by_class)) if by_class else '  无')
    if args.include_test:
        print('  test/（D 类豁免，仅供参考）：%d 处' % len(test_sites))

    if bad:
        print('\n违规 %d 处：' % len(bad))
        for s in bad:
            print('  %s:%d [%s类]' % (s['file'], s['line'], s['class']))
            for v in s['violations']:
                print('      - %s' % v)
        if args.verbose:
            print('\n全部明细：')
            for s in all_sites:
                print('  %s:%d [%s] logged=%s marked=%s loop=%s' % (
                    s['file'], s['line'], s['class'],
                    ','.join(s['logged']) or '-', s['marked'], s['in_loop']))
        return 1

    print('\n全部通过：无静默 catch 块。')
    if args.verbose:
        for s in all_sites:
            print('  %s:%d [%s] %s' % (
                s['file'], s['line'], s['class'],
                ','.join(s['logged']) if s['logged'] else ('mark: ' + s['reason'])))
    return 0


if __name__ == '__main__':
    sys.exit(main())
