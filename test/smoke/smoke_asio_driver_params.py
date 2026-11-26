# -*- coding: utf-8 -*-
"""smoke_asio_driver_params.py — ASIO 参数块跨进程契约（r61 S4/S5）。

定罪背景（2026-11-20）：DAW 进程内的 AuraDSP Driver 引擎实例
与 App 互不可见，恒跑默认参数——App 侧调参从未到达声音；App
还自开一份自家驱动空会话（假会话）显示假状态。S4 接通参数块
Global\\AuraDSP_AsioDriverParams（App 写、驱动读、seq 触发应
用）并删除假会话（虚拟形态 = isolate 控制模式、本地链停摆）。

本冒烟是纯源码契约钉：契约头常量、驱动只读打开 + 奇偶
seqlock 门（奇数=写入中不采信）+ 稳定复核 + 块缺席重试、
Dart 发布者写序（seq 先奇后偶包住载荷）、channels.count
排除与 graph.order 单带、isolate 虚拟分支不起桥会话、
泵的控制模式停链门。任一处被改回去（假会话复活、奇偶
门删除、写序颠倒）本冒烟必红。两平台可跑。
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
DART_MODES = "app/auradsp_app/lib/core/state/state_audio_modes.dart"
DART_EVENTS = "app/auradsp_app/lib/core/state/state_events.dart"

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
dart_modes = read(DART_MODES)
dart_events = read(DART_EVENTS)

# ---- 契约头 ----
check("params block name", "AuraDSP_AsioDriverParams" in shared)
check("params magic AADP", "0x50444141" in shared)
check("params version 2 (parity seqlock)",
      "ASIO_DRIVER_PARAMS_VERSION 2u" in shared)
check("params bytes 8192", "ASIO_DRIVER_PARAMS_BYTES 8192u" in shared)
check("payload offset 64", "ASIO_DRIVER_PARAMS_PAYLOAD_OFFSET 64u" in shared)
check("header writeSeq field", "volatile long writeSeq;" in shared)
check("header channel request token slot",
      "reserved1[1]" in shared and "offset 28" in shared)

# ---- 驱动消费侧 ----
check("driver opens params read-only",
      "OpenFileMappingW(FILE_MAP_READ" in driver and
      "ASIO_DRIVER_PARAMS_NAME" in driver)
check("driver seq gate", "m_lastParamSeq" in driver and
      "s1 == m_lastParamSeq" in driver)
check("driver rejects odd write window", "(s1 & 1) != 0" in driver)
check("driver stability re-check", "m_params->writeSeq != s1" in driver)
check("driver version parity guard",
      "m_params->version != ASIO_DRIVER_PARAMS_VERSION" in driver)
check("driver applies via ApplyParamsString",
      "ApplyParamsString(m_engine, snapshot" in driver)
check("driver bypass from block",
      "m_bypass.store(bypass != 0" in driver)
check("driver absent-block retry", "m_paramsRetry" in driver)
check("pump pulls params per block", "PullParamsFromBlock();" in driver)
i_init = driver.find("ASIOBool AuraAsioDriver::init")
i_load_channels = driver.find("LoadConfiguredChannels();", i_init)
i_capture_request = driver.find("CaptureChannelRequestSeq();", i_init)
i_load_engine = driver.find("m_engineLoader.Load();", i_init)
check("driver captures request token in init beside registry width",
      0 <= i_capture_request < i_load_channels < i_load_engine,
      f"capture@{i_capture_request} load@{i_load_channels} engine@{i_load_engine}")
i_start = driver.find("ASIOError AuraAsioDriver::start()")
i_stop = driver.find("ASIOError AuraAsioDriver::stop()", i_start)
start_body = driver[i_start:i_stop] if 0 <= i_start < i_stop else ""
check("same-instance start never recaptures request token",
      bool(start_body) and "CaptureChannelRequestSeq" not in start_body)
i_capture_def = driver.find("void AuraAsioDriver::CaptureChannelRequestSeq()")
i_open_params_def = driver.find("void AuraAsioDriver::OpenParams()", i_capture_def)
capture_body = driver[i_capture_def:i_open_params_def] if 0 <= i_capture_def < i_open_params_def else ""
check("init token capture reads reserved1[1]",
      "reserved1[1]" in capture_body)
check("init token capture requires stable even seqlock",
      "(s1 & 1) == 0" in capture_body and
      "writeSeq != s1" in capture_body)
i_pull = driver.find("void AuraAsioDriver::PullParamsFromBlock()")
i_publish_sink = driver.find("void AuraAsioDriver::PublishTelemetrySinkState()", i_pull)
pull_body = driver[i_pull:i_publish_sink] if 0 <= i_pull < i_publish_sink else ""
check("pump never recaptures request token",
      bool(pull_body) and "reserved1[1]" not in pull_body and
      "m_channelRequestSeq =" not in pull_body)

# ---- Dart 发布者 ----
check("publisher creates mapping", "createFileMappingW" in dart_asio)
i_odd = dart_asio.find("_seq = (_seq + 1) | 1;")
i_payload = dart_asio.find("view[_asioParamsPayloadOffset + i]")
i_token = dart_asio.find("_u32![7] = _requestSeq;")
i_even = dart_asio.find("_seq += 1;")
check("publisher brackets payload with odd/even seq",
      0 <= i_odd < i_payload < i_even,
      f"odd@{i_odd} payload@{i_payload} even@{i_even}")
check("publisher writes request token inside odd/even seq",
      0 <= i_odd < i_token < i_even,
      f"odd@{i_odd} token@{i_token} even@{i_even}")
check("publisher carries channels.count (W6 width authority)",
      "if (id == 'channels.count') continue;" not in dart_asio)
check("publisher carries graph.order only",
      "_strMirror?['graph.order']" in dart_asio)
check("publisher debounced", "noteChanged" in dart_asio)

# ---- W6 流宽/引擎宽解耦 与 W7 端点热切换（2026-11-24）----
check("driver keeps engine-width shadow", "m_engineCh" in driver)
check("driver keeps channel-mode shadow", "m_channelMode" in driver)
check("driver adapts width via chmap",
      "chmap_gather_discrete" in driver and
      "chmap_scatter_discrete" in driver and "chmap_fold(" in driver)
check("driver no longer pins count to stream width",
      "int nCh = (int)m_channels;\n    m_engineLoader.SetParam" not in driver)
check("driver telemetry in engine order",
      "chmap_stream_pos(engCh, (int)ch, c)" in driver)
check("header endpoint seq slot documented", "reserved1[0]" in shared)
check("publisher bumps endpoint seq", "bumpEndpointSeq" in dart_asio)
check("isolate routes endpoint seq command",
      "case 'asioendpointseq'" in dart_iso)
check("isolate routes channel request token command",
      "case 'asioRequestSeq'" in dart_iso and
      "asioPublisher.setRequestSeq" in dart_iso)
check("AppModel exposes pending-token replay for a fresh isolate",
      "void _replayAsioVirtualChannelRequest()" in dart_modes and
      "_pendingAsioVirtualRequestCh" in dart_modes)
i_iso_ready = dart_events.find("case 'isoReady':")
i_ready = dart_events.find("case 'ready':", i_iso_ready)
iso_ready_body = dart_events[i_iso_ready:i_ready]
i_replay = iso_ready_body.find("_replayAsioVirtualChannelRequest();")
i_port = iso_ready_body.find("_toIso = raw['port'] as SendPort;")
check("isoReady replays pending token after binding the new port",
      0 <= i_port < i_replay,
      f"port@{i_port} replay@{i_replay}")

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
