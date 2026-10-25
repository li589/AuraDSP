#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_vb_8x8_budget.py — VB 8×8 CPU/内存预算门禁（骨架，WP0 登记）。

计划断言（工程文档 §6.5 / §7.1）：
  - 8 个 handle，channels.count=8、channels.mode=1；
  - 开启 gate/filter/shelf/dyneq/tube/bassmono/comp/eq/loudness/limiter/reverb；
  - 8ch 粉噪、480 帧块、60s 音频；
  - 单 handle 总 CPU < 40% 单核@48k；8 handle 峰值 RSS 增量 < 150MB；
    comp 8ch < 25% 单核；
  - 反向验证：comp 改回逐对后逐声道耗时明显更高，证明测量非空转。

WP0 只登记文件与门禁位；实现于 WP3/WP8。
"""
import sys

print("SKIP: WP3 尚未实现（smoke_vb_8x8_budget.py 骨架）")
sys.exit(0)
