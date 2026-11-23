#!/usr/bin/env python3
"""Source contract for the VAIO processed write-back ring (2026-11-23,
2x2 combination model S1).

The VAIO-in + VAIO-out cell needs processed audio delivered to the
capture endpoint without rendering back into the render endpoint that
is serving as the input. The driver grows a second shared ring (the
processed ring): the bridge produces into it, the driver's capture
read consumes from it. The render header's CaptureSource field picks
the capture source three ways: loopback (0, with the r64 mute flag
still honored), muted (1), processed ring (2). Mapping the processed
ring is restricted to the render-ring holder process, and every
teardown path (mapping cleanup of either ring, driver destroy) clears
CaptureSource so a dead bridge can never leave the capture endpoint
reading a producer-less ring.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FAIL = []


def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        FAIL.append(label)


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8", errors="replace")


ipc = read("core/desktop/windows-drivers/common/AuraVaioIpc.h")
check("volatile ULONG      CaptureSource;" in ipc,
      "shared header carries the CaptureSource field")
check("Reserved[11]" in ipc,
      "header size preserved (Reserved shrinks to 11)")
check("IOCTL_AURAVAIO_MAP_PROCESSED_RING" in ipc and "0x805" in ipc,
      "MAP_PROCESSED_RING ioctl defined (0x805)")
check("IOCTL_AURAVAIO_UNMAP_PROCESSED_RING" in ipc and "0x806" in ipc,
      "UNMAP_PROCESSED_RING ioctl defined (0x806)")
check("AURA_VAIO_CAPTURE_PROCESSED     2" in ipc,
      "capture source constant for the processed ring is 2")

drv = read("core/desktop/windows-drivers/01_vaio_driver/src/ControlDevice.cpp")
check("g_pProcRingBuffer" in drv and "AuraAllocatePool" in drv,
      "driver allocates the processed ring")
check("case IOCTL_AURAVAIO_MAP_PROCESSED_RING:" in drv,
      "driver handles MAP_PROCESSED_RING")
check("case IOCTL_AURAVAIO_UNMAP_PROCESSED_RING:" in drv,
      "driver handles UNMAP_PROCESSED_RING")
mapfn = drv.split("case IOCTL_AURAVAIO_MAP_PROCESSED_RING:", 1)[1].split(
    "case IOCTL_AURAVAIO_UNMAP_PROCESSED_RING:", 1)[0]
check("g_pMappedProcess != currentProc" in mapfn,
      "processed mapping restricted to the render-ring holder")
fn = drv.split("AuraControlDevice_ReadCaptureSamples", 1)[1].split(
    "AuraControlDevice_", 1)[0]
check("pHeader->CaptureSource" in fn,
      "capture read selects its source from CaptureSource")
check("AURA_VAIO_CAPTURE_PROCESSED" in fn and "ReadProcessedCaptureSamples" in fn,
      "processed source dispatches to the processed-ring reader")
check("static VOID\nReadProcessedCaptureSamples" in drv
      or "ReadProcessedCaptureSamples(" in drv,
      "processed-ring reader exists in the driver")
check(drv.count("->CaptureSource = 0") >= 3,
      "driver clears CaptureSource on cleanup paths and destroy")

print("FAILURES:", len(FAIL))
sys.exit(1 if FAIL else 0)
