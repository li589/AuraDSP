# -*- coding: utf-8 -*-
"""smoke_asio_telemetry_contract.py — ASIO 遥测块跨进程契约（r61 S3/S4/S5）。

背景：遥测块 Global\\AuraDSP_AsioDriverTelemetry 是虚拟 ASIO
形态下 DAW 侧真实例的唯一回传通道（S3 最小集：心跳/已处理
帧/峰值/汇状态；S4 升 v2 追加输出/EQ 入口频谱各 32 段；r65
升 v3 尾加逐声道峰值 peakInCh/peakOutCh 各 8）。四
个消费/生产方——契约头、驱动泵、桥 asiostatus 中转、Dart 读
者——任一处布局或版本口径漂移都会静默错位（频谱读偏、版本
误拒），真机上只表现为「图不对」而无人报错。

本冒烟是纯源码契约钉：头部版本/魔数/频谱字段/尺寸断言、驱
动 viz 频谱发布与旁路清零、loader 的 viz 绑定、桥的版本接
受域（1..当前版）与 daw* 转发、Dart 读者的字节偏移常数
（频谱 f32 索引 66/98、端点 ID u16 索引 36——与 C 结构逐字
对位）。两平台可跑。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


SHARED = "core/desktop/windows-drivers/04_asio_driver/AsioDriverShared.h"
DRIVER = "core/desktop/windows-drivers/04_asio_driver/AuraAsioDriver.cpp"
LOADER = "core/desktop/windows-drivers/04_asio_driver/AuraAsioEngineLoader.h"
BRIDGE = "core/desktop/windows-drivers/bridge/asio_bridge/AsioBridge.cpp"
DART_ASIO = "app/auradsp_app/lib/engine/audio_isolate_asio.dart"

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail and not cond else ""))
    if not cond:
        fails.append(name)


shared = read(SHARED)
driver = read(DRIVER)
loader = read(LOADER)
bridge = read(BRIDGE)
dart_asio = read(DART_ASIO)

# ---- 契约头 ----
check("telemetry name", "AuraDSP_AsioDriverTelemetry" in shared)
check("telemetry magic AADT", "0x54444141" in shared)
check("telemetry version 4", "ASIO_DRIVER_TELEMETRY_VERSION 4u" in shared)
check("spectrum fields v2",
      "spectrum[32]" in shared and "eqInSpectrum[32]" in shared)
check("per-channel peak fields v3",
      "peakInCh[8]" in shared and "peakOutCh[8]" in shared)
check("v2/v3 offsets remain pinned (static_assert)",
      "offsetof(AsioDriverTelemetryBlock, spectrum) == 264u" in shared and
      "offsetof(AsioDriverTelemetryBlock, eqInSpectrum) == 392u" in shared and
      "offsetof(AsioDriverTelemetryBlock, peakInCh) == 520u" in shared and
      "offsetof(AsioDriverTelemetryBlock, peakOutCh) == 552u" in shared)
check("v4 request token tail pinned (static_assert)",
      "offsetof(AsioDriverTelemetryBlock, requestSeq) == 584u" in shared and
      "sizeof(AsioDriverTelemetryBlock) == 592u" in shared)
check("block fits one page (static_assert)",
      "sizeof(AsioDriverTelemetryBlock) <= ASIO_DRIVER_TELEMETRY_BYTES" in shared)

# ---- 驱动生产侧 ----
check("driver publishes viz spectrum",
      "m_telemetry->spectrum, frame.spectrum" in driver and
      "m_telemetry->eqInSpectrum" in driver)
check("driver zeroes spectrum when bypassed/engineless",
      "memset(m_telemetry->spectrum, 0" in driver)
check("loader binds auradsp_viz_read optionally",
      '"auradsp_viz_read"' in loader and "FnEngVizRead" in loader)
check("driver publishes heartbeat/frames",
      "m_telemetry->heartbeat++" in driver and
      "m_telemetry->processedFrames" in driver)
check("driver publishes per-channel peaks v3",
      "m_telemetry->peakInCh" in driver and
      "m_telemetry->peakOutCh" in driver and
      "telePeakOutCh[c]" in driver)
check("driver writes telemetry version unconditionally (r65)",
      "m_telemetry->version = ASIO_DRIVER_TELEMETRY_VERSION;" in driver)
check("driver echoes init-captured channel request token",
      "m_telemetry->requestSeq = m_channelRequestSeq;" in driver)

# ---- 桥中转侧 ----
check("bridge accepts telemetry versions 1..current",
      "view->version < 1 ||" in bridge and
      "view->version > ASIO_DRIVER_TELEMETRY_VERSION" in bridge)
check("bridge forwards daw fields",
      "dawSinkEndpoint" in bridge and "dawFrames" in bridge and
      "dawActive" in bridge)

# ---- Dart 读者（偏移与 C 结构逐字对位） ----
check("reader checks magic", "_asioTelemetryMagic" in dart_asio)
check("reader spectrum offset f32[66]", "_f32![66 + i]" in dart_asio)
check("reader eqIn offset f32[98]", "_f32![98 + i]" in dart_asio)
check("reader endpoint id offset u16[36]", "u16[36 + i]" in dart_asio)
check("reader frames u64 pair", "u32[8] + u32[9] * 4294967296.0" in dart_asio)
check("reader synthesizes asio viz",
      "'backend': 'asio'" in dart_asio and "'evt': 'viz'" in dart_asio)
check("reader stale-heartbeat liveness gate", "_staleTicks <= 15" in dart_asio)
check("reader accepts versions 1..4",
      "version < 1 || version > 4" in dart_asio)
check("reader parses request token only for v4",
      "version == 4" in dart_asio and
      "'requestSeq': _u32![146]" in dart_asio)
check("reader per-channel levels from f32[138] (peakOutCh)",
      "_f32![138 + c]" in dart_asio and "dawCh >= 2 && dawCh <= 8" in dart_asio)

print("RESULT:", "FAIL " + ",".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
