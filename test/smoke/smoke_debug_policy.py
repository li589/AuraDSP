# -*- coding: utf-8 -*-
"""smoke_debug_policy.py — 调试体系文件与打印规范门禁。

对应 2026-11-01 用户要求：
  · 所有打印操作受调试体系约束（禁止业务代码直接 print/debugPrint）；
  · 控件动作与 DSP 回执统一为结构化事件；
  · 调试实例可通过命令行启动。
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCAN = os.path.join(ROOT, 'tools', 'bin', 'debug_log_scan.py')
TRACE = os.path.join(ROOT, 'app', 'auradsp_app', 'lib', 'core', 'debug', 'debug_trace.dart')
HUD = os.path.join(ROOT, 'app', 'auradsp_app', 'lib', 'features', 'debug', 'debug_hud.dart')
RUNNER = os.path.join(ROOT, 'tools', 'debug', 'run_debug.ps1')
FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + (('  ' + detail) if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


print('=== 调试体系门禁 ===')
check('DebugTrace 存在', os.path.isfile(TRACE), TRACE)
check('Debug HUD 存在', os.path.isfile(HUD), HUD)
check('命令行启动器存在', os.path.isfile(RUNNER), RUNNER)

if os.path.isfile(SCAN):
    r = subprocess.run([sys.executable, SCAN], cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(r.stdout.strip())
    check('无直接 print/debugPrint', r.returncode == 0, 'rc=%d' % r.returncode)
else:
    check('debug_log_scan.py 存在', False, SCAN)

print()
if FAIL:
    print('DEBUG POLICY FAILURES:', FAIL)
    sys.exit(1)
print('debug_policy: all checks passed')
