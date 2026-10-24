#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""viz_frame.py — `auradsp_viz_frame` 的**唯一** Python ctypes 镜像（§7-1）。

为什么要有这个文件
------------------
改造前 `tools/` 与 `test/` 下**各有 8 份彼此独立的 VizFrame 定义**（
`tools/bin/verify_dll_copies.py`、`tools/probe/probe_viz_cost.py` 和 6 个
`test/smoke/*.py`）。它们是同一个 C 结构的 8 份手抄件，靠人肉同步。

审查 A1/A2/A3 三处缓冲越界全部来自这条通道：改了 `auradsp_engine.h` 的
`sizeof`（536B → 1600B）后，漏改某一个脚本的镜像，那个脚本就按旧尺寸
申请缓冲、引擎按新尺寸写——**堆越界**，而且是静默的（Python 不检查）。

修法分两层，缺一不可：
  1. **单源**：所有 Python 侧一律 `from viz_frame import VizFrame`，
     全仓不允许出现第二份定义（`abi_consistency.py` 的 M1 检查强制）。
  2. **逐字段对齐**：光有 `sizeof == 1600` 不够——字段顺序错了但总长凑巧相同
     仍然会读到错位数据。`abi_consistency.py` 的 M2 会解析
     `engine/auradsp_engine.h` 的结构体定义，用 ctypes 重建期望布局，
     与这里的 `_fields_` 逐字段比对 **名称 / 偏移 / 尺寸**。

尺寸链（改任何一处都必须同步四处）
----------------------------------
    engine/auradsp_engine.h  auradsp_viz_frame + typedef 哨兵
      → 本文件 VIZ_FRAME_SIZE / _fields_
      → app/auradsp_app/lib/engine/auradsp_ffi.dart  VizFrame
      → app/auradsp_app/test/mc_channel_levels_test.dart  sizeOf 断言
"""
import ctypes

# ABI 版本。与 engine/engine_internal.h 的 AURADSP_ABI 同源；
# 尺寸变化必须同时升版本（Dart 侧加载时强校验，不匹配即明确失败）。
AURADSP_ABI = 2

# 帧字节数。536 = v1；1600 = v2（536 + 4 channel_count + 32 channel_levels
# + 1024 stage_ch_levels + 4 尾填充）。尾填充存在是因为结构含 uint64/double，
# sizeof 必须是 8 的倍数。
VIZ_FRAME_SIZE = 1600


class VizFrame(ctypes.Structure):
    """逐字节对应 `auradsp_engine.h` 的 `auradsp_viz_frame`。

    字段名与 C 侧完全一致（含下划线风格），这样 `abi_consistency.py` 的 M2
    可以按名字比对偏移，不必维护第二张映射表——映射表本身又是一处会漂的手抄件。
    """

    _fields_ = [
        ("seq", ctypes.c_uint64),
        ("timestamp_ms", ctypes.c_double),
        ("spectrum", ctypes.c_float * 32),
        # [EQ tap] vendor 链入口（均衡器输入）谱。与 spectrum 同规格、同语义。
        ("eq_in_spectrum", ctypes.c_float * 32),
        ("level_l_dbfs", ctypes.c_float),
        ("level_r_dbfs", ctypes.c_float),
        # 21 个 stage 的 per-stage 峰值（0..11 vendor 链，12..20 各效果器，21..31 预留）
        ("stage_levels_l", ctypes.c_float * 32),
        ("stage_levels_r", ctypes.c_float * 32),
        # [Phase B 多声道电平 / ADR-003] ABI 1→2 的追加段。前 536B 零变化。
        ("channel_count", ctypes.c_uint32),
        ("channel_levels", ctypes.c_float * 8),
        # stage-major：[stage][ch]，物理长度 32*8
        ("stage_ch_levels", ctypes.c_float * (32 * 8)),
    ]


# 尺寸哨兵：导入即校验。真出错时这里抛 AssertionError，比在某个脚本里
# 堆越界后再回来找要早得多。
assert ctypes.sizeof(VizFrame) == VIZ_FRAME_SIZE, (
    "VizFrame 与 auradsp_viz_frame 不同步：期望 %d 字节，实际 %d"
    % (VIZ_FRAME_SIZE, ctypes.sizeof(VizFrame))
)

# 命名偏移表：给需要按名字取偏移的脚本用（如桥/探针对 1600 字节裸缓冲的手工
# 寻址）。硬编码魔数（12 / 272 / 536）是 A3 那类错偏移的温床。
FIELD_OFFSETS = {name: getattr(VizFrame, name).offset for name, _ in VizFrame._fields_}


def new_frame() -> VizFrame:
    """分配一个已清零的帧（等价于 C 侧 `auradsp_viz_frame f = {0};`）。"""
    return VizFrame()
