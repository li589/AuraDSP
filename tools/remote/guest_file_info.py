# -*- coding: utf-8 -*-
"""宾机文件核对：在宾机上打印指定文件的大小与 SHA-256。

交付核对的宾机侧一半——开发机侧算一遍、宾机侧算一遍，两边一致才算
投递落地（不认 scp 退出码）。

用法：python guest_file_info.py <path>
缺文件时列出同目录下名字含 AuraDSP 的文件，便于发现投错位置。
"""
import hashlib
import os
import sys


def main():
    if len(sys.argv) < 2:
        print('usage: guest_file_info.py <path>')
        return 1
    p = sys.argv[1]
    if os.path.exists(p):
        data = open(p, 'rb').read()
        print('path', p)
        print('size', len(data))
        print('sha256', hashlib.sha256(data).hexdigest())
    else:
        print('NOT FOUND:', p)
        d = os.path.dirname(p)
        if os.path.isdir(d):
            print('dir AuraDSP entries:',
                  [f for f in os.listdir(d) if 'AuraDSP' in f])
    print('file info done')
    return 0


if __name__ == '__main__':
    sys.exit(main())
