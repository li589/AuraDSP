"""smoke_apo_selftest.py — 自研 APO 对象级自测（不进 audiodg）。

验收：apo_selftest.exe 全 PASS（CoCreateInstance/QI 五接口/Initialize/格式/
LockForProcess/bit-exact 透传/心跳映射/Unlock），JSON selftest=true。
机器无关：无需 VM、无需管理员、不碰注册表（只建 Global 心跳映射，进程退出即清）。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'apo_selftest.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


if not os.path.exists(EXE):
    print('NOTE  apo_selftest.exe 不存在（未构建 Release 产物），跳过')
    print('apo_selftest: SKIPPED (not built)')
    sys.exit(0)

r = subprocess.run([EXE], capture_output=True, text=True, errors='replace', timeout=120)
check('exit code 0', r.returncode == 0, 'rc=%d' % r.returncode)
out = r.stdout or ''
lines = [line for line in out.splitlines() if line.startswith('[')]
for line in lines:
    tag, rest = line[1:].split(']', 1)
    check('selftest ' + rest.strip().split(' ')[0], tag == 'PASS', rest.strip()[:100])
try:
    d = json.loads([line for line in out.splitlines() if line.startswith('{')][-1])
    check('selftest JSON true', d.get('selftest') is True, str(d))
except (ValueError, IndexError) as ex:
    check('selftest JSON true', False, str(ex)[:100])

print()
if FAIL:
    print('APOSELFTEST FAILURES:', FAIL)
    sys.exit(1)
print('apo_selftest: all checks passed')
