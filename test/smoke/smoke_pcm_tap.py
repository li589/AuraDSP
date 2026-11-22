#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_pcm_tap.py — PCM tap 附加导出 auradsp_pcm_read（2026-11-23 W2）

projectM 等波形消费者需要真 PCM，而 viz 频谱是仪表数据（32 频带
幅值、无相位），不可替代。W2 在 viz_write 的同一趟遍历里旁路记录
处理后立体声 L/R 到定长环（engine_internal.h pcm_hist），并以
auradsp_pcm_read 附加导出（ABI 号不变，宿主按符号在场性降级）。

本用例钉住三件事：
  1. 导出存在且在任何 process 之前读返回 0（无数据不编造）。
  2. 灌入已知信号后，pcm_read 返回的最近 N 帧与 process() 最后
     输出缓冲的尾部逐帧一致（容差 1e-6）——tap 录的是「处理后
     输出」而不是输入或分析窗均值。
  3. 请求超过已写入总量时返回实际总量（钳制语义），环长上限
     8192 帧同理。

引擎产物缺失时自 SKIP 退出 0（仓库惯例，同 smoke_linux_engine_exports）。
"""
import ctypes
import math
import os
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
sys.path.insert(0, TEST_DIR)

from engine_artifact import find_engine_lib  # noqa: E402

FS = 48000.0
BLOCK = 512
BLOCKS = 10
TOL = 1e-6

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main() -> int:
    lib = find_engine_lib()
    if not lib:
        print("  SKIP 引擎产物缺失（未构建），按仓库惯例跳过")
        return 0
    dll = ctypes.CDLL(lib)
    if not hasattr(dll, "auradsp_pcm_read"):
        check(False, "auradsp_pcm_read 导出存在")
        return 1
    check(True, "auradsp_pcm_read 导出存在")

    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p,
                                    ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float),
                                    ctypes.c_int]
    dll.auradsp_pcm_read.restype = ctypes.c_uint32
    dll.auradsp_pcm_read.argtypes = [ctypes.c_void_p,
                                     ctypes.POINTER(ctypes.c_float),
                                     ctypes.c_uint32]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

    h = ctypes.c_void_p(dll.auradsp_create(FS, BLOCK))
    if not h:
        check(False, "auradsp_create")
        return 1

    out_buf = (ctypes.c_float * (256 * 2))()
    got0 = dll.auradsp_pcm_read(h, out_buf, 256)
    check(got0 == 0, "process 前 pcm_read 返回 0（实得 %d）" % got0)

    buf_in = (ctypes.c_float * (BLOCK * 2))()
    buf_out = (ctypes.c_float * (BLOCK * 2))()
    last_out = None
    for n in range(BLOCKS):
        for i in range(BLOCK):
            t = (n * BLOCK + i) / FS
            buf_in[i * 2] = 0.4 * math.sin(2.0 * math.pi * 440.0 * t)
            buf_in[i * 2 + 1] = 0.3 * math.sin(2.0 * math.pi * 220.0 * t)
        dll.auradsp_process(h, buf_in, buf_out, BLOCK)
        last_out = list(buf_out)

    want = 256
    got = dll.auradsp_pcm_read(h, out_buf, want)
    check(got == want, "pcm_read 返回请求帧数 %d（实得 %d）" % (want, got))
    if got == want and last_out is not None:
        tail = last_out[-want * 2:]
        max_err = 0.0
        for i in range(want * 2):
            err = abs(out_buf[i] - tail[i])
            if err > max_err:
                max_err = err
        check(max_err <= TOL,
              "pcm 尾部与 process 输出逐帧一致（max_err=%.2e）" % max_err)

    big = (ctypes.c_float * (20000 * 2))()
    got_big = dll.auradsp_pcm_read(h, big, 20000)
    check(got_big == BLOCK * BLOCKS,
          "超量请求钳制到已写入总量 %d（实得 %d）" % (BLOCK * BLOCKS, got_big))

    dll.auradsp_destroy(h)
    print("smoke_pcm_tap: %s" % ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
