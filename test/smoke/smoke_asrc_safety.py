#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_asrc_safety.py — Batch 1 C-01/E-01 runtime safety regression.

Each sample rate runs in a fresh subprocess so a heap overwrite or ASRC OOM
cannot take down the runner. The worker exercises the real engine ABI from
create through process to destroy, checks finite/non-silent audio, and records peak working set/commit plus wall
time. No source-string assertions are used.
"""
import argparse
import ctypes
import json
import math
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "test"))
from engine_artifact import find_engine_lib  # noqa: E402

RATES = (
    8000, 11025, 16000, 22050, 24000, 32000,
    44100, 48000, 47952, 47999, 48048,
    88200, 96000, 176400, 191808, 192000,
)
INVALID_RATES = ("nan", "inf", "8000.5", "48000.5")
BLOCK = 256
MEMORY_LIMIT_MIB = 160
WORKER_TIMEOUT_SEC = 20


def peak_working_set_bytes():
    if sys.platform.startswith("win"):
        class ProcessMemoryCounters(ctypes.Structure):
            _fields_ = [
                ("cb", ctypes.c_ulong),
                ("PageFaultCount", ctypes.c_ulong),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        counters = ProcessMemoryCounters()
        counters.cb = ctypes.sizeof(counters)
        psapi = ctypes.CDLL("psapi", use_last_error=True)
        kernel32 = ctypes.CDLL("kernel32", use_last_error=True)
        kernel32.GetCurrentProcess.argtypes = []
        kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        psapi.GetProcessMemoryInfo.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ProcessMemoryCounters),
            ctypes.c_ulong,
        ]
        psapi.GetProcessMemoryInfo.restype = ctypes.c_int
        if not psapi.GetProcessMemoryInfo(
                kernel32.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
            raise OSError(ctypes.get_last_error(), "GetProcessMemoryInfo failed")
        return max(int(counters.PeakWorkingSetSize),
                   int(counters.PeakPagefileUsage))

    import resource
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # Linux reports KiB; macOS reports bytes.
    return int(peak if sys.platform == "darwin" else peak * 1024)


def bind_abi(dll):
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.restype = None
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.restype = None
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_int,
    ]


def worker(rate):
    started = time.monotonic()
    dll = ctypes.CDLL(os.environ.get("AURADSP_ENGINE_DLL") or find_engine_lib())
    bind_abi(dll)
    handle = dll.auradsp_create(ctypes.c_float(rate), BLOCK)
    if not handle:
        raise RuntimeError("auradsp_create returned NULL")
    create_peak_bytes = peak_working_set_bytes()

    frames = max(64, int(math.ceil(rate * 0.5 / BLOCK)))
    pcm = (ctypes.c_float * (BLOCK * 2))()
    out = (ctypes.c_float * (BLOCK * 2))()
    phase_l = 0.0
    phase_r = 0.25
    step_l = 2.0 * math.pi * 997.0 / rate
    step_r = 2.0 * math.pi * 1201.0 / rate
    peak = 0.0
    finite = True
    try:
        for _ in range(frames):
            for i in range(BLOCK):
                pcm[2 * i] = 0.25 * math.sin(phase_l)
                pcm[2 * i + 1] = 0.25 * math.sin(phase_r)
                phase_l += step_l
                phase_r += step_r
            for i in range(BLOCK * 2):
                out[i] = float("nan")
            dll.auradsp_process(handle, pcm, out, BLOCK)
            for value in out:
                if not math.isfinite(value):
                    finite = False
                else:
                    peak = max(peak, abs(value))
    finally:
        dll.auradsp_destroy(handle)

    elapsed = time.monotonic() - started
    peak_bytes = peak_working_set_bytes()
    result = {
        "rate": rate,
        "frames": frames,
        "finite": finite,
        "peak": peak,
        "create_peak_mib": create_peak_bytes / (1024.0 * 1024.0),
        "elapsed_s": elapsed,
        "peak_mib": peak_bytes / (1024.0 * 1024.0),
    }
    ok = (finite and peak > 1e-4 and elapsed < WORKER_TIMEOUT_SEC
          and peak_bytes < MEMORY_LIMIT_MIB * 1024 * 1024)
    result["ok"] = ok
    print("ASRC_RESULT " + json.dumps(result, sort_keys=True), flush=True)
    return 0 if ok else 1


def invalid_rate_worker(raw_rate):
    dll = ctypes.CDLL(os.environ.get("AURADSP_ENGINE_DLL") or find_engine_lib())
    bind_abi(dll)
    rate = float(raw_rate)
    handle = dll.auradsp_create(ctypes.c_float(rate), BLOCK)
    if handle:
        dll.auradsp_destroy(handle)
        raise RuntimeError("invalid sample rate was accepted")
    print(f"ASRC_INVALID_OK rate={raw_rate}", flush=True)
    return 0


def block_one_worker():
    dll = ctypes.CDLL(os.environ.get("AURADSP_ENGINE_DLL") or find_engine_lib())
    bind_abi(dll)
    handle = dll.auradsp_create(ctypes.c_float(8000), 1)
    if not handle:
        raise RuntimeError("8k block-one create failed")
    try:
        pcm = (ctypes.c_float * 2)(0.25, 0.25)
        out = (ctypes.c_float * 2)()
        peak = 0.0
        for _ in range(4):
            dll.auradsp_process(handle, pcm, out, 1)
            for value in out:
                if not math.isfinite(value):
                    raise RuntimeError("block-one output is non-finite")
                peak = max(peak, abs(value))
        if peak <= 1e-4:
            raise RuntimeError("block-one ASRC ring produced silence")
        print("ASRC_BLOCK_ONE_OK", flush=True)
        return 0
    finally:
        dll.auradsp_destroy(handle)


def function_body(source, name):
    position = source.find(name + "(")
    if position < 0:
        return ""
    start = source.find("{", position)
    if start < 0:
        return ""
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", type=int, metavar="RATE")
    parser.add_argument("--invalid-rate", metavar="RATE")
    parser.add_argument("--block-one", action="store_true")
    args = parser.parse_args()
    if args.worker is not None:
        try:
            return worker(args.worker)
        except Exception as exc:
            print(f"ASRC_ERROR rate={args.worker}: {type(exc).__name__}: {exc}",
                  file=sys.stderr, flush=True)
            return 2
    if args.invalid_rate is not None:
        try:
            return invalid_rate_worker(args.invalid_rate)
        except Exception as exc:
            print(f"ASRC_INVALID_ERROR rate={args.invalid_rate}: "
                  f"{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            return 2
    if args.block_one:
        try:
            return block_one_worker()
        except Exception as exc:
            print(f"ASRC_BLOCK_ONE_ERROR: {type(exc).__name__}: {exc}",
                  file=sys.stderr, flush=True)
            return 2

    dll_path = os.environ.get("AURADSP_ENGINE_DLL") or find_engine_lib()
    if not os.path.isfile(dll_path):
        print(f"SKIP (engine artifact not found: {dll_path})")
        return 0

    failures = 0
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__), "--block-one"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=WORKER_TIMEOUT_SEC + 5.0,
        check=False,
    )
    if proc.returncode != 0:
        failures += 1
        print(f"FAIL block-one ASRC: rc={proc.returncode} {proc.stderr.strip()}")
    else:
        print("PASS block-one ASRC ring")

    controller = open(os.path.join(ROOT, "engine", "legacy", "jdsp",
                                   "jdspController.c"), encoding="utf-8",
                      errors="replace").read()
    prepare = function_body(controller, "jdsp_prepare_process_block")
    if "JamesDSPReallocateBlock" in prepare:
        failures += 1
        print("FAIL RT block preparation still reallocates storage")
    else:
        print("PASS RT block preparation uses fixed capacity")
    for entry in ("pint16", "pint16Multiplexed", "pint32",
                  "pint32Multiplexed", "pint8_24", "pint8_24Multiplexed",
                  "pintp24", "pintp24Multiplexed", "pfloat32",
                  "pfloat32Multiplexed", "JamesDSPProcessMultiplexedStageSet"):
        if "JamesDSPRefreshConvolutions" in function_body(controller, entry):
            failures += 1
            print(f"FAIL {entry} still rebuilds convolvers on RT block changes")
            break
    else:
        print("PASS PCM entrypoints do not rebuild convolvers on block changes")

    for rate in INVALID_RATES:
        proc = subprocess.run(
            [sys.executable, os.path.abspath(__file__), "--invalid-rate", rate],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=WORKER_TIMEOUT_SEC + 5.0,
            check=False,
        )
        if proc.returncode != 0:
            failures += 1
            print(f"FAIL invalid rate={rate}: rc={proc.returncode} "
                  f"{proc.stderr.strip()}")
        else:
            print(f"PASS invalid rate={rate}: rejected")

    for rate in RATES:
        try:
            proc = subprocess.run(
                [sys.executable, os.path.abspath(__file__), "--worker", str(rate)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=WORKER_TIMEOUT_SEC + 5.0,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failures += 1
            print(f"FAIL rate={rate}: subprocess exceeded bounded runtime")
            continue

        result = None
        for line in proc.stdout.splitlines():
            if line.startswith("ASRC_RESULT "):
                result = json.loads(line[len("ASRC_RESULT "):])
        if proc.returncode != 0 or result is None or not result.get("ok"):
            failures += 1
            detail = json.dumps(result, sort_keys=True) if result else "no result"
            stderr = proc.stderr.strip().replace("\n", " | ")
            print(f"FAIL rate={rate}: rc={proc.returncode} {detail}"
                  + (f" stderr={stderr}" if stderr else ""))
        else:
            print("PASS rate={rate}: finite_peak={peak:.6f} "
                  "elapsed={elapsed_s:.3f}s peak_mem={peak_mib:.1f}MiB".format(**result))

    if failures:
        print(f"ASRC SAFETY FAIL: {failures}/{len(RATES)} rates")
        return 1
    print(f"ASRC SAFETY PASS: {len(RATES)} rates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
