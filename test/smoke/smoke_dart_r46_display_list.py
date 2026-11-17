#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第四十六轮 S1/S3：显示生效宽钳制 + APO 列表三态不变式。

S1：APO 遥测 chCount 是端点流宽，主页直认 vizChannelCount
会被流宽钉死（切声道数量不刷新、设 5.1 放 7.1 显示 7.1）。
守：流宽进显示前必过 clampStreamChForDisplay。
S3：端点列表三态（空/亮勾/暗勾/亮叉）+ 选中只以整行底
色呈现。守：_ApoTriBox 与锁定集接线在、三态调和（排队
集只存未附加者）在、「选中」文字标不再被行引用。
"""
import os
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


modes = read(os.path.join(APP, "core", "state", "state_audio_modes.dart"))
events = read(os.path.join(APP, "core", "state", "state_events.dart"))
check("display clamp function exists",
      "int clampStreamChForDisplay(int cc)" in modes)
check("stream note stores clamped width",
      "_streamCh = clampStreamChForDisplay(cc);" in modes)
check("viz write clamped at event funnel",
      "vizChannelCount.value = clampStreamChForDisplay(cc);" in events)
check("manual clamp uses capability-clamped setting",
      "clampChannelsToCapability(want, cap)" in modes)

check("tri-state lock set exists",
      "apoLockedEndpoints" in read(os.path.join(APP, "core", "state.dart")))
check("reconcile prunes checked to unattached only",
      "apoCheckedEndpoints.removeWhere(apoEndpointAttached)" in modes)
check("reconcile prunes locks to attached only",
      "apoLockedEndpoints" in modes and "removeWhere" in modes)
check("markApoLocked gated on attached",
      "void markApoLocked(String endpointId)" in modes)

sections = read(os.path.join(
    APP, "features", "settings", "panels", "sections.dart"))
check("tri-state box widget exists", "_ApoTriBox" in sections)
check("selected tag no longer rendered in rows",
      "apoEndpointSelectedTag" not in sections)
check("selected row uses background tint",
      "p.accent.withValues(alpha: 0.13)" in sections)
check("operating dims and locks the list",
      "IgnorePointer" in sections and "isApoOperating" in sections)

if failures:
    print("R46_DISPLAY_LIST FAILURES: %s" % failures)
    sys.exit(1)
print("r46_display_list: all checks passed")
