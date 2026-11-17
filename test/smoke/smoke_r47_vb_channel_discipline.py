#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_r47_vb_channel_discipline — 第四十七轮 S2 门禁。

定罪背景（r46 宾机实证 + 代码审计）：VB 泵 ProcessGroupVm 在
引擎处理前把非立体声道整组透传拷贝、scatter 只覆写 procCh
内的槽——设 5.1 时 BL/BR 原始直通，输出恒 7.1；且 gather 与
channels.mode 无关恒顺序截断，矩阵模式在引擎入口即与离散
同形（填充开关亦被透传掩盖）。本门禁钉住修复口径：

  1. PumpCtx 有 chanMode 影子，块快照与并行 cur* 发布齐备；
  2. 矩阵模式 gather 为折叠表（6/4/2 三档，系数同 APO 表）；
  3. 引擎生效路径 scatter 后未写槽一律清零（透传只属非处理
     路径）；
  4. VmBridge 两条参数路径（ApplyParamsString 实时 +
     SyncWorkChFromMirror 重建）都同步 chanMode。
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
    pump = read("core/desktop/windows-drivers/02_voicemeeter_client/VmPumpCore.h")
    bridge = read("core/desktop/windows-drivers/bridge/vm_bridge/VmBridge.cpp")

    check("PumpCtx chanMode shadow exists",
          "volatile LONG chanMode = 0;" in pump)
    check("block snapshot reads chanMode",
          "InterlockedCompareExchange(&c->chanMode, 0, 0)" in pump)
    check("parallel publish + worker snapshot carry chanMode",
          "c->curChanMode = chanMode;" in pump and
          "const long chanMode = c->curChanMode;" in pump)
    check("matrix fold gather for procCh 6/4",
          "sIn[i * 6 + 4] = b[4] + b[6] * k;" in pump and
          "sIn[i * 4 + 2] = b[6] + b[4] * k;" in pump)
    check("matrix fold gather for stereo (8->2, LFE excluded)",
          "sIn[i * 2] = inL[i] + (cc +" in pump)
    check("engine path zeroes unwritten bus slots",
          "if (!written) {" in pump and
          "memset(dst, 0, (size_t)n * sizeof(float));" in pump)
    check("bridge live path maps channels.mode to chanMode",
          'strcmp(id, "channels.mode") == 0' in bridge and
          "InterlockedExchange(&g_b.ctx.chanMode, iv == 1 ? 1 : 0);" in bridge)
    check("bridge mirror sync restores chanMode",
          'strcmp(g_mirror[i].id, "channels.mode") == 0' in bridge)

    if FAILS:
        print("VB_CHANNEL_DISCIPLINE FAILURES:", FAILS)
        return 1
    print("vb_channel_discipline: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
