#!/usr/bin/env python3
"""Source contract for the VB bridge geometry/readiness contract.

乙 (discrete folding): vb_set_param must request channels.mode through the
pending geometry ABI alongside channels.count. The pump-shadow chanMode is
published only after every live group reports the same complete active
geometry; the bridge must not mutate workCh/chanMode directly.

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
      and "ApplyWorkGeometry(RequestedWorkChannels(), value)" in set_param
      and bridge.count("ApplyWorkGeometry(RequestedWorkChannels(), iv)") >= 2,
      "vb_set_param requests pending channels.mode geometry")
check('strcmp(id, "channels.count") == 0' in set_param,
      "vb_set_param keeps the channels.count dedicated path")
check("InterlockedExchange(&g_b.ctx.workCh" not in bridge
      and "InterlockedExchange(&g_b.ctx.chanMode" not in bridge,
      "bridge never publishes pump geometry directly")

request_geometry = pump.split("inline bool VmRequestGroupGeometry(", 1)[1].split(
    "inline int VmLiveEngineCount", 1)[0]
bridge_request = bridge.split("bool RequestGroupGeometry(", 1)[1].split(
    "static bool ProcessingAbiReady()", 1)[0]
request_call = request_geometry.find("c->requestGeometry(engine")
generation_publish = request_geometry.find("requestedGeneration[g]")
check("vmcore::VmRequestGroupGeometry" in bridge_request
      and request_call >= 0 and generation_publish > request_call
      and "generation == 0" in request_geometry,
      "geometry request publishes a nonzero generation only after engine acceptance")
apply_geometry = pump.split("inline int VmApplyWorkGeometry(", 1)[1].split(
    "// 选取一个没有未完成 claimant", 1)[0]
bridge_apply = bridge.split("int ApplyWorkGeometry(", 1)[1].split(
    "int ApplyWorkChannels(", 1)[0]
check("vmcore::VmApplyWorkGeometry" in bridge_apply
      and "oldChannels[PumpCtx::kMaxGroups]" in apply_geometry
      and "oldMode[PumpCtx::kMaxGroups]" in apply_geometry
      and "VmRequestGroupGeometry(c, g, c->eng[g], oldChannels[g],"
          in apply_geometry,
      "partial geometry requests roll back prior groups to their old geometry")

sync_geometry = pump.split("inline LONG SyncGeometryAtBlockStart(", 1)[1].split(
    "inline bool ProcessEngineGeometry(", 1)[0]
publish_guard = sync_geometry.split("if (ready && haveGeometry)", 1)
check(len(publish_guard) == 2
      and "InterlockedExchange(&c->workCh, common.channels)" in publish_guard[1]
      and "InterlockedExchange(&c->chanMode, common.mode)" in publish_guard[1]
      and "active.generation == requested" in sync_geometry
      and "active.channels == channels && active.mode == mode" in sync_geometry,
      "pump publishes only a complete matching active geometry")

startup = bridge.split("int vb_start(", 1)[1].split("int vb_stop(", 1)[0]
rebuild = bridge.split("void RebuildEngines(", 1)[1].split(
    "void ApplyParamsString(", 1)[0]
abi_helper = bridge.split("static bool ProcessingAbiReady()", 1)
abi_body = abi_helper[1].split("}", 1)[0] if len(abi_helper) == 2 else ""
check(len(abi_helper) == 2
      and all(symbol in abi_body for symbol in (
          "g_b.create", "g_b.ctx.process &&", "g_b.ctx.processGeometry",
          "g_b.ctx.requestGeometry", "g_b.ctx.getActiveGeometry",
          "g_b.ctx.destroy")),
      "shared readiness predicate requires the complete processing ABI")
for label, body in (("startup", startup), ("rebuild", rebuild)):
    check("ProcessingAbiReady()" in body,
          label + " uses the complete processing ABI readiness predicate")
check('GetProcAddress(g_b.eng, "auradsp_abi")' in rebuild
      and "abiOk && ProcessingAbiReady()" in rebuild,
      "rebuild revalidates the engine ABI version and complete processing symbols")
check("engineReady = abiOk && ProcessingAbiReady();" in startup
      and "engineReady = g_b.ctx.scratchIn && g_b.ctx.scratchOut" in startup,
      "startup keeps ABI, scratch, and live-handle validation in one readiness result")
check("RequestGroupGeometry(g," in startup
      and "requestedGeneration[g], 1" not in startup,
      "startup requests initial geometry through the per-handle ABI")
rebuild_create = rebuild.split("void* e = g_b.create(sr, 2048);", 1)
rebuild_request = rebuild_create[1].find("RequestGroupGeometry(g, e, 2, 0)") \
    if len(rebuild_create) == 2 else -1
rebuild_publish = rebuild_create[1].find("g_b.ctx.eng[g] = e;") \
    if len(rebuild_create) == 2 else -1
check(rebuild_request >= 0 and rebuild_publish > rebuild_request,
      "rebuild requests each new handle geometry before publishing it")
lazy = bridge.split("static bool CreateGroupEngineLocked(", 1)[1].split(
    "static void DestroyGroupEngineLocked(", 1)[0]
lazy_request = lazy.find("MirrorReplayOne(g, e, setP)")
lazy_publish = lazy.find("InterlockedExchangePointer((PVOID volatile*)&g_b.ctx.eng[g]")
check("ProcessingAbiReady()" in lazy
      and lazy_request >= 0 and lazy_publish > lazy_request,
      "lazy-create requires the full ABI and requests geometry before publish")
unload = startup.split("if (!engineReady)", 1)
check(len(unload) == 2
      and "DestroyEngines()" in unload[1].split("FreeLibrary(g_b.eng)", 1)[0]
      and "ClearProcessingAbi()" in unload[1],
      "startup destroys created handles and clears exports before unload")

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
