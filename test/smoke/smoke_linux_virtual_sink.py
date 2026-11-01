#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_linux_virtual_sink —— Linux virtual 模式的平台机制门禁（S5a）。

验证 ADR-012 D-5 virtual 模式依赖的 PulseAudio 机制本身：
null-sink 虚拟设备可加载、其 monitor 源可被 pa_simple 采集、且能采到
注入 sink 的信号。App 侧的 pa_context 加载路径（pulse_context.dart）
与采集路径（audio_in_linux.dart）由 Dart 侧 E2E 验证覆盖，本门禁守的
是「平台机制在当前 PA 服务上成立」这一层。

环境：需要 PulseAudio 服务在跑（CI J3 已起服务 + auradsp_ci sink；
本地需 XDG_RUNTIME_DIR 指向已启动服务的 runtime 目录）。
缺 pactl 或服务不可用 → 自 SKIP（exit 0 并打印 SKIP）。不污染环境：
加载的模块在结束时卸载，注入的信号只进本门禁自建的 sink。

判据：向 auradsp_gate_virtual sink 注入 440Hz 正弦 0.6s，同时从其
monitor 源采集，均方根 > 0.03（注入幅度 0.3，monitor 为直通）。
"""
import ctypes
import math
import shutil
import struct
import subprocess
import sys
import time

SINK = "auradsp_gate_virtual"
MONITOR = SINK + ".monitor"
RATE = 48000


def skip(msg):
    print(f"SKIP smoke_linux_virtual_sink: {msg}")
    sys.exit(0)


def pactl(*args):
    return subprocess.run(["pactl"] + list(args), capture_output=True,
                          text=True, timeout=15)


def main():
    if shutil.which("pactl") is None:
        skip("pactl not available")
    if pactl("info").returncode != 0:
        skip("PulseAudio server not reachable")

    loaded_idx = None
    if SINK not in pactl("list", "short", "sinks").stdout:
        r = pactl("load-module", "module-null-sink", f"sink_name={SINK}")
        if r.returncode != 0:
            print(f"FAIL: load-module null-sink: {r.stderr.strip()}")
            return 1
        loaded_idx = r.stdout.strip()

    try:
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

        play_attr = Attr(all_max, 2048 * 8, all_max, all_max, all_max)
        play = lib.pa_simple_new(None, b"gate-producer", 1,
                                 SINK.encode(), b"gate tone",
                                 ctypes.byref(spec), None,
                                 ctypes.byref(play_attr), ctypes.byref(err))
        if not play:
            print(f"FAIL: pa_simple_new(playback) err={err.value}")
            return 1

        rec_attr = Attr(all_max, all_max, all_max, all_max, 512 * 8)
        rec = lib.pa_simple_new(None, b"gate-capture", 2,
                                MONITOR.encode(), b"gate capture",
                                ctypes.byref(spec), None,
                                ctypes.byref(rec_attr), ctypes.byref(err))
        if not rec:
            print(f"FAIL: pa_simple_new(record {MONITOR}) err={err.value}")
            return 1

        block = 1024
        frames_total = int(RATE * 0.6)
        captured = []
        phase = 0.0

        def produce(n):
            nonlocal phase
            out = []
            for _ in range(n):
                v = math.sin(phase) * 0.3
                phase += 2 * math.pi * 440.0 / RATE
                out += [v, v]
            return struct.pack(f"<{len(out)}f", *out)

        # 先注一段，再边注边采（monitor 是实时流，采集滞后于注入）。
        buf = ctypes.create_string_buffer(block * 8)
        sent = 0
        got = 0
        while got < frames_total:
            if sent < frames_total:
                data = produce(block)
                rc = lib.pa_simple_write(play, data, len(data),
                                         ctypes.byref(err))
                if rc < 0:
                    print(f"FAIL: pa_simple_write err={err.value}")
                    return 1
                sent += block
            rc = lib.pa_simple_read(rec, buf, block * 8, ctypes.byref(err))
            if rc < 0:
                print(f"FAIL: pa_simple_read err={err.value}")
                return 1
            captured.extend(struct.unpack(f"<{block * 2}f", buf.raw))
            got += block

        lib.pa_simple_free(play)
        lib.pa_simple_free(rec)

        if not captured:
            print("FAIL: captured nothing from monitor source")
            return 1
        rms = math.sqrt(sum(v * v for v in captured) / len(captured))
        print(f"monitor capture: frames={len(captured) // 2} rms={rms:.4f}")
        if rms <= 0.03:
            print(f"FAIL: monitor RMS too low ({rms:.4f}); injected tone "
                  "did not reach the monitor source")
            return 1
        print(f"PASS smoke_linux_virtual_sink (rms={rms:.3f})")
        return 0
    finally:
        if loaded_idx:
            pactl("unload-module", loaded_idx)
        # 兜底：按名再查一次并卸载本门禁可能残留的模块实例。
        mods = pactl("list", "short", "modules").stdout
        for line in mods.splitlines():
            if SINK in line:
                pactl("unload-module", line.split()[0])


if __name__ == "__main__":
    sys.exit(main())
