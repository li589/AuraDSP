"""smoke_vm_detect.py — Voicemeeter 三级自省检测验收。

验收标准（机器无关：有/无 Voicemeeter 都必须 PASS）：
  1. vm_detect.exe 存在且退出码 0，输出单行合法 JSON。
  2. 自洽性：found=false → edition==0 且 tierReached==0；
     found=true → edition in {1,2,3} 且 tierReached in {1,2,3}。
  3. 本机（Voicemeeter 全家桶）期望：edition==3 且 tierReached>=2。
     非本机无此断言——只做存在性 sniff，不硬编码。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'vm_detect.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


check('vm_detect.exe exists', os.path.exists(EXE), EXE)
if not os.path.exists(EXE):
    print('VMDETECT FAILURES:', FAIL)
    sys.exit(1)

r = subprocess.run([EXE], capture_output=True, text=True, timeout=60)
check('exit code 0', r.returncode == 0, 'rc=%d err=%s' % (r.returncode, r.stderr.strip()[:120]))
try:
    d = json.loads(r.stdout.strip().splitlines()[-1])
    check('valid JSON dict', isinstance(d, dict))
except (ValueError, IndexError) as ex:
    check('valid JSON dict', False, str(ex)[:100])
    d = None

if d is not None:
    found = d.get('found') is True
    ed, tier = d.get('edition'), d.get('tierReached')
    if not found:
        check('absent self-consistent', ed == 0 and tier == 0, str(d))
    else:
        check('edition in 1..3', ed in (1, 2, 3), str(d))
        check('tierReached in 1..3', tier in (1, 2, 3), str(d))
        for k in ('editionName', 'installDir'):
            check('has %s' % k, isinstance(d.get(k), str) and len(d.get(k)) > 0, str(d))

print()
if FAIL:
    print('VMDETECT FAILURES:', FAIL)
    sys.exit(1)
print('vm_detect: all checks passed')
