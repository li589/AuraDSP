# -*- coding: utf-8 -*-
"""debug_log_scan.py — 调试打印规范门禁。

规则：
  1. app/auradsp_app/lib 下禁止直接 print( / debugPrint(；
     唯一例外是调试总线 debug_trace.dart（其内部仍用 debugPrint 报启动失败）。
  2. 必须存在统一调试总线 core/debug/debug_trace.dart；
  3. 必须存在命令行启动器 tools/debug/run_debug.ps1。

不扫描 engine/legacy 第三方/厂商代码里的历史 printf；引擎宿主调试日志由
编译期 AURADSP_DBG_LOG + 运行期 AURADSP_LOG 约束（engine/debug_log.h）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_LIB = os.path.join(ROOT, 'app', 'auradsp_app', 'lib')
TRACE = os.path.join(APP_LIB, 'core', 'debug', 'debug_trace.dart')
RUNNER = os.path.join(ROOT, 'tools', 'debug', 'run_debug.ps1')
ALLOW = {'debug_trace.dart', 'debug_log.dart'}
PAT = re.compile(r'\b(?:print|debugPrint)\s*\(')


def main():
    fails = []
    hits = []
    for dirpath, _, files in os.walk(APP_LIB):
        for fn in files:
            if not fn.endswith('.dart') or fn in ALLOW:
                continue
            path = os.path.join(dirpath, fn)
            try:
                for i, line in enumerate(open(path, encoding='utf-8'), 1):
                    if PAT.search(line):
                        hits.append('%s:%d: %s' % (
                            os.path.relpath(path, ROOT), i, line.strip()))
            except UnicodeDecodeError:
                fails.append('无法解码: ' + path)
    if hits:
        fails.append('发现 %d 处直接 print/debugPrint：' % len(hits))
        fails.extend('  ' + h for h in hits[:20])
    for p in (TRACE, RUNNER):
        if not os.path.isfile(p):
            fails.append('缺少调试体系文件: ' + os.path.relpath(p, ROOT))

    print('checked app lib: %s' % os.path.relpath(APP_LIB, ROOT))
    if fails:
        print('FAIL')
        for f in fails:
            print(f)
        return 1
    print('PASS: no direct print/debugPrint; debug trace + CLI launcher present')
    return 0


if __name__ == '__main__':
    sys.exit(main())
