#!/usr/bin/env python3
"""Source contract for the VAIO capture-mute ruling (2026-11-23, A 案).

While the VAIO bridge holds the ring mapped (VAIO mode), the
driver's capture endpoint must serve silence instead of looping
back the raw pre-processing render stream. The bridge raises
CaptureMuted in the shared header; the driver honors it in
ReadCaptureSamples; teardown paths (bridge unmap, driver cleanup
of the mapping file object, driver destroy) clear it so the
pipeline-mode loopback is never left muted by a dead bridge.
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
check("volatile ULONG      CaptureMuted;" in ipc,
      "shared header carries the CaptureMuted field")
check("Reserved[11]" in ipc,
      "header size preserved (Reserved 12 after this field, 11 after S1 CaptureSource)")

drv = read("core/desktop/windows-drivers/01_vaio_driver/src/ControlDevice.cpp")
fn = drv.split("AuraControlDevice_ReadCaptureSamples", 1)[1].split(
    "AuraControlDevice_", 1)[0]
check("pHeader->CaptureMuted != 0" in fn,
      "driver capture read honors the mute flag")
check(fn.count("CaptureMuted") == 1,
      "mute check sits in the capture read only")
check(drv.count("->CaptureMuted = 0") == 2,
      "driver clears the flag on cleanup and on destroy")

bridge = read("core/desktop/windows-drivers/bridge/vaio_bridge/VaioBridge.cpp")
check("pRingHeader->CaptureMuted = 1" in bridge,
      "bridge raises the flag when the ring is mapped")
check("pRingHeader) g_vaio.pRingHeader->CaptureMuted = 0" in bridge,
      "bridge clears the flag before unmapping")

print("FAILURES:", len(FAIL))
sys.exit(1 if FAIL else 0)
