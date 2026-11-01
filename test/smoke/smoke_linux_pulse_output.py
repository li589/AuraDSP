# -*- coding: utf-8 -*-
"""smoke_linux_pulse_output — PulseAudio 输出通路门禁（S3 补强，2026-11-01）。

S3 的 audio_out_linux.dart（PulseAudio simple API）当时靠 /tmp 临时
harness 验证；本门禁把同一契约固化到总控：经 ctypes 直绑 libpulse-
simple，以与 Dart 实现相同的方式（FLOAT32LE / 48000Hz / 2ch /
tlength 2048 帧）打开流，写 30 块正弦，断言：
  - pa_simple_new 成功（有 PA/PipeWire-pulse 服务在跑）
  - 写入后 get_latency 落在 (0, 2 倍缓冲] 区间（padding 口径同 Dart）
  - pa_simple_flush 后 latency 回落到接近 0（stop 真静音语义）

无音频服务（pa_simple_new 失败）或 libpulse 缺失时自 SKIP 退出 0：
开发机/CI 无声卡服务不等于产品失败；CI 的 J3 专门起 pulseaudio +
null-sink 使本门禁在流水线里实跑（见 .github/workflows/ci.yml）。
"""
import ctypes
import math
import os
import sys

FAILS = []
RATE, CHANNELS, BLOCK, BLOCKS = 48000, 2, 512, 30
BUFFER_FRAMES = 2048


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


class SampleSpec(ctypes.Structure):
    _fields_ = [("format", ctypes.c_int), ("rate", ctypes.c_uint32),
                ("channels", ctypes.c_uint8)]


class BufferAttr(ctypes.Structure):
    _fields_ = [("maxlength", ctypes.c_uint32), ("tlength", ctypes.c_uint32),
                ("prebuf", ctypes.c_uint32), ("minreq", ctypes.c_uint32),
                ("fragsize", ctypes.c_uint32)]


PA_SAMPLE_FLOAT32LE = 5
PA_STREAM_PLAYBACK = 1


def main():
    try:
        pulse = ctypes.CDLL("libpulse.so.0")
        simple = ctypes.CDLL("libpulse-simple.so.0")
    except OSError as e:
        print(f"SKIP: libpulse 不可用（{e}）")
        return 0
    simple.pa_simple_new.restype = ctypes.c_void_p
    simple.pa_simple_new.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int,
        ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(SampleSpec),
        ctypes.c_void_p, ctypes.POINTER(BufferAttr), ctypes.POINTER(ctypes.c_int)]
    simple.pa_simple_write.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                       ctypes.c_size_t,
                                       ctypes.POINTER(ctypes.c_int)]
    simple.pa_simple_get_latency.restype = ctypes.c_uint64
    simple.pa_simple_get_latency.argtypes = [ctypes.c_void_p,
                                             ctypes.POINTER(ctypes.c_int)]
    simple.pa_simple_flush.argtypes = [ctypes.c_void_p,
                                       ctypes.POINTER(ctypes.c_int)]
    simple.pa_simple_free.argtypes = [ctypes.c_void_p]
    pulse.pa_strerror.restype = ctypes.c_char_p
    pulse.pa_strerror.argtypes = [ctypes.c_int]

    spec = SampleSpec(PA_SAMPLE_FLOAT32LE, RATE, CHANNELS)
    attr = BufferAttr(0xFFFFFFFF, BUFFER_FRAMES * 4 * CHANNELS,
                      0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)
    err = ctypes.c_int(0)
    stream = simple.pa_simple_new(
        None, b"AuraDSP-smoke", PA_STREAM_PLAYBACK, None,
        b"smoke_linux_pulse_output", ctypes.byref(spec), None,
        ctypes.byref(attr), ctypes.byref(err))
    if not stream:
        msg = pulse.pa_strerror(err.value).decode(errors="replace")
        print(f"SKIP: 无 PulseAudio 服务（pa_simple_new: {msg}）")
        return 0
    try:
        frames = (ctypes.c_float * (BLOCK * CHANNELS))()
        for n in range(BLOCKS):
            for i in range(BLOCK):
                v = 0.2 * math.sin(2 * math.pi * 440 * (n * BLOCK + i) / RATE)
                frames[i * 2] = v
                frames[i * 2 + 1] = v
            rc = simple.pa_simple_write(stream, frames,
                                        ctypes.sizeof(frames),
                                        ctypes.byref(err))
            if rc < 0:
                check(False, f"pa_simple_write 第 {n} 块失败")
                break
        else:
            check(True, f"{BLOCKS} 块写入全部成功")
        lat_us = simple.pa_simple_get_latency(stream, ctypes.byref(err))
        lat_frames = lat_us * RATE // 1_000_000
        check(0 < lat_frames <= BUFFER_FRAMES * 2,
              f"写入后 latency {lat_frames} 帧 ∈ (0, {BUFFER_FRAMES * 2}]")
        simple.pa_simple_flush(stream, ctypes.byref(err))
        lat_us = simple.pa_simple_get_latency(stream, ctypes.byref(err))
        lat_frames = lat_us * RATE // 1_000_000
        check(lat_frames <= BLOCK,
              f"flush 后 latency 回落至 {lat_frames} 帧（<= {BLOCK}）")
    finally:
        simple.pa_simple_free(stream)
    print("smoke_linux_pulse_output: " + ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
