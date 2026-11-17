#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四十五轮：声道能力权威不变式（源码级）。

背景：r44 S1 把桥 viz 流几何喂进 isolate 钳制器，形成只能降
不能升的棘轮死锁（宾机实证 VAIO 切 7.1 回 2.0、5.1 后回不
去 7.1）。r45 收敛后能力只认设备事实三路：状态侧分模式计
算（chcap）/ 本地泵 devCh / ASIO 预置。本冒烟守住：

  1. isolate 桥 viz 消费段不再出现 updateCapabilityCh 调用；
  2. 状态侧存在 _capabilityChForMode 且覆盖 sysapo /
     vbcallback / capture-min / vaio 链四分支；
  3. VB 协商面接线齐：VmPumpCore 回调记录 negNbo、VmBridge
     status 输出 negNbo、状态侧 vbstatus 消费 vbNegotiatedCh；
  4. VAIO 泵 kind3 注入按 inCh（min{文件， 引擎}）贯穿，
     不再以 ringChannels 填 kind3；
  5. 桥文件注入走 fold:false 的 raw 探针路径（全桥）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
APP = os.path.join(ROOT, "app", "auradsp_app", "lib")
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (("  " + detail) if (detail and not ok) else ""))
    if not ok:
        failures.append(name)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


iso = read(os.path.join(APP, "engine", "audio_isolate.dart"))
# 1. viz 消费段（brc.vizRead 前后窗口）无能力喂入
viz_idx = iso.find("brc.vizRead()")
window = iso[viz_idx:viz_idx + 1600] if viz_idx >= 0 else ""
check("bridge viz no longer feeds capability clamp",
      viz_idx >= 0 and "updateCapabilityCh" not in window)
# isolate 侧能力入口仍在（chcap 命令 + ASIO 预置）
check("isolate chcap command retained", "'chcap'" in iso or '"chcap"' in iso)
check("isolate ASIO capability pre-seed retained",
      "updateCapabilityCh(asioCh)" in iso)

modes = read(os.path.join(APP, "core", "state", "state_audio_modes.dart"))
check("state capability authority exists", "_capabilityChForMode" in modes)
check("capability covers sysapo endpoint", "_selectedApoEndpointCh()" in modes)
check("capability covers vb negotiated", "vbNegotiatedCh" in modes)
check("capability covers capture chain min",
      "PipelineChain.capture" in modes)
check("capability covers vaio chain output cap",
      "PipelineChain.vaio" in modes and "vaioOutputEndpoint" in modes)
check("display clamp delegates to same authority",
      "_displayCapCh() => _capabilityChForMode()" in modes)

pump = read(os.path.join(
    ROOT, "core", "desktop", "windows-drivers",
    "02_voicemeeter_client", "VmPumpCore.h"))
check("VB callback records negotiated nbo",
      "negNbo" in pump and "InterlockedExchange(&c->negNbo" in pump)
vmb = read(os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "bridge",
    "vm_bridge", "VmBridge.cpp"))
check("VB status exposes negNbo", '\\"negNbo\\"' in vmb)
events = read(os.path.join(APP, "core", "state", "state_events.dart"))
check("state consumes VB negotiation from vbstatus",
      "vbNegotiatedCh" in events and "negNbo" in events)

vaio = read(os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "bridge",
    "vaio_bridge", "VaioBridge.cpp"))
check("VAIO kind3 injection widened to engine width",
      "injCh" in vaio and "testFileCh" in vaio)
check("VAIO downstream remap uses inCh",
      "RemapInterleavedAudio(g_vaio.scratchIn, inCh," in vaio)
check("bridge file injection probes raw for all bridges",
      "decodeWavFile(fpath, fold: false)" in iso)

if failures:
    print("CHCAP AUTHORITY FAILURES: %s" % failures)
    sys.exit(1)
print("chcap_authority: all checks passed")
