# -*- coding: utf-8 -*-
"""smoke_plugin_quarantine.py — B3 验收：RT 异常滞留时卸载必须保留实例（隔离）。

驱动 test_host_quarantine.exe：假实例 process() 在事件上阻塞，注入「插件死锁
在音频线程内」的现场，断言

  1) 卸载按墙钟上界返回（~kQuiesceWaitMs=100ms）——既不立即返回（原实现
     `inFlight.wait(0)` 语义写错，实为几十 µs 空转），也不永久挂住控制线程；
  2) 实例未被析构（移入隔离区），且 closeEditor/deactivate/unload 一次未调
     （对在途实例那样做同样是 UAF，unload 还会卸库）；
  3) 槽 inFlight 清零，滞留线程晚些退出时饱和递减不下溢（仍为 0）；
  4) 槽未被毒化：紧接着的正常卸载照常销毁实例并跑完 teardown。

机器无关：无插件依赖、无计时敏感阈值（只有 50ms 下界与 2s 上界）。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows', 'out', 'Release',
                   'test_host_quarantine.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


check('test_host_quarantine.exe exists', os.path.exists(EXE), EXE)
if not os.path.exists(EXE):
    print('HOSTQUARANTINE FAILURES:', FAIL)
    sys.exit(1)

try:
    r = subprocess.run([EXE], capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    check('exe finished (no deadlock)', False, 'timeout 120s — 控制线程被滞留 RT 永久挂住？')
    print('HOSTQUARANTINE FAILURES:', FAIL)
    sys.exit(1)

check('exit code 0', r.returncode == 0,
      'rc=%d err=%s' % (r.returncode, r.stderr.strip()[:200]))
try:
    d = json.loads(r.stdout.strip().splitlines()[-1])
    check('valid JSON dict', isinstance(d, dict))
except (ValueError, IndexError) as ex:
    check('valid JSON dict', False, str(ex)[:120])
    d = {}

check('all assertions ok', d.get('ok') is True, 'note=%s' % (d.get('note', ''),))

ms = d.get('unloadMs', -1)
check('quiesce wait effective (unloadMs >= 50)', isinstance(ms, int) and ms >= 50,
      'unloadMs=%s（原 wait(0) 实现在此判红）' % (ms,))
check('quiesce wait bounded (unloadMs <= 2000)', isinstance(ms, int) and 0 <= ms <= 2000,
      'unloadMs=%s' % (ms,))
check('instance not destroyed (quarantined)', d.get('dtorStuck') == 0,
      'dtorStuck=%s' % (d.get('dtorStuck'),))
check('no destructor inside process', d.get('destroyedWhileInside') == 0,
      'destroyedWhileInside=%s' % (d.get('destroyedWhileInside'),))
check('no instance calls on stuck instance', d.get('stuckInstanceCalls') == 0,
      'calls=%s' % (d.get('stuckInstanceCalls'),))
check('slot inFlight cleared after quarantine', d.get('slotInFlightAfterStuck') == 0,
      'inFlight=%s' % (d.get('slotInFlightAfterStuck'),))
check('no underflow after straggler exit', d.get('inFlightAfterStraggler') == 0,
      'inFlight=%s' % (d.get('inFlightAfterStraggler'),))
check('quiesced unload still destroys', d.get('normalDtor') == 1,
      'normalDtor=%s' % (d.get('normalDtor'),))

if FAIL:
    print('HOSTQUARANTINE FAILURES:', FAIL)
    sys.exit(1)
print('HOSTQUARANTINE ALL PASSED')
