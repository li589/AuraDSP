"""smoke_vm_pump.py — Voicemeeter OUTPUT INSERT 泵验收。

验收标准（机器无关）：
  1. vm_pump_test.exe 存在且退出码 0，输出单行合法 JSON。
  2. ran=false（无 VM / 槽被占 / 启动失败）→ 只打印 note，PASS（优雅跳过）。
  3. run1（中性）：frames 达到实时跟量（>=2s×sr），透传 maxDiff < 1e-4，
     sampleRate/nbs/groups/handles/budget 合法。
  4. run2（tube 12dB 参数下发）：applied==2 且 failed==0；有声（peakIn>0.1）时
     maxDiff 必须起量（>1e-5），静默总线只记 note 不判（声学不可证）。
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

# run2：参数下发面（tube 12dB）。声学断言是有条件的：总线静默时 bypass 接管，
# maxDiff 恒 0 恰恰证明透传正确；只在有声（peakIn>0.1）时要求染色起量。
r2 = subprocess.run([EXE, '4', '', '--seti', 'tube.enable=1', '--setf', 'tube.gain=12.0'],
                    capture_output=True, text=True, timeout=120)
check('param run exit 0', r2.returncode == 0, 'rc=%d' % r2.returncode)
try:
    d2 = json.loads(r2.stdout.strip().splitlines()[-1])
except (ValueError, IndexError) as ex:
    check('param run valid JSON', False, str(ex)[:100])
    d2 = None
if d2 is not None:
    if not d2.get('ran'):
        print('NOTE param run skipped: %s' % d2.get('note', '?'))
    else:
        check('params applied==2', d2.get('paramsApplied') == 2, str(d2.get('paramsApplied')))
        check('params failed==0', d2.get('paramsFailed') == 0, str(d2.get('paramsFailed')))
        peak = d2.get('peakIn') or 0.0
        md2 = d2.get('maxDiff')
        if peak > 0.1:
            check('hot signal colored (maxDiff>1e-5)', isinstance(md2, (int, float)) and md2 > 1e-5,
                  'peak=%.4f maxDiff=%s' % (peak, md2))
        else:
            print('NOTE silent bus (peak=%.6f): acoustic unproven, plumbing proven' % peak)

print()
if FAIL:
    print('VMPUMP FAILURES:', FAIL)
    sys.exit(1)
print('vm_pump: all checks passed')
