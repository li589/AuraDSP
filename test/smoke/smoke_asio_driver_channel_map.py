# -*- coding: utf-8 -*-
"""Task 16: virtual-ASIO and WASAPI channel-layout regression.

No DAW, audio device, driver installation, or registry mutation is used.  The
native fixture exercises engine/chain/channel_map.h directly, source checks pin
the ASIO pump's complete active-geometry dispatch, and the engine DLL checks
cover matrix/discrete x upmix_fill plus the shared remap used by the WASAPI
manual pump.
"""
import ctypes
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DRIVER = os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "04_asio_driver",
    "AuraAsioDriver.cpp")
ISOLATE = os.path.join(
    ROOT, "app", "auradsp_app", "lib", "engine", "audio_isolate.dart")
ENGINE_DLL = os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (("  " + detail) if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


NATIVE = r'''
#include <cmath>
#include <cstdio>
#include <cstring>
#include "chain/channel_map.h"

static int failures = 0;
static void check(const char* name, bool ok) {
    std::printf("%s  %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) ++failures;
}
static bool near(float a, float b) { return std::fabs(a - b) < 1e-6f; }
static bool frame_near(const float* got, const float* want, int n) {
    for (int i = 0; i < n; ++i) if (!near(got[i], want[i])) return false;
    return true;
}

int main() {
    const float k = kChmapFoldK;
    const float s8[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    float d[8] = {};

    chmap_fold(s8, 8, d, 2, 1);
    const float m2[2] = {1 + (3 + 5 + 7) * k, 2 + (3 + 6 + 8) * k};
    check("VM-01 matrix 8->2 folds C/surrounds, excludes LFE", frame_near(d, m2, 2));

    chmap_fold(s8, 8, d, 4, 1);
    const float m4[4] = {1 + 3 * k, 2 + 3 * k, 7 + 5 * k, 8 + 6 * k};
    check("VM-02 matrix 8->4 keeps C out of BL/BR", frame_near(d, m4, 4));

    chmap_fold(s8, 8, d, 6, 1);
    const float m6[6] = {1, 2, 3, 4, 5 + 7 * k, 6 + 8 * k};
    check("VM-03 matrix 8->6 folds BL/BR into SL/SR", frame_near(d, m6, 6));

    chmap_fold(s8, 8, d, 8, 1);
    check("matrix 8->8 identity", frame_near(d, s8, 8));

    chmap_gather_discrete(s8, 8, d, 2, 1);
    const float d2[2] = {1, 2};
    check("discrete gather 8->2 slot identity", frame_near(d, d2, 2));
    chmap_gather_discrete(s8, 8, d, 4, 1);
    const float d4[4] = {1, 2, 7, 8};
    check("discrete gather 8->4 slot identity", frame_near(d, d4, 4));
    chmap_gather_discrete(s8, 8, d, 6, 1);
    check("discrete gather 8->6 slot identity", frame_near(d, s8, 6));
    chmap_gather_discrete(s8, 8, d, 8, 1);
    check("discrete gather 8->8 slot identity", frame_near(d, s8, 8));

    const float e4[4] = {1, 2, 7, 8};
    chmap_scatter_discrete(e4, 4, d, 8, 1);
    const float x4[8] = {1, 2, 0, 0, 0, 0, 7, 8};
    check("discrete scatter 4->8 targets BL/BR slots", frame_near(d, x4, 8));
    const float e2[2] = {1, 2};
    chmap_scatter_discrete(e2, 2, d, 6, 1);
    const float x2[6] = {1, 2, 0, 0, 0, 0};
    check("matrix/discrete expansion uses stream-pos targets", frame_near(d, x2, 6));

    std::printf(failures ? "NATIVE CHANNEL MAP FAILURES: %d\n" : "NATIVE CHANNEL MAP ALL PASS\n", failures);
    return failures ? 1 : 0;
}
'''


def run_native_map():
    cxx = shutil.which("g++") or shutil.which("clang++") or shutil.which("c++")
    check("native C++ compiler available", cxx is not None)
    if not cxx:
        return
    with tempfile.TemporaryDirectory(prefix="auradsp_task16_map_") as td:
        src = os.path.join(td, "channel_map_regression.cpp")
        exe = os.path.join(td, "channel_map_regression.exe")
        with open(src, "w", encoding="utf-8", newline="\n") as f:
            f.write(NATIVE)
        build = subprocess.run(
            [cxx, "-std=c++17", "-I", os.path.join(ROOT, "engine"), src,
             "-o", exe], capture_output=True, text=True, timeout=120)
        if build.stdout:
            sys.stdout.write(build.stdout)
        if build.stderr:
            sys.stderr.write(build.stderr)
        check("native channel-map fixture compiles", build.returncode == 0,
              f"rc={build.returncode}")
        if build.returncode != 0:
            return
        run = subprocess.run([exe], capture_output=True, text=True, timeout=60)
        sys.stdout.write(run.stdout)
        if run.stderr:
            sys.stderr.write(run.stderr)
        check("native channel-map fixture rc=0", run.returncode == 0,
              f"rc={run.returncode}")


def engine_fixtures():
    if not os.path.isfile(ENGINE_DLL):
        check("engine DLL present", False, ENGINE_DLL)
        return
    lib = ctypes.WinDLL(ENGINE_DLL)
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    lib.auradsp_set_param.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
    lib.auradsp_set_param.restype = ctypes.c_int

    def set_int(handle, name, value):
        v = ctypes.c_int32(value)
        return lib.auradsp_set_param(
            handle, name.encode("ascii"), ctypes.byref(v), 4)

    def process(mode, fill):
        h = lib.auradsp_create(48000.0, 64)
        try:
            for name, value in (("channels.count", 8),
                                ("channels.mode", mode),
                                ("channels.upmix_fill", fill),
                                ("limiter.enable", 0)):
                if set_int(h, name, value) != 0:
                    raise RuntimeError("set_param failed: " + name)
            src = (ctypes.c_float * (64 * 8))()
            dst = (ctypes.c_float * (64 * 8))()
            for i in range(64):
                for c in range(8):
                    src[i * 8 + c] = 0.125 if c in (0, 1) else 0.0
            lib.auradsp_process(h, src, dst, 64)
            return [float(v) for v in dst]
        finally:
            lib.auradsp_destroy(h)

    matrix_off = process(0, 0)
    matrix_on = process(0, 1)
    check("matrix upmix_fill=0 leaves unused targets silent",
          all(abs(matrix_off[c]) < 1e-6 for c in (2, 4, 5, 6, 7)))
    check("matrix upmix_fill=1 expands to mapped targets",
          all(abs(matrix_on[c]) > 1e-4 for c in (2, 4, 5, 6, 7)))
    for fill in (0, 1):
        discrete = process(1, fill)
        expected = [0.125, 0.125, 0, 0, 0, 0, 0, 0] * 64
        check(f"discrete upmix_fill={fill} preserves slot identity",
              all(abs(a - b) < 1e-6 for a, b in zip(discrete, expected)))

    try:
        remap = lib.auradsp_remap_channels
    except AttributeError:
        check("VM-06 shared WASAPI remap export available", False,
              "auradsp_remap_channels missing")
        return
    check("VM-06 shared WASAPI remap export available", True)
    remap.argtypes = [
        ctypes.POINTER(ctypes.c_float), ctypes.c_int,
        ctypes.POINTER(ctypes.c_float), ctypes.c_int,
        ctypes.c_int, ctypes.c_int]
    remap.restype = ctypes.c_int
    src = (ctypes.c_float * 8)(1, 2, 3, 4, 5, 6, 7, 8)

    def remap_frame(dst_ch, mode):
        dst = (ctypes.c_float * 8)()
        rc = remap(src, 8, dst, dst_ch, 1, mode)
        return rc, [dst[i] for i in range(dst_ch)]

    k = 0.70710678
    cases = [
        ("VM-06 WASAPI 8ch -> manual 4 matrix", 4, 0,
         [1 + 3 * k, 2 + 3 * k, 7 + 5 * k, 8 + 6 * k]),
        ("VM-06 WASAPI 8ch -> manual 6 matrix", 6, 0,
         [1, 2, 3, 4, 5 + 7 * k, 6 + 8 * k]),
        ("WASAPI 8ch -> manual 2 matrix", 2, 0,
         [1 + (3 + 5 + 7) * k, 2 + (3 + 6 + 8) * k]),
        ("VM-06 WASAPI 8ch -> manual 4 discrete", 4, 1, [1, 2, 7, 8]),
        ("VM-06 WASAPI 8ch -> manual 6 discrete", 6, 1, [1, 2, 3, 4, 5, 6]),
        ("WASAPI 8ch -> manual 8 discrete", 8, 1, [1, 2, 3, 4, 5, 6, 7, 8]),
    ]
    for name, dst_ch, mode, expected in cases:
        rc, got = remap_frame(dst_ch, mode)
        check(name, rc == 0 and len(got) == len(expected) and
              all(abs(a - b) < 1e-6 for a, b in zip(got, expected)),
              f"rc={rc} got={got} want={expected}")


def main():
    print("== smoke_asio_driver_channel_map ==")
    with open(DRIVER, encoding="utf-8") as f:
        driver = f.read()
    check("ASIO pump snapshots requested and active geometry together",
          "m_requestedGeometry.Load(&requested)" in driver and
          "GetActiveGeometry(m_engine, &activeAbi)" in driver and
          "const bool geometryReady" in driver)
    check("ASIO matrix narrowing delegates chmap_fold",
          "chmap_fold(m_interleavedIn, (int)ch, m_engIn, engCh" in driver)
    check("ASIO discrete gather uses streamCh then engineCh",
          "chmap_gather_discrete(m_interleavedIn, (int)ch,\n"
          "                                                  m_engIn, engCh" in driver)
    check("ASIO expansion and output scatter preserve slot sources",
          "chmap_scatter_discrete(m_interleavedIn, (int)ch,\n"
          "                                                   m_engIn, engCh" in driver and
          "chmap_scatter_discrete(engOut, engCh, m_proc, (int)ch" in driver)
    check("ASIO process expected geometry comes from active snapshot",
          "const auradsp_geometry expected{\n"
          "                        active.generation, active.channels, active.mode}" in driver)

    run_native_map()
    engine_fixtures()

    with open(ISOLATE, encoding="utf-8") as f:
        isolate = f.read()
    check("VM-06 manual pump delegates mismatched raw width to shared remap",
          "lib!.remapChannels(" in isolate and
          "final rawCh = rawMulti.rawCh;" in isolate and
          "if (rawCh == engineChCount)" in isolate)

    print("RESULT:", "FAIL " + ",".join(FAIL) if FAIL else "PASS")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
