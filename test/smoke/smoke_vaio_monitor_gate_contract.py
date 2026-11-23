#!/usr/bin/env python3
"""Source contract for the VAIO local-monitor gate (2026-11-23, B 案).

The old "monitor mirroring" second render path (a duplicate copy
to the system default endpoint, auto-disabled whenever the main
output WAS the default) is gone. The setting is now an honest
local-monitor gate: off silences only the local WASAPI render
(AUDCLNT_BUFFERFLAGS_SILENT), while the engine keeps processing
and telemetry keeps flowing. Default is ON.

Revision (r65 S2, 2026-11-23): the 2x2 model re-scopes the gate.
The main-path SILENT gate is retired — with WASAPI output the
main render always sounds; the setting now means "WASAPI mirror
switch when output is VAIO": off means no physical endpoint is
opened at all and the pump runs on the ring clock.
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


bridge = read("core/desktop/windows-drivers/bridge/vaio_bridge/VaioBridge.cpp")
check("bool monitorEnabled = true;" in bridge,
      "bridge monitor gate defaults to enabled")
check("g_vaio.monitorEnabled = (monitor_mirror != 0);" in bridge,
      "start config drives the gate")
check("AUDCLNT_BUFFERFLAGS_SILENT" not in bridge,
      "main-path silence gate retired (2x2 re-scope)")
check("!g_vaio.outputVaio || g_vaio.monitorEnabled" in bridge,
      "mirror client exists only when output is VAIO and mirror is on")
check('"outVaio":%d' in bridge.replace("\\", ""),
      "status reports the output axis")
for gone in ("pMirrorClient", "FeedMirror", "VaioMirrorFeed",
             "mirrorRequested", "mirrorActive"):
    check(gone not in bridge, f"mirror path removed: {gone}")
check(not (ROOT / "core/desktop/windows-drivers/bridge/vaio_bridge"
           / "VaioMirrorFeed.h").exists(),
      "VaioMirrorFeed.h deleted")

dart_cfg = read("app/auradsp_app/lib/core/config.dart")
check("this.monitorMirroring = true" in dart_cfg,
      "App config default for the monitor gate is ON")

print("FAILURES:", len(FAIL))
sys.exit(1 if FAIL else 0)
