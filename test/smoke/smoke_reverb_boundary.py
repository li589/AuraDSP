#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_reverb_boundary.py — WP1 混响边界门禁（骨架，WP0 登记）。

计划断言（工程文档 §7.1）：
  - 矩阵 / 双耳路径 → vendor Progenitor2 立体声混响；
  - 离散多声道路径 → MC FDN；
  - 两套混响不得同时运行；
  - reverb.preset=-1 时两条路径都静音；
  - 延迟按路径 30ms / 0ms（含 -2 自定义在立体声路径计 30ms）。

WP0 只登记文件与门禁位；实现于 WP1。
"""
import sys

print("SKIP: WP1 尚未实现（smoke_reverb_boundary.py 骨架）")
sys.exit(0)
