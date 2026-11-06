#!/usr/bin/env python3
"""VM Service probe for AuraDSP profile builds.

Usage:
  python vm_probe.py ws://127.0.0.1:PORT/TOKEN=/ws info
  python vm_probe.py ... mem --out memory.json
  python vm_probe.py ... alloc --out alloc.json
  python vm_probe.py ... timeline --seconds 10 --out timeline.json
  python vm_probe.py ... cpu --seconds 10 --out cpu.json
  python vm_probe.py ... all --seconds 10 --outdir DIR --label STAGE
"""
import argparse
import json
import os
import sys
import time

import websocket


class VM:
    def __init__(self, ws_uri):
        self.ws = websocket.create_connection(ws_uri, timeout=30)
        self.seq = 0

    def call(self, method, params=None):
        self.seq += 1
        req = {"jsonrpc": "2.0", "id": self.seq, "method": method, "params": params or {}}
        self.ws.send(json.dumps(req))
        while True:
            raw = self.ws.recv()
            if not raw:
                continue
            msg = json.loads(raw)
            if msg.get("id") == self.seq:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


def root_isolate(vm):
    info = vm.call("getVM")
    isolates = info.get("isolates", [])
    main = None
    for iso in isolates:
        if iso.get("name") in ("main", "root"):
            main = iso
            break
    if main is None and isolates:
        main = isolates[0]
    return main, info


def mem_snapshot(vm, iso_id):
    mu = vm.call("getMemoryUsage", {"isolateId": iso_id})
    return {
        "heapUsage": mu.get("heapUsage"),
        "heapCapacity": mu.get("heapCapacity"),
        "externalUsage": mu.get("externalUsage"),
        "heapUsedMB": round((mu.get("heapUsage") or 0) / 1048576, 2),
        "heapCapacityMB": round((mu.get("heapCapacity") or 0) / 1048576, 2),
        "externalMB": round((mu.get("externalUsage") or 0) / 1048576, 2),
    }


def mem_all_isolates(vm):
    info = vm.call("getVM")
    out = {}
    for iso in info.get("isolates", []):
        try:
            out[iso.get("name") or iso["id"]] = mem_snapshot(vm, iso["id"])
        except Exception as e:
            out[iso.get("name") or iso["id"]] = {"error": str(e)}
    return out


def alloc_profile(vm, iso_id):
    prof = vm.call("getAllocationProfile", {"isolateId": iso_id, "gc": True})
    members = prof.get("members", [])
    rows = []
    for m in members:
        cls = m.get("class") or m.get("classRef") or {}
        lib = (cls.get("library") or {}).get("uri") or ""
        rows.append({
            "class": cls.get("name"),
            "library": lib,
            "bytesCurrent": m.get("bytesCurrent"),
            "instancesCurrent": m.get("instancesCurrent"),
            "bytesAccumulated": m.get("accumulatedSize"),
            "instancesAccumulated": m.get("instancesAccumulated"),
        })
    rows.sort(key=lambda r: (r["bytesCurrent"] or 0), reverse=True)
    total = sum(r["bytesCurrent"] or 0 for r in rows)
    return {"members": rows, "totalBytesCurrent": total}


def cpu_samples(vm, iso_id, seconds):
    end = int(time.time() * 1000000)
    start = end - int(seconds * 1000000)
    res = vm.call("getCpuSamples", {
        "isolateId": iso_id,
        "timeOriginMicros": start,
        "timeExtentMicros": end - start,
    })
    funcs = res.get("functions", []) or []
    samples = res.get("samples", []) or []
    by_func = {}
    for s in samples:
        fid = s.get("functionId") or s.get("stackTraceId") or 0
        by_func[fid] = by_func.get(fid, 0) + 1
    fmap = {f.get("id"): f for f in funcs}
    rows = []
    for fid, count in by_func.items():
        f = fmap.get(fid, {})
        rows.append({
            "function": f.get("name") or f"fn#{fid}",
            "kind": f.get("kind"),
            "samples": count,
        })
    rows.sort(key=lambda r: r["samples"], reverse=True)
    return {"sampleCount": len(samples), "periodMicros": res.get("samplePeriod"), "top": rows[:40]}


def timeline(vm, seconds):
    try:
        vm.call("setVMTimelineFlags", {"recordedStreams": ["Dart", "Embedder", "GC", "Compiler", "VM", "Isolate"]})
    except Exception as e:
        print("setVMTimelineFlags failed:", e, file=sys.stderr)
    vm.call("clearVMTimeline")
    time.sleep(seconds)
    end = int(time.time() * 1000000)
    start = end - int(seconds * 1000000)
    res = vm.call("getVMTimeline", {"timeOriginMicros": start, "timeExtentMicros": end - start})
    events = res.get("traceEvents", []) or []
    return {"traceEvents": events, "timeOriginMicros": start, "timeExtentMicros": end - start}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ws")
    ap.add_argument("cmd", choices=["info", "mem", "alloc", "timeline", "cpu", "all"])
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--out", default="")
    ap.add_argument("--outdir", default="")
    ap.add_argument("--label", default="stage")
    args = ap.parse_args()

    vm = VM(args.ws)
    try:
        iso, info = root_isolate(vm)
        iso_id = iso["id"]
        out = {"isolate": {"id": iso_id, "name": iso.get("name")}, "vm": {
            "version": info.get("version"),
            "pid": (info.get("_profilerInfo") or {}).get("pid") if info.get("_profilerInfo") else None,
        }}
        if args.cmd in ("info", "mem", "all"):
            out["memory"] = mem_snapshot(vm, iso_id)
        if args.cmd in ("alloc", "all"):
            out["allocation"] = alloc_profile(vm, iso_id)
        if args.cmd in ("cpu",):
            out["cpu"] = cpu_samples(vm, iso_id, args.seconds)
        if args.cmd == "timeline":
            out["timeline"] = timeline(vm, args.seconds)
        if args.cmd == "all":
            out["cpu"] = cpu_samples(vm, iso_id, args.seconds)
            out["timeline"] = timeline(vm, args.seconds)
            out["memoryAfter"] = mem_snapshot(vm, iso_id)
        text = json.dumps(out, ensure_ascii=False)
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(text)
            print(f"wrote {args.out}")
        else:
            print(text[:20000])
    finally:
        vm.close()


if __name__ == "__main__":
    main()
