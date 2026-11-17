#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_r47_input_metering — 第四十七轮 S5 门禁。

定罪背景（r46 宾机反馈）：效果页输入卡多声道时输入电平行
不亮（或只有输出亮）。引擎侧 stage_peak_ch[12] 本有全声道
原始输入峰值，但 emit_viz 用 stage_ch_active（矩阵模式 =2，
链宽）门控所有自研级的逐声道列，把链首计量也压成两列；
stage 13（门控输出）逐声道在矩阵路径根本无人采集。

本门禁钉住修复口径：
  1. 处理入口多声道段同采 pk_out_ch 并写 stage_peak_ch[13]；
  2. emit_viz 对 stage 12/13 改用 blkCh（本块声道数）门控，
     其余级仍用 stage_ch_active；
  3. auradsp_engine.h 的有效性口径文档同步（12/13 两模式全宽）。
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
    eng = read("engine/auradsp_engine.cpp")
    viz = read("engine/chain/engine_viz.cpp")
    hdr = read("engine/auradsp_engine.h")

    check("entry stage collects per-channel gate-out peaks",
          "float pk_out_ch[AURADSP_CH_MAX] = {};" in eng and
          "h->stage_peak_ch[13][c] = pk_out_ch[c];" in eng)
    check("emit_viz widens only stages 12/13 to block width",
          "c < ((i == 12 || i == 13) ? blkCh : h->stage_ch_active)" in viz)
    check("header documents 12/13 valid in both modes",
          "12 gate 输入 / 13 gate 输出：**两模式下 [0..ch-1] 均有效**" in hdr)

    if FAILS:
        print("INPUT_METERING FAILURES:", FAILS)
        return 1
    print("input_metering: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
