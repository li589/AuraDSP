"""smoke_channel_map.py — 声道适配统一表数值单测（第五十五轮）。

背景：APO/VB/VAIO/ASIO 各自抄声道映射与下混表，两次漂移
（r47 漏 VAIO 离散截断、r55 前 VAIO 矩阵 8→4 主次仍旧表）。
表已收编至 engine/chain/channel_map.h，本 smoke 跑其宿主
单测 channel_map_test.exe（驱动无关）：位置表、离散
gather/scatter、矩阵下混全表（含 8→4 BL/BR 为主哨），逐项
数值断言。前身为 smoke_vaio_channel_map.py（第五十四轮）。
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_EXE = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers', 'out',
                        'Release', 'channel_map_test.exe')

FAIL = []


def check(name, cond, detail=''):
    print(('PASS  ' if cond else 'FAIL  ') + name +
          (f'  ({detail})' if detail and not cond else ''))
    if not cond:
        FAIL.append(name)


def main():
    check('channel_map_test_exe_present', os.path.isfile(TEST_EXE),
          TEST_EXE)
    if FAIL:
        return 1
    r = subprocess.run([TEST_EXE], capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=60)
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    check('channel_map_test_rc0', r.returncode == 0,
          f'rc={r.returncode}')
    check('channel_map_test_all_pass', 'ALL PASS' in r.stdout)
    print(f"== smoke_channel_map: {'FAIL' if FAIL else 'PASS'} "
          f"({len(FAIL)} failures) ==")
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
