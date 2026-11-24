# -*- coding: utf-8 -*-
"""宾机 REAPER 状态回读：找 reaper.ini 并打印 [asiochan] 段。

[asiochan] 里的 `AuraDSP Driver=<in_lo> <in_hi> <out_lo> <out_hi>`
是 REAPER 首选项里 ASIO 输入/输出声道范围；多声道问题先看这里是否
全开（7.1 应为 0 7 0 7）。注意：范围全开 != 工程路由正确——轨道与
主轨的 Track channels 仍需各自设为目标声道数（见 README）。

用法：python guest_reaper_state.py
"""
import glob
import os


def main():
    cands = []
    for base in (os.path.expandvars(r'%APPDATA%\REAPER'),
                 r'C:\Program Files\REAPER'):
        cands += glob.glob(os.path.join(base, '**', 'reaper.ini'),
                           recursive=True)
    cands = sorted(set(cands))
    print('ini candidates:', cands)
    for p in cands:
        try:
            txt = open(p, encoding='utf-8', errors='replace').read()
        except Exception as e:
            print(p, 'ERR', e)
            continue
        print('=====', p)
        in_sec = False
        for line in txt.splitlines():
            s = line.strip()
            if s.startswith('['):
                in_sec = (s.lower() == '[asiochan]')
                if in_sec:
                    print(s)
                continue
            if in_sec and s:
                print(' ', s)
    print('reaper state done')


if __name__ == '__main__':
    main()
