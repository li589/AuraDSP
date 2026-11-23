#!/usr/bin/env python3
"""Source contract for the VB bridge r65 dual fix (2026-11-23).

乙 (discrete folding): vb_set_param's pump-shadow block must carry
channels.mode alongside the spatial pair - the bulk apply path and
the rebuild replay both sync chanMode, and the live single-param
path missing it left the pump folding while the engines processed
discrete (every channel count except 7.1 folded).

乙 secondary (gate/idle criteria): the pump's gate peak and idle
silence judgement must be taken over the engine feed-slot set
(FeedSlots/BusSlotsPeak/BusSlotsSilent), not the main pair only -
a per-channel test tone on high channels alone otherwise reads as
whole-group silence (gate zeroes the group, idle bypasses DSP).

甲 (meter residue): vb_viz_read must emit SilentVizEmitter frames
when the selected group's input is frozen (pump sigSame criterion)
or the callback frame counter stalls - Voicemeeter replays a frozen
buffer after stop, the engines keep producing hot viz frames, and
neither Dart watchdog (both keyed on frame stop) ever fires.
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


bridge = read("core/desktop/windows-drivers/bridge/vm_bridge/VmBridge.cpp")
pump = read("core/desktop/windows-drivers/02_voicemeeter_client/VmPumpCore.h")

set_param = bridge.split("int vb_set_param(", 1)[1].split(
    "int vb_set_param_str(", 1)[0]
check('strcmp(id, "channels.mode") == 0' in set_param
      and "g_b.ctx.chanMode" in set_param,
      "vb_set_param syncs the chanMode pump shadow")
check('strcmp(id, "channels.count") == 0' in set_param,
      "vb_set_param keeps the channels.count dedicated path")

check("inline int FeedSlots(" in pump
      and "BusSlotsPeak(" in pump and "BusSlotsSilent(" in pump,
      "pump exposes the feed-slot criteria helpers")
proc = pump.split("inline void ProcessGroupVm(", 1)[1].split(
    "inline void VmWorkComplete(", 1)[0]
check("BusSlotsPeak(ab, base, feedSlots, feedCnt, n)" in proc,
      "gate peak taken over the feed-slot set")
check("gateInPeak = (float)grpPeak" not in proc,
      "gate peak no longer the main-pair peak")
check(proc.count("BusSlotsSilent(ab, base, feedSlots, feedCnt, n)") >= 2,
      "idle accumulate and wake both judge by the feed-slot set")

viz = bridge.split("int vb_viz_read(", 1)[1].split(
    "unsigned vb_abi(", 1)[0]
check("VizGroupFrozen(g)" in viz and "VizFramesStalled()" in viz,
      "vb_viz_read checks freeze and stall before reading frames")
check("g_silentViz.Emit" in viz,
      "vb_viz_read emits silent frames on freeze/stall")
check("sigSame[g] > frozenAt" in bridge,
      "freeze criterion reuses the pump sigSame threshold")

print("FAILURES:", len(FAIL))
sys.exit(1 if FAIL else 0)
