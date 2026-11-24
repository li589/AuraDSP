# -*- coding: utf-8 -*-
"""ASIO 驱动遥测块采样器（在宾机 vm-win10 上运行）。

读取 Global\\AuraDSP_AsioDriverTelemetry（驱动发布、App 消费的 v3 块），
周期打印 dawCh / running 与逐声道处理前 peakInCh、处理后 peakOutCh，
用于判别「信号没进驱动 / 引擎没处理 / 显示没跟上」这类问题。

判读口径：
  - peakInCh[c]==0 而 DAW 该声道有声 -> 信号没送进驱动（DAW 工程路由侧）
  - peakInCh 有、peakOutCh 无       -> 驱动内引擎宽度/模式问题
  - 两者都有而 App 不显示           -> App 遥测消费侧问题

用法：python guest_telemetry.py [--samples 40] [--interval 0.3]

注意（教训）：ctypes 调 kernel32 必须声明 restype/argtypes，否则 64 位
句柄/指针被默认 int 截断，MapViewOfFile 直接访问违例（0xC0000005）。
"""
import argparse
import ctypes
import struct
import sys
import time
from ctypes import wintypes

BLOCK_NAME = r'Global\AuraDSP_AsioDriverTelemetry'
FILE_MAP_READ = 0x0004
# v3 块内偏移（单位：u32 下标）——magic 0 / version 1 / running 3 /
# sampleRate 5 / dawCh 6 / peakInCh f32[130..137] / peakOutCh f32[138..145]
IDX_VERSION, IDX_RUNNING, IDX_DAWCH = 1, 3, 6
IDX_PEAK_IN, IDX_PEAK_OUT = 130, 138


def open_block(name):
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.OpenFileMappingW.restype = wintypes.HANDLE
    k32.OpenFileMappingW.argtypes = [wintypes.DWORD, wintypes.BOOL,
                                     wintypes.LPCWSTR]
    k32.MapViewOfFile.restype = ctypes.c_void_p
    k32.MapViewOfFile.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                  wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_size_t]
    h = k32.OpenFileMappingW(FILE_MAP_READ, False, name)
    if not h:
        print('open failed err', ctypes.get_last_error())
        sys.exit(1)
    p = k32.MapViewOfFile(h, FILE_MAP_READ, 0, 0, 1024)
    if not p:
        print('map failed err', ctypes.get_last_error())
        sys.exit(1)
    return (ctypes.c_char * 1024).from_address(p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--samples', type=int, default=6)
    ap.add_argument('--interval', type=float, default=0.7)
    args = ap.parse_args()
    buf = open_block(BLOCK_NAME)

    def u32(i):
        return struct.unpack_from('<I', buf, i * 4)[0]

    def f32(i):
        return struct.unpack_from('<f', buf, i * 4)[0]

    print('version %d running %d dawCh %d'
          % (u32(IDX_VERSION), u32(IDX_RUNNING), u32(IDX_DAWCH)))
    for t in range(args.samples):
        pin = [f32(IDX_PEAK_IN + c) for c in range(8)]
        pout = [f32(IDX_PEAK_OUT + c) for c in range(8)]
        print('t%02d in [' % t + ' '.join('%.3f' % v for v in pin)
              + '] out [' + ' '.join('%.3f' % v for v in pout) + ']')
        if t + 1 < args.samples:
            time.sleep(args.interval)
    print('telemetry done')


if __name__ == '__main__':
    main()
