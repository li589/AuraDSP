"""smoke_vm_pump.py — Voicemeeter OUTPUT INSERT 泵验收。

验收标准（机器无关）：
  1. vm_pump_test.exe 存在且退出码 0，输出单行合法 JSON。
  2. ran=false（无 VM / 槽被占 / 启动失败）→ 只打印 note，PASS（优雅跳过）。
  3. ran=true → frames 达到实时跟量（>=2s×sr），中性引擎透传
     maxDiff < 1e-4（本机实测恒 0.0），sampleRate/nbs 合法。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'vm_pump_test.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + ('  ' + detail if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


check('vm_pump_test.exe exists', os.path.exists(EXE), EXE)
if not os.path.exists(EXE):
    print('VMPUMP FAILURES:', FAIL)
    sys.exit(1)

r = subprocess.run([EXE, '3'], capture_output=True, text=True, timeout=120)
check('exit code 0', r.returncode == 0, 'rc=%d err=%s' % (r.returncode, r.stderr.strip()[:120]))
try:
    d = json.loads(r.stdout.strip().splitlines()[-1])
    check('valid JSON dict', isinstance(d, dict))
except (ValueError, IndexError) as ex:
    check('valid JSON dict', False, str(ex)[:100])
    d = None

if d is not None:
    if not d.get('ran'):
        print('NOTE pump skipped: %s' % d.get('note', '?'))
    else:
        sr = d.get('sampleRate', 0)
        check('frames kept real-time', d.get('frames', 0) >= 2 * max(sr, 1),
              'frames=%s sr=%s' % (d.get('frames'), sr))
        md = d.get('maxDiff')
        check('neutral passthrough maxDiff<1e-4', isinstance(md, (int, float)) and md < 1e-4,
              'maxDiff=%s' % md)
        check('sampleRate sane', sr in (44100, 48000, 88200, 96000, 192000), 'sr=%s' % sr)
        check('nbs in range', 0 < d.get('nbs', 0) <= 4096, 'nbs=%s' % d.get('nbs'))
        check('groups>=1', isinstance(d.get('groups'), int) and d.get('groups') >= 1,
              'groups=%s' % d.get('groups'))
        if d.get('engine'):
            check('handles cover groups', isinstance(d.get('handles'), int) and d.get('handles') >= d.get('groups', 0),
                  'handles=%s groups=%s' % (d.get('handles'), d.get('groups')))
        # 爆音预算：单次回调耗时必须远小于缓冲周期（2048/48k=42.7ms），否则必欠载。
        # 本机中性引擎 8 组约 3.2ms；阈值取半周期，留足机器差异与效果全开余量。
        md = d.get('maxCbUs')
        check('callback budget maxCbUs<20000', isinstance(md, (int, float)) and md < 20000,
              'maxCbUs=%s' % md)
        check('changes counter present', isinstance(d.get('changes'), int) and d.get('changes') >= 0,
              'changes=%s' % d.get('changes'))

print()
if FAIL:
    print('VMPUMP FAILURES:', FAIL)
    sys.exit(1)
print('vm_pump: all checks passed')
