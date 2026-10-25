#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_eq_freq_clamp.py — WP7 EQ 频率钳制门禁（骨架，WP0 登记）。

计划断言（工程文档 §7.1）：
  - 96k 设备率、48k 工作率下，请求 30kHz 必须被拒绝或钳制到工作域 Nyquist；
  - 不得把设备率 Nyquist 当作工作率上限。

WP0 只登记文件与门禁位；实现于 WP7。
"""
import sys

print("SKIP: WP7 尚未实现（smoke_eq_freq_clamp.py 骨架）")
sys.exit(0)
