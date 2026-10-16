"""smoke_asio_tone.py — ASIO 驱动发声链路验收（04_asio_client Phase 1）。

验收标准（Spec §3 Phase 1 / §6）：
  1. asio_tone.exe 存在（需先构建）。
  2. 选定驱动跑 3 秒 440Hz/0.25 正弦：rc=0、switches>0、peak≈amp、
     bufSize/sampleRate 有效。
  3. 缓冲数学自洽：switches*bufSize/sampleRate ≈ seconds（±35%，容忍调度抖动）。
  4. 驱动优先级：FL Studio ASIO > Voicemeeter Virtual ASIO > 任一 ok 驱动；
     本机无可用驱动时记 note 跳过（机器无关验收）。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                   'asio_tone.exe')
PROBE_EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out', 'Release',
                         'asio_probe.exe')
PREFERRED = ['FL Studio ASIO', 'Voicemeeter Virtual ASIO']

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name + (('  ' + detail) if (detail and not cond) else ''))
    if not cond:
        FAIL.append(name)


def pick_driver():
    """按优先级挑一个可用驱动；无则 None。"""
    try:
        r = subprocess.run([PROBE_EXE], capture_output=True, timeout=120)
        data = json.loads(r.stdout.decode('utf-8'))
    except Exception:
        return None
    ok_names = [d['name'] for d in data.get('drivers', []) if d.get('ok')]
    for p in PREFERRED:
        if p in ok_names:
            return p
    return ok_names[0] if ok_names else None


def run_tone(driver, seconds=3.0):
    try:
        r = subprocess.run([EXE, '--driver', driver, '--seconds', str(seconds)],
                           capture_output=True, timeout=seconds + 60)
    except subprocess.TimeoutExpired:
        return None
    try:
        return json.loads(r.stdout.decode('utf-8'))
    except Exception:
        return None


def main():
    print('== smoke_asio_tone ==')
    if not os.path.exists(EXE):
        print('NOTE  asio_tone.exe 不存在（未构建 windows-drivers），跳过')
        print('asio_tone: SKIPPED (not built)')
        return 0
    if sys.platform != 'win32':
        print('NOTE  非 Windows，跳过')
        return 0

    driver = pick_driver()
    if driver is None:
        print('NOTE  本机无可用 ASIO 驱动，发声断言跳过')
        print('asio_tone: SKIPPED (no openable driver)')
        return 0
    print('      选定驱动:', driver)

    seconds = 3.0
    res = run_tone(driver, seconds)
    check('asio_tone 输出合法 JSON', res is not None)
    if res is None:
        print()
        print('ASIO_TONE FAILURES:', FAIL)
        return 1

    check('rc=0', res.get('rc') == 0, 'err=%s' % res.get('err'))
    check('switches>0', res.get('switches', 0) > 0, str(res.get('switches')))
    peak = res.get('peak', 0.0)
    check('peak≈amp(0.25)', abs(peak - 0.25) < 0.05, 'peak=%s' % peak)
    check('bufSize>0', res.get('bufSize', 0) > 0)
    check('sampleRate>0', res.get('sampleRate', 0) > 0)
    check('sampleType 已知', res.get('sampleType', 'Unknown') != 'Unknown')

    sw = res.get('switches', 0)
    bs = res.get('bufSize', 0)
    sr = res.get('sampleRate', 0)
    if sw > 0 and bs > 0 and sr > 0:
        elapsed = sw * bs / sr
        check('缓冲数学 ≈ seconds(±35%)', abs(elapsed - seconds) / seconds < 0.35,
              'elapsed=%.3fs' % elapsed)
        print('      （%d 帧缓冲 × %d 样本 / %.0fHz = %.3fs）' % (sw, bs, sr, elapsed))

    print()
    if FAIL:
        print('ASIO_TONE FAILURES:', FAIL)
        return 1
    print('asio_tone: all checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
