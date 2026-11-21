# -*- coding: utf-8 -*-
"""smoke_asio_driver_params.py — ASIO 参数块跨进程契约（r61 S4/S5）。

定罪背景（2026-11-20）：DAW 进程内的 AuraDSP Driver 引擎实例
与 App 互不可见，恒跑默认参数——App 侧调参从未到达声音；App
还自开一份自家驱动空会话（假会话）显示假状态。S4 接通参数块
Global\\AuraDSP_AsioDriverParams（App 写、驱动读、seq 触发应
用）并删除假会话（虚拟形态 = isolate 控制模式、本地链停摆）。

本冒烟是纯源码契约钉：契约头常量、驱动只读打开 + seq 门 +
稳定复核 + 块缺席重试、Dart 发布者写序（seq 最后）、
channels.count 排除与 graph.order 单带、isolate 虚拟分支不
起桥会话、泵的控制模式停链门。任一处被改回去（假会话复活、
seq 门删除、写序颠倒）本冒烟必红。两平台可跑。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


SHARED = "core/desktop/windows-drivers/04_asio_driver/AsioDriverShared.h"
DRIVER = "core/desktop/windows-drivers/04_asio_driver/AuraAsioDriver.cpp"
DART_ASIO = "app/auradsp_app/lib/engine/audio_isolate_asio.dart"
DART_ISO = "app/auradsp_app/lib/engine/audio_isolate.dart"

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail and not cond else ""))
    if not cond:
        fails.append(name)


shared = read(SHARED)
driver = read(DRIVER)
dart_asio = read(DART_ASIO)
dart_iso = read(DART_ISO)

# ---- 契约头 ----
check("params block name", "AuraDSP_AsioDriverParams" in shared)
check("params magic AADP", "0x50444141" in shared)
check("params version 1", "ASIO_DRIVER_PARAMS_VERSION 1u" in shared)
check("params bytes 8192", "ASIO_DRIVER_PARAMS_BYTES 8192u" in shared)
check("payload offset 64", "ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET 64u" in shared)

# ---- 驱动消费侧 ----
check("driver opens params read-only",
      "OpenFileMappingW(FILE_MAP_READ" in driver and
      "ASIO_DRIVER_PARAMS_NAME" in driver)
check("driver seq gate", "m_lastParamSeq" in driver and
      "seq == m_lastParamSeq" in driver)
check("driver stability re-check", "m_params->seq != seq" in driver)
check("driver applies via ApplyParamsString",
      "ApplyParamsString(m_engine, snapshot" in driver)
check("driver bypass from block",
      "m_bypass.store(bypass != 0" in driver)
check("driver absent-block retry", "m_paramsRetry" in driver)
check("pump pulls params per block", "PullParamsFromBlock();" in driver)

# ---- Dart 发布者 ----
check("publisher creates mapping", "createFileMappingW" in dart_asio)
i_payload = dart_asio.find("view[_asioParamsPayloadOffset + i]")
i_seq = dart_asio.find("_i32![2] = _seq")
check("publisher writes seq last",
      0 <= i_payload < i_seq,
      f"payload@{i_payload} seq@{i_seq}")
check("publisher excludes channels.count",
      "id == 'channels.count'" in dart_asio)
check("publisher carries graph.order only",
      "_strMirror?['graph.order']" in dart_asio)
check("publisher debounced", "noteChanged" in dart_asio)

# ---- 总闸静音（r61 验收修复） ----
check("header mute field", "volatile long mute;" in shared)
check("driver reads mute", "m_params->mute" in driver and
      "m_paramsMuted = (mute != 0)" in driver)
check("driver pump zeroes when muted", "if (m_paramsMuted)" in driver)
check("publisher writes mute at i32[5]",
      "_i32![5] = (_muteOf?.call() ?? false) ? 1 : 0;" in dart_asio)
check("isolate tracks asioMuted from asiomode",
      "asioMuted = m['muted'] == true;" in dart_iso)
check("isolate un-mutes before leaving control mode",
      "asioMuted = false;" in dart_iso)

# ---- isolate 控制模式（去假会话） ----
i_virtual = dart_iso.find("if ((m['flavor'] as String?) == 'virtual')")
i_else = dart_iso.find("} else {", i_virtual)
virtual_branch = dart_iso[i_virtual:i_else] if 0 <= i_virtual < i_else else ""
check("virtual branch found", bool(virtual_branch))
check("virtual branch enters control mode",
      "asioControlMode = true" in virtual_branch and
      "asioTelemetry.start(send)" in virtual_branch)
check("virtual branch never starts bridge session",
      "startAsioBridge" not in virtual_branch)
check("virtual branch stops residual client session",
      "stopAsioBridge()" in virtual_branch)
check("pump idles local chain in control mode",
      "if (asioControlMode)" in dart_iso)
check("asiorestart degenerates to re-flush",
      "if (asioControlMode) {\n            asioPublisher.flushAll();" in dart_iso)

print("RESULT:", "FAIL " + ",".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
