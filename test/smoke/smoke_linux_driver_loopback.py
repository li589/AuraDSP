#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_linux_driver_loopback — Linux driver 模式的平台机制门禁（S5a）。

验证 ADR-012 D-5 driver 模式依赖的 snd-aloop 回环链路本身：
向 PA 侧的回环 sink 注入正弦，从**同名 sink 的 monitor 源**采集，
断言能采到信号。App 侧的 pa_context 源选择与 pa_simple 采集由
Dart 单测/E2E 覆盖；本门禁守的是「内核 snd-aloop + 当前 PA 服务」
这一层在真机上成立。

2026-11-02 实机实测（Ubuntu 24.04 + PipeWire）：
  play[alsa_output.platform-snd_aloop.0.analog-stereo]
    -> rec[同名 .monitor]  rms=0.203
    -> rec[alsa_input.platform-snd_aloop.0...]  rms=0.000
故 driver 模式必须优先选回环 sink 的 `.monitor`，不能选 alsa_input。
`snd-aloop` 用 `index=2 enable=1` 只建一张回环卡；`enable=1,1` 会建
两张，PA 枚举顺序与 index=2 不一致，会引入源/汇错配（见 l10n 与
ADR-012 的修订注）。

环境：需已加载 snd-aloop 且 PA/PipeWire 已暴露回环设备。缺 pactl、
服务不可用、/proc/asound/cards 无 Loopback 或无回环 sink 时自 SKIP
（exit 0）。不加载/卸载模块，不污染默认设备。
"""
import ctypes
import math
import shutil
import struct
import subprocess
import sys

RATE = 48000
BLOCK = 1024
SECONDS = 0.6
RMS_MIN = 0.03


def skip(msg):
    print(f"SKIP smoke_linux_driver_loopback: {msg}")
    sys.exit(0)


def pactl(*args):
    return subprocess.run(["pactl"] + list(args), capture_output=True,
                          text=True, timeout=15)


def device_names(kind):
    out = []
    for line in pactl("list", "short", kind).stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            out.append(parts[1])
    return out


def is_loopback(name):
    n = name.lower()
    return "loopback" in n or "snd_aloop" in n


def main():
    if shutil.which("pactl") is None:
        skip("pactl not available")
    if pactl("info").returncode != 0:
        skip("PulseAudio server not reachable")
    try:
        with open("/proc/asound/cards", "r", encoding="utf-8") as f:
            if "Loopback" not in f.read():
                skip("snd-aloop not loaded (/proc/asound/cards has no Loopback)")
    except OSError as e:
        skip(f"cannot read /proc/asound/cards: {e}")

    sinks = [n for n in device_names("sinks") if is_loopback(n)]
    sources = [n for n in device_names("sources") if is_loopback(n)]
    if not sinks:
        skip("no snd-aloop sink exposed by PulseAudio")
    # 与 App 的选择规则一致：优先同名 sink 的 monitor（实测唯一可采集侧）。
    pair = None
    for sink in sinks:
        mon = sink + ".monitor"
        if mon in sources:
            pair = (sink, mon)
            break
    if pair is None:
        print(f"FAIL: no loopback sink monitor in sources {sources}")
        return 1
    sink, source = pair

    lib = ctypes.CDLL("libpulse-simple.so.0")

    class Spec(ctypes.Structure):
        _fields_ = [("format", ctypes.c_int32), ("rate", ctypes.c_uint32),
                    ("channels", ctypes.c_uint8)]

    class Attr(ctypes.Structure):
        _fields_ = [(n, ctypes.c_uint32) for n in
                    ("maxlength", "tlength", "prebuf", "minreq", "fragsize")]

    lib.pa_simple_new.restype = ctypes.c_void_p
    spec = Spec(5, RATE, 2)  # FLOAT32LE
    all_max = 0xFFFFFFFF
    err = ctypes.c_int(0)

    play = lib.pa_simple_new(None, b"gate-driver", 1, sink.encode(),
                             b"driver tone", ctypes.byref(spec), None,
                             ctypes.byref(Attr(all_max, 2048 * 8, all_max,
                                               all_max, all_max)),
                             ctypes.byref(err))
    if not play:
        print(f"FAIL: pa_simple_new(playback {sink}) err={err.value}")
        return 1
    rec = lib.pa_simple_new(None, b"gate-driver", 2, source.encode(),
                            b"driver capture", ctypes.byref(spec), None,
                            ctypes.byref(Attr(all_max, all_max, all_max,
                                              all_max, 512 * 8)),
                            ctypes.byref(err))
    if not rec:
        print(f"FAIL: pa_simple_new(record {source}) err={err.value}")
        lib.pa_simple_free(play)
        return 1

    frames_total = int(RATE * SECONDS)
    buf = ctypes.create_string_buffer(BLOCK * 8)
    captured = []
    phase = 0.0
    sent = got = 0
    try:
        while got < frames_total:
            if sent < frames_total:
                out = []
                for _ in range(BLOCK):
                    v = math.sin(phase) * 0.3
                    phase += 2 * math.pi * 440.0 / RATE
                    out += [v, v]
                data = struct.pack(f"<{len(out)}f", *out)
                rc = lib.pa_simple_write(play, data, len(data),
                                         ctypes.byref(err))
                if rc < 0:
                    print(f"FAIL: pa_simple_write err={err.value}")
                    return 1
                sent += BLOCK
            rc = lib.pa_simple_read(rec, buf, BLOCK * 8, ctypes.byref(err))
            if rc < 0:
                print(f"FAIL: pa_simple_read err={err.value}")
                return 1
            captured.extend(struct.unpack(f"<{BLOCK * 2}f", buf.raw))
            got += BLOCK
    finally:
        lib.pa_simple_free(play)
        lib.pa_simple_free(rec)

    if not captured:
        print("FAIL: captured nothing from loopback monitor")
        return 1
    rms = math.sqrt(sum(v * v for v in captured) / len(captured))
    print(f"loopback [{sink}] -> [{source}] "
          f"frames={len(captured) // 2} rms={rms:.4f}")
    if rms <= RMS_MIN:
        print(f"FAIL: loopback RMS too low ({rms:.4f}); snd-aloop route "
              "did not reach the monitor source")
        return 1
    print(f"PASS smoke_linux_driver_loopback (rms={rms:.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
