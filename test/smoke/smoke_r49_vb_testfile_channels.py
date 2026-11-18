#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_r49_vb_testfile_channels — 第四十九轮 S2 门禁（源码口径）。

审计背景（r48 宾机 B2 / r49 开发机 Potato 新证据）：离散
7.1 第 5 声道不显示也不输出。泵侧审计结论：ProcessGroupVm
离散 gather/scatter 经 BusChForSlot 位置恒等（仅 4 声道
Quad 档把 slot 2/3 映到总线 6/7），泵内无槽位洞；但测试
文件注入路径定罪一处真缺陷——vb_test_start kind=3 恒把
文件截断为立体声且不写 testFileCh，多声道测试文件在 VB
模式下 3..8 声道在桥门口丢失（ASIO 桥 B2c 早已全宽）。

本门禁钉住：
  1. vb_test_start 全声道存储（1..8 校验、storeCh、memcpy
     原样存、testFileCh 落值）与 ASIO 桥同语义；
  2. BusChForSlot 语义不漂移（8/6/2 恒等、4 档 Quad 映射）；
  3. 离散 gather 与 scatter 同用 BusChForSlot（两侧同表，
     不许一侧改口径另一侧漏改）。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAILS = []


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAILS.append(name)


def main():
    vm = read("core/desktop/windows-drivers/bridge/vm_bridge/VmBridge.cpp")
    pump = read("core/desktop/windows-drivers/02_voicemeeter_client/VmPumpCore.h")
    asio = read("core/desktop/windows-drivers/bridge/asio_bridge/AsioBridge.cpp")

    check("vb_test_start rejects ch outside 1..8",
          "if (ch < 1 || ch > 8) return -3;" in vm)
    check("vb_test_start stores full width (storeCh)",
          "const int storeCh = (ch <= 1) ? 2 : ch;" in vm and
          "memcpy(buf, pcm, sizeof(float) * (size_t)frames * (size_t)storeCh);" in vm)
    check("vb_test_start writes testFileCh",
          "g_b.ctx.testFileCh = storeCh;" in vm)
    check("asio parity anchor still full width",
          "const int storeCh = (ch <= 1) ? 2 : ch;" in asio and
          "g_b.tc.testFileCh = storeCh;" in asio)
    check("BusChForSlot: identity except quad slots 2/3 -> bus 6/7",
          "return (procCh == 4 && slot >= 2) ? slot + 4 : slot;" in pump)
    check("discrete gather uses BusChForSlot",
          "ab->r[base + BusChForSlot(procCh, ch)]" in pump)
    check("scatter uses BusChForSlot (same table both ways)",
          "ab->w[base + BusChForSlot(procCh, ch)]" in pump)
    check("pump FillTestSignalN honours testFileCh range",
          "(c->testFileCh >= 1 && c->testFileCh <= 8) ? c->testFileCh : 2" in pump)

    if FAILS:
        print("VB_TESTFILE FAILURES:", FAILS)
        return 1
    print("vb_testfile_channels: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
