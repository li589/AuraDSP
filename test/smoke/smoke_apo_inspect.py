"""smoke_apo_inspect.py — APO 只读检测验收。

验收标准（机器无关，不提权）：
  1. apo_inspect.exe 存在且退出码 0，输出单行合法 JSON。
  2. 端点为空（无头 CI）→ 记 note 即 PASS。
  3. 有端点 → 每项含 id/direction/name/state/fx 五槽/readable；
     readable 的项 fx 恰 5 个槽；protectedAudioDG ∈ {-1,0,1}。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'apo_inspect.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


check('apo_inspect.exe exists', os.path.exists(EXE), EXE)
if not os.path.exists(EXE):
    print('APOINSPECT FAILURES:', FAIL)
    sys.exit(1)

r = subprocess.run([EXE], capture_output=True, text=True, errors='replace', timeout=120)
check('exit code 0', r.returncode == 0, 'rc=%d err=%s' % (r.returncode, (r.stderr or '').strip()[:120]))
stdout = r.stdout or ''
try:
    d = json.loads(stdout.strip().splitlines()[-1])
    check('valid JSON dict', isinstance(d, dict))
except (ValueError, IndexError) as ex:
    check('valid JSON dict', False, str(ex)[:100])
    d = None

if d is not None:
    eps = d.get('endpoints')
    check('endpoints is list', isinstance(eps, list))
    if isinstance(eps, list):
        if not eps:
            print('NOTE no audio endpoints (headless?): skip per-endpoint asserts')
        n_readable = 0
        for e in eps:
            ok = all(k in e for k in ('id', 'direction', 'name', 'state', 'fx', 'readable'))
            if not ok:
                check('endpoint schema', False, str(sorted(e.keys())))
                break
            if e.get('readable'):
                n_readable += 1
                if len(e.get('fx', [])) != 5:
                    check('readable fx has 5 slots', False, '%s slots=%d' % (e.get('id'), len(e.get('fx', []))))
                    break
        else:
            check('endpoint schema', True)
            print('NOTE endpoints=%d readable=%d' % (len(eps), n_readable))
    check('protectedAudioDG in {-1,0,1}', d.get('protectedAudioDG') in (-1, 0, 1),
          str(d.get('protectedAudioDG')))

print()
if FAIL:
    print('APOINSPECT FAILURES:', FAIL)
    sys.exit(1)
print('apo_inspect: all checks passed')
