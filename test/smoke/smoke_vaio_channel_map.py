"""smoke_vaio_channel_map.py — VAIO 桥离散截断位置映射数值单测。

第五十四轮定罪：离散截断原为顺序拷贝，引擎 4ch（Quad:
FL,FR,BL,BR）在 7.1 流里应取第 7/8 声道（BL/BR），实际对到
第 3/4 声道（C/LFE）。本 smoke 跑 vaio_channel_map_test.exe
（VaioChannelMap.h 的宿主单测，驱动无关）：位置表、gather
取位、scatter 整帧清零后只回写映射位置，逐项数值断言。
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out',
                        'Release', 'vaio_channel_map_test.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name +
          (f'  ({detail})' if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


def main():
    check('vaio_channel_map_test_exe_present', os.path.isfile(TEST_EXE),
          TEST_EXE)
    if FAIL:
        return 1
    r = subprocess.run([TEST_EXE], capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=60)
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    check('vaio_channel_map_test_rc0', r.returncode == 0,
          f'rc={r.returncode}')
    check('vaio_channel_map_test_all_pass', 'ALL PASS' in r.stdout)
    print(f"== smoke_vaio_channel_map: {'FAIL' if FAIL else 'PASS'} "
          f"({len(FAIL)} failures) ==")
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
