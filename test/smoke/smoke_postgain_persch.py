#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_postgain_persch.py — WP5 output 逐声道门禁（骨架，WP0 登记）。

计划断言（工程文档 §7.1）：
  - 8ch 逐声道增益（post.gain.c0..c7）；
  - LFE 也按补偿衰减；
  - stereo 回归（c0/c1 与主增益同级，逐位不变）。

WP0 只登记文件与门禁位；实现于 WP5。
"""
import sys

print("SKIP: WP5 尚未实现（smoke_postgain_persch.py 骨架）")
sys.exit(0)
