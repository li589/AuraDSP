#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四十六轮 S2：APO 生效宽决议 + 离散截断不变式（源码级）。

背景：APO 旧决议「流声道是几何真相，压过参数块
channels.count」使用户的声道数量设置在 APO 模式下从未
生效（设 5.1 放 7.1 仍全宽离散处理），且 stereo adapt
路径多余声道原样直通；VAIO 泵的 RemapInterleavedAudio
下行对全是折叠（8→6 把 BL/BR 折入 SL/SR），离散模式
下与 user 裁定（多出的声道丢弃、不映射）相悖。本冒烟
守住新口径的接线不回退。

第五十四轮补：VAIO 离散截断由顺序拷贝改为位置映射
（VaioChannelMap.h，引擎 4ch 在 7.1 流取第 7/8 声道），
本冒烟的 VAIO 段随之改守新接线；数值行为由
smoke_vaio_channel_map.py 的宿主单测守。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if (detail and not ok) else ""))
    if not ok:
        failures.append(name)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


host = read(os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "03_system_apo",
    "ApoEngineHost.cpp"))
check("APO eng resolution exists",
      "ResolveEngCh" in host and "ApplyEngChResolution" in host)
check("APO snapshot no longer skips channels.count",
      "userCh_ = values[i];" in host)
check("APO live width published atomically",
      "liveEngCh_.store" in host and "liveTrunc_.store" in host)
check("APO fold gather present for matrix mode",
      "FoldGather" in host)
chmap = read(os.path.join(ROOT, "engine", "chain", "channel_map.h"))
check("APO scatter zeroes extra channels (r55: via chmap_scatter_discrete)",
      "chmap_scatter_discrete" in host and
      "std::memset(dst, 0," in chmap)
check("APO 4ch position map present (r47 S2: quad vs C/LFE; r55 收编统一表)",
      "chmap_gather_discrete" in host and "StreamPosForCh" not in host
      and "if (streamCh == 8) return c + 4;" in chmap)
check("APO old passthrough doctrine gone",
      "压过参数块里的 channels.count" not in host and
      "其余声道先原样落 dst" not in host)
check("APO buffers sized by stream width",
      "kMaxBlock * (streamCh_ > 2 ? streamCh_ : 2)" in host)

vaio = read(os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "bridge",
    "vaio_bridge", "VaioBridge.cpp"))
vaio_map = read(os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "bridge",
    "vaio_bridge", "VaioChannelMap.h"))
check("VAIO truncate is position-mapped (r54: quad vs C/LFE)",
      "VaioTruncateGather" in vaio and "VaioTruncateScatter" in vaio
      and "TruncateRemapAudio" not in vaio)
check("VAIO 4ch position map present (r55: 统一表 + 垫片委托)",
      "if (streamCh == 8) return c + 4;" in chmap
      and "if (streamCh == 6) return c + 2;" in chmap
      and "chmap_gather_discrete" in vaio_map
      and "chmap_scatter_discrete" in vaio_map)
check("VAIO bridge records channels.mode",
      "g_vaio.chanMode" in vaio)
check("VAIO pump engine path branches on discrete",
      vaio.count("g_vaio.chanMode == 1") >= 2)

if failures:
    print("APO_ENGCH FAILURES: %s" % failures)
    sys.exit(1)
print("apo_engch_truncate: all checks passed")
