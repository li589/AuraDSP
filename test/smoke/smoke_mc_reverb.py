#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_mc_reverb.py — WP1 离散多声道 FDN 混响门禁（骨架，WP0 登记）。

计划断言（工程文档 §7.1）：
  - 8ch 尾音去相关（各声道 wet 不完全相同）；
  - LFE 默认直通；
  - reverb.lfe=1 时 LFE 有湿声，且湿声能量集中在 120Hz 以下；
  - 切换 preset 无爆音；RMS 不爆炸。

WP0 只登记文件与门禁位；实现于 WP1。
"""
import sys

print("SKIP: WP1 尚未实现（smoke_mc_reverb.py 骨架）")
sys.exit(0)
