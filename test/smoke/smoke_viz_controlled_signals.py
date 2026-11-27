# -*- coding: utf-8 -*-
"""Task 19: controlled PCM through the real native viz FFT/band path.

No audio device, driver, or service is used. Prints the last and mean 32-band
raw sequences so UI-side AGC/post investigations have an inspectable baseline.
"""
import ctypes
import math
import os
import random
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
sys.path.insert(0, TEST_DIR)
sys.path.insert(0, os.path.join(ROOT, "tools", "bin"))

from engine_artifact import find_engine_lib  # noqa: E402
from viz_frame import VizFrame  # noqa: E402

SAMPLE_RATE = 48000.0
BLOCK = 240
BLOCKS = 400
BANDS = 32


def fmt(values):
    return "[" + ", ".join("%.4f" % v for v in values) + "]"


def mean_bands(frames):
    return [sum(frame[i] for frame in frames) / len(frames) for i in range(BANDS)]


def extreme_isolated_spikes(frames):
    """A spike with no local spectral support is suspicious even for noise."""
    found = []
    for frame_no, frame in enumerate(frames):
        for i in range(1, BANDS - 1):
            local = max(frame[i - 1], frame[i + 1])
            if frame[i] > 0.90 and local < 0.20:
                found.append((frame_no, i, frame[i], local))
    return found


def run_signal(dll, kind):
    h = dll.auradsp_create(SAMPLE_RATE, BLOCK)
    if not h:
        raise AssertionError("auradsp_create returned null")
    source = (ctypes.c_float * (BLOCK * 2))()
    dest = (ctypes.c_float * (BLOCK * 2))()
    viz = (VizFrame * 64)()
    rng = random.Random(19013)
    phase = 0.0
    pink = [0.0] * 7
    result = []
    try:
        for _ in range(BLOCKS):
            for n in range(BLOCK):
                if kind == "silence":
                    sample = 0.0
                elif kind == "tone10k":
                    sample = 0.3 * math.sin(phase)
                    phase += 2.0 * math.pi * 10000.0 / SAMPLE_RATE
                else:
                    white = rng.uniform(-1.0, 1.0)
                    if kind == "white":
                        sample = 0.3 * white
                    elif kind == "pink":
                        # Paul Kellet's deterministic pink-noise filter.
                        pink[0] = 0.99886 * pink[0] + white * 0.0555179
                        pink[1] = 0.99332 * pink[1] + white * 0.0750759
                        pink[2] = 0.96900 * pink[2] + white * 0.1538520
                        pink[3] = 0.86650 * pink[3] + white * 0.3104856
                        pink[4] = 0.55000 * pink[4] + white * 0.5329522
                        pink[5] = -0.7616 * pink[5] - white * 0.0168980
                        sample = (sum(pink) + white * 0.5362) * 0.11
                        pink[6] = white * 0.115926
                    else:
                        raise ValueError(kind)
                source[2 * n] = sample
                source[2 * n + 1] = sample
            dll.auradsp_process(h, source, dest, BLOCK)
            count = dll.auradsp_viz_read(h, viz, 64)
            for i in range(count):
                result.append(list(viz[i].spectrum))
    finally:
        dll.auradsp_destroy(h)
    if len(result) < 30:
        raise AssertionError("%s produced only %d viz frames" % (kind, len(result)))
    return result


def main():
    lib_path = find_engine_lib()
    if not os.path.isfile(lib_path):
        print("SKIP: native engine artifact not found: %s" % lib_path)
        return 0

    dll = ctypes.CDLL(lib_path)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.restype = None
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_int,
    ]
    dll.auradsp_viz_read.restype = ctypes.c_uint32
    dll.auradsp_viz_read.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(VizFrame),
        ctypes.c_uint32,
    ]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

    failures = []
    captures = {}
    for kind in ("silence", "tone10k", "white", "pink"):
        frames = run_signal(dll, kind)
        captures[kind] = frames
        last = frames[-1]
        mean = mean_bands(frames[-30:])
        print("%s raw last=%s" % (kind, fmt(last)))
        print("%s raw mean30=%s" % (kind, fmt(mean)))

        if kind == "silence":
            if any(value != 0.0 for frame in frames for value in frame):
                failures.append("silence produced non-zero raw bands")
        elif kind == "tone10k":
            peak = max(range(BANDS), key=lambda i: last[i])
            # 10 kHz lies exactly on the 27/28 edge (8400-10000 / 10000-11900).
            # FFT bin centers and Hann leakage may legitimately light both.
            if peak not in (27, 28):
                failures.append("10 kHz peak landed in band %d" % peak)
            active = {i for i, value in enumerate(last) if value > 0.05}
            if not active.issubset({26, 27, 28, 29}):
                failures.append("10 kHz has non-local bands: %s" % sorted(active))
        else:
            spikes = extreme_isolated_spikes(frames[-30:])
            if spikes:
                failures.append("%s isolated raw spikes: %s" % (kind, spikes[:4]))

    if failures:
        for failure in failures:
            print("FAIL:", failure)
        return 1
    print("PASS: silence=0; 10 kHz local to bands 27/28; white/pink have no unsupported isolated raw spike")
    return 0


if __name__ == "__main__":
    sys.exit(main())
