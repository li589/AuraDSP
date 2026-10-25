#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_bassmono_pairs.py — WP4 BassMono 四对选择门禁（骨架，WP0 登记）。

计划断言（工程文档 §7.1）：
  - 每对独立平均；
  - merge=1 时全局平均；
  - 未选中的对直通；
  - C/LFE 对可选；
  - 4ch 下忽略不存在的对；
  - pairs / merge 越界拒绝。

WP0 只登记文件与门禁位；实现于 WP4。
"""
import sys

print("SKIP: WP4 尚未实现（smoke_bassmono_pairs.py 骨架）")
sys.exit(0)
