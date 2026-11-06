#!/usr/bin/env python3
"""Sample process memory/CPU for one measurement stage and attach VM snapshots."""
import argparse
import json
import os
import statistics
import sys
import time

import psutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vm_probe


def sample(pid, seconds, interval):
    p = psutil.Process(pid)
    p.cpu_percent(interval=None)
    rows = []
    t0 = time.time()
    while time.time() - t0 < seconds:
        time.sleep(interval)
        mi = p.memory_info()
        cpu = p.cpu_percent(interval=None)
        rows.append({
            "t": round(time.time() - t0, 2),
            "rss_mb": round(mi.rss / 1048576, 2),
            "private_mb": round(mi.private / 1048576, 2),
            "cpu_pct_core": cpu,
            "threads": p.num_threads(),
            "handles": getattr(p, "num_handles", lambda: None)(),
        })
    # trim warm-up (first 20%)
    steady = rows[len(rows) // 5:] or rows
    return rows, {
        "rss_avg_mb": round(statistics.mean([r["rss_mb"] for r in steady]), 2),
        "rss_max_mb": round(max(r["rss_mb"] for r in steady), 2),
        "private_avg_mb": round(statistics.mean([r["private_mb"] for r in steady]), 2),
        "private_max_mb": round(max(r["private_mb"] for r in steady), 2),
        "cpu_avg_pct_core": round(statistics.mean([r["cpu_pct_core"] for r in steady]), 2),
        "cpu_max_pct_core": round(max(r["cpu_pct_core"] for r in steady), 2),
        "cpu_cores": psutil.cpu_count(logical=True),
        "threads_avg": round(statistics.mean([r["threads"] for r in steady]), 1),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--seconds", type=float, default=30)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--label", default="stage")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--ws", default="")
    ap.add_argument("--alloc", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    rows, summary = sample(args.pid, args.seconds, args.interval)
    out = {"label": args.label, "pid": args.pid, "seconds": args.seconds, "summary": summary, "rows": rows}

    if args.ws:
        vm = vm_probe.VM(args.ws)
        try:
            iso, info = vm_probe.root_isolate(vm)
            out["vmMemoryStart"] = vm_probe.mem_snapshot(vm, iso["id"])
            if args.alloc:
                prof = vm_probe.alloc_profile(vm, iso["id"])
                out["allocation"] = {
                    "totalBytesCurrent": prof["totalBytesCurrent"],
                    "top": prof["members"][:40],
                }
            out["vmMemoryEnd"] = vm_probe.mem_snapshot(vm, iso["id"])
            out["vmIsolates"] = [{"id": i.get("id"), "name": i.get("name")} for i in info.get("isolates", [])]
        finally:
            vm.close()

    path = os.path.join(args.outdir, f"proc_{args.label}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print(json.dumps({"path": path, "summary": summary, "vmStart": out.get("vmMemoryStart"),
                      "vmEnd": out.get("vmMemoryEnd")}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
