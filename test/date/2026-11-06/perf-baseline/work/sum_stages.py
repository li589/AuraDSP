import glob
import json
import os

for p in sorted(glob.glob(r"d:\temp_desktop\Proj\JamesDSP\2026-11-06\perf-baseline\work\stages\proc_*.json")):
    d = json.load(open(p, encoding="utf-8"))
    s = d["summary"]
    rows = d["rows"][::3]
    print("%-38s rss=%7.1f/%7.1f cpuCore=%6.1f thr=%s" % (
        os.path.basename(p)[5:-5], s["rss_avg_mb"], s["rss_max_mb"],
        s["cpu_avg_pct_core"], s["threads_avg"]))
    print("    cpu samples:", [round(r["cpu_pct_core"] / 100, 2) for r in rows])
