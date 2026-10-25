#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_mc_eq_persch.py — WP3 EQ 逐声道门禁（骨架，WP0 登记）。

计划断言（工程文档 §7.1）：
  - 8ch 每声道独立 EQ；
  - 单声道 mask 生效；
  - 96k 设备率下 IR 不偏移；
  - 8 个 FFTConvolver1x1 实例的卷积 FIFO 不串。

WP0 只登记文件与门禁位；实现于 WP3。
"""
import sys

print("SKIP: WP3 尚未实现（smoke_mc_eq_persch.py 骨架）")
sys.exit(0)
