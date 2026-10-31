# -*- coding: utf-8 -*-
"""bench_full_chain.py — 一次性性能探针（非门禁）

Part 1 单效果器全参数评估：
  以参数表为真相源，逐效果器单独启用，遍历该效果器全部有界参数
  （min/中点/max 三档），测量每 480 帧块（10ms@48k）处理耗时并记录最坏值。
  依赖外部资源的节点（ddc 需要 VDC）显式标注 SKIP；convolver 用合成 IR。

Part 2 全链条启动 + 实时调参：
  启 20 个参数链节点（含 2048-tap 合成 IR 卷积），测量 create→参数下发→首块
  的冷启动耗时；随后在控制线程持续随机改参数（约 500 次/秒），主线程连续
  处理 3000 块，统计音频块 p50/p95/p99/max、xrun 代理（>10ms）、set_param
  延迟分布、输出有限性/峰值。ctypes 调用期间释放 GIL，控制与 RT 为真并发。

输出：stdout 表格 + .tmp/bench_full_chain.json（供报告引用）。
"""
import ctypes
import json
import math
import os
import random
import re
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
TABLE = os.path.join(ROOT, "engine", "engine_param_table.h")
TMP = os.path.join(ROOT, ".tmp")
os.makedirs(TMP, exist_ok=True)

SR = 48000.0
N = 480
BLOCK_MS = N / SR * 1000.0

lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_get_param.restype = ctypes.c_int32
lib.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]


def f32(v):
    return ctypes.c_float(v)


def i32(v):
    return ctypes.c_int32(v)


def set_param(h, key, kind, value):
    if kind == "f":
        return lib.auradsp_set_param(h, key.encode(), ctypes.byref(f32(value)), 4)
    return lib.auradsp_set_param(h, key.encode(), ctypes.byref(i32(int(value))), 4)


def set_str(h, key, text):
    b = text.encode("utf-8")
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return lib.auradsp_set_param(h, key.encode(), buf, len(b))


def get_str(h, key, size=8192):
    buf = ctypes.create_string_buffer(size)
    rc = lib.auradsp_get_param(h, key.encode(), buf, size)
    return rc, buf.value.decode("utf-8", "replace")


def parse_params():
    """(kind, name, min, max, deprecated) 列表，按表顺序。"""
    rows = []
    for line in open(TABLE, encoding="utf-8"):
        if "deprecated alias" in line:
            continue
        m = re.search(r'PARAM_(FLOAT|INT|BOOL)\("([^"]+)",\s*\w+(?:\[\d+\])?,\s*'
                      r'(-?\d+(?:\.\d+)?f?),\s*(-?\d+(?:\.\d+)?f?)?', line)
        if not m:
            continue
        kind = {"FLOAT": "f", "INT": "i", "BOOL": "i"}[m.group(1)]
        lo = _num(m.group(3)) if m.group(3) else 0.0
        hi = _num(m.group(4)) if m.group(4) else 1.0
        rows.append((kind, m.group(2), lo, hi))
    return rows


def _num(text):
    t = text.strip().rstrip("f")
    return float(int(t, 16)) if t.lower().startswith("0x") else float(t)


def group_of(name):
    return name.split(".", 1)[0]


ENABLE = {
    "tube": "tube.enable", "comp": "comp.enable", "convolver": "convolver.enable",
    "arbmag": "arbmag.enable", "bass": "bass.enable", "eq": "eq.enable",
    "reverb": "freeverb.enable",  # WP1：freeverb 已退役，此为 reverb.preset 写别名
    "dyneq": "dyneq.enable", "stereo": "stereo.enable", "haas": "haas.enable",
    "crossfeed": "crossfeed.enable", "spatial": "spatial.enable",
    "bassmono": "bassmono.enable", "shelf": "shelf.enable", "filter": "filter.enable",
    "exciter": "exciter.enable", "gate": "gate.enable", "deesser": "deesser.enable",
    "loudness": "loudness.enable", "liveprog": "liveprog.enable", "limiter": "limiter.enable",
}

# 使效果器真正进入处理路径的代表性参数（不覆盖被评估参数本身）
ACTIVATE = {
    "tube": [("tube.gain", "f", 6.0), ("tube.mix", "f", 1.0)],
    "comp": [("comp.timeconstant", "f", 0.05)],
    "convolver": [("convolver.mix", "f", 0.8)],
    "arbmag": [],
    "bass": [("bass.gain", "f", 8.0), ("bass.mode", "i", 1), ("bass.cutoff", "f", 100.0)],
    "eq": [],
    "reverb": [("freeverb.wet", "f", 0.5), ("freeverb.decay", "f", 0.7)],
    "dyneq": [("dyneq.low.gain", "f", 6.0), ("dyneq.mid.gain", "f", 6.0)],
    "stereo": [("stereo.mix", "f", 0.5)],
    "haas": [("haas.delay", "f", 10.0), ("haas.mix", "f", 0.5)],
    "crossfeed": [],
    "spatial": [("spatial.width", "f", 1.0), ("spatial.room", "f", 0.5)],
    "bassmono": [],
    "shelf": [("shelf.gain", "f", 6.0)],
    "filter": [("filter.type", "i", 0), ("filter.freq", "f", 3000.0)],
    "exciter": [("exciter.amount", "f", 0.5)],
    "gate": [("gate.threshold", "f", -30.0)],
    "deesser": [("deesser.amount", "f", 0.5)],
    "loudness": [("loudness.amount", "f", 0.5)],
    "liveprog": [],
    "limiter": [("limiter.lookahead", "i", 1)],
}


def write_ir(path, taps=2048):
    """合成 48k 立体声 IR（指数衰减噪声），供卷积节点进入真实 FFT 路径。"""
    rnd = random.Random(7)
    frames = []
    for i in range(taps):
        g = math.exp(-i / (taps / 6.0)) * 0.02
        frames.append((rnd.uniform(-1, 1) * g, rnd.uniform(-1, 1) * g))
    import struct
    data = b"".join(struct.pack("<hh", int(max(-1, min(1, l)) * 32767),
                                int(max(-1, min(1, r)) * 32767)) for l, r in frames)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, 48000, 48000 * 4, 4, 16)
    hdr += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as f:
        f.write(hdr + data)


INT16 = (ctypes.c_float * (N * 2))()
OUTBUF = (ctypes.c_float * (N * 2))()
phase = 0.0
for n in range(N):
    s = 0.30 * math.sin(phase) + 0.08 * math.sin(phase * 2.7) + 0.04 * math.sin(phase * 7.1)
    phase += 2 * math.pi * 220.0 / SR
    INT16[2 * n] = s
    INT16[2 * n + 1] = s * 0.93


def measure_block_us(h, blocks=200, warmup=30):
    for _ in range(warmup):
        lib.auradsp_process(h, INT16, OUTBUF, N)
    samples = []
    for _ in range(blocks):
        t0 = time.perf_counter_ns()
        lib.auradsp_process(h, INT16, OUTBUF, N)
        samples.append((time.perf_counter_ns() - t0) / 1000.0)
    samples.sort()
    return {
        "p50": samples[len(samples) // 2],
        "p95": samples[int(len(samples) * 0.95)],
        "max": samples[-1],
        "mean": sum(samples) / len(samples),
    }


ALL_OFF = [("tube.enable"), ("comp.enable"), ("convolver.enable"), ("ddc.enable"),
           ("arbmag.enable"), ("bass.enable"), ("eq.enable"), ("freeverb.enable"),
           ("dyneq.enable"), ("stereo.enable"), ("haas.enable"), ("crossfeed.enable"),
           ("spatial.enable"), ("bassmono.enable"), ("shelf.enable"), ("filter.enable"),
           ("exciter.enable"), ("gate.enable"), ("deesser.enable"), ("loudness.enable"),
           ("liveprog.enable"), ("limiter.enable")]


def disable_all(h):
    for key in ALL_OFF:
        set_param(h, key, "i", 0)


def prepare_convolver(h):
    ir = os.path.join(TMP, "bench_ir_2048.wav")
    write_ir(ir, 2048)
    rc = set_str(h, "convolver.ir.path", ir)
    return rc


def part1():
    params = parse_params()
    by_group = {}
    for kind, name, lo, hi in params:
        by_group.setdefault(group_of(name), []).append((kind, name, lo, hi))

    h = lib.auradsp_create(SR, N)
    disable_all(h)
    # 先加载卷积 IR，便于后续只靠 enable 切换
    conv_rc = prepare_convolver(h)

    base = measure_block_us(h, blocks=300)
    print("\n== Part 1 单效果器全参数评估（480f=10ms@48k，单位 us/块） ==")
    print("%-12s %10s %10s %10s  %s" % ("effect", "baseline", "effect-on", "worst", "worst-param"))

    results = []
    for eff, enable_key in ENABLE.items():
        if eff == "ddc":
            continue
        disable_all(h)
        set_param(h, enable_key, "i", 1)
        for key, kind, val in ACTIVATE.get(eff, []):
            set_param(h, key, kind, val)
        if eff == "convolver":
            if conv_rc != 0:
                print("[SKIP] convolver: IR load rc=%d" % conv_rc)
                continue
            set_param(h, "convolver.enable", "i", 1)
        on = measure_block_us(h, blocks=250)
        worst = on["p50"]
        worst_param = "(effect-on)"
        per_param = []
        for kind, name, lo, hi in by_group.get(eff, []):
            if name == enable_key:
                continue
            vals = [lo, (lo + hi) / 2.0, hi] if kind == "f" else [lo, hi]
            w = 0.0
            for v in vals:
                ts = time.perf_counter_ns()
                rc = set_param(h, name, kind, v)
                set_us = (time.perf_counter_ns() - ts) / 1000.0
                if rc != 0:
                    continue
                m = measure_block_us(h, blocks=120, warmup=10)
                per_param.append({"param": name, "value": v, "p50_us": m["p50"],
                                  "p95_us": m["p95"], "max_us": m["max"], "set_us": set_us})
                if m["p50"] > w:
                    w = m["p50"]
                    worst_param = "%s=%.4g" % (name, v)
            if w > worst:
                worst = w
        # 收尾把该效果器参数复位为激活状态，避免污染下一个效果器
        for key, kind, val in ACTIVATE.get(eff, []):
            set_param(h, key, kind, val)
        results.append({
            "effect": eff, "enable": enable_key,
            "baseline_us": base["p50"], "effect_on_us": on["p50"], "effect_on_p95_us": on["p95"],
            "worst_p95_us": worst, "worst_param": worst_param,
            "params": per_param,
        })
        print("%-12s %10.1f %10.1f %10.1f  %s" % (eff, base["p50"], on["p50"], worst, worst_param))

    # 控制侧最慢 set_param（全参数扫描期间记录）
    heavy = sorted(
        ({"param": p["param"], "value": p["value"], "set_us": p["set_us"]}
         for r in results for p in r["params"]),
        key=lambda x: x["set_us"], reverse=True)[:10]
    print("\n-- 最慢 set_param（单次，扫描期间）--")
    for it in heavy:
        print("%-22s %10.4g  %8.1f us" % (it["param"], it["value"], it["set_us"]))

    # 常开增益节点
    print("\n-- 常开增益节点 --")
    for key, lo, hi in [("input.gain", -15.0, 15.0), ("post.gain", -15.0, 15.0)]:
        disable_all(h)
        vals = []
        for v in (lo, 0.0, hi):
            set_param(h, key, "f", v)
            vals.append(measure_block_us(h, blocks=150)["p95"])
        print("%-12s p95: %.1f / %.1f / %.1f us" % (key, vals[0], vals[1], vals[2]))

    lib.auradsp_destroy(h)
    return base, results, heavy


def part2():
    print("\n== Part 2 全链条启动 + 实时调参 ==")
    params = parse_params()
    tunables = [(k, n, lo, hi) for (k, n, lo, hi) in params
                if not n.endswith(".enable") and n not in ("channels.count", "channels.countMode")]

    # 冷启动成本：create → 参数下发 → 首块
    t0 = time.perf_counter_ns()
    h = lib.auradsp_create(SR, N)
    t1 = time.perf_counter_ns()
    disable_all(h)
    prepare_convolver(h)
    for eff, key in ENABLE.items():
        if eff == "ddc":
            continue
        for pkey, kind, val in ACTIVATE.get(eff, []):
            set_param(h, pkey, kind, val)
        set_param(h, key, "i", 1)
    set_param(h, "convolver.enable", "i", 1)
    set_param(h, "limiter.enable", "i", 1)
    t2 = time.perf_counter_ns()
    lib.auradsp_process(h, INT16, OUTBUF, N)
    t3 = time.perf_counter_ns()

    _, effects_csv = get_str(h, "graph.effects")
    create_ms = (t1 - t0) / 1e6
    params_ms = (t2 - t1) / 1e6
    first_ms = (t3 - t2) / 1e6
    print("graph.effects = %s" % effects_csv)
    print("cold start: create=%.3f ms | params=%.2f ms | first block=%.3f ms"
          % (create_ms, params_ms, first_ms))

    # 稳态 + 控制线程实时调参
    stop = threading.Event()
    set_us = []
    set_err = 0
    rnd = random.Random(2026)

    def tuner():
        nonlocal set_err
        while not stop.is_set():
            kind, name, lo, hi = rnd.choice(tunables)
            v = rnd.uniform(lo, hi) if kind == "f" else rnd.randint(int(lo), int(hi))
            a = time.perf_counter_ns()
            rc = set_param(h, name, kind, v)
            set_us.append((time.perf_counter_ns() - a) / 1000.0)
            if rc != 0:
                set_err += 1
            time.sleep(random.uniform(0.001, 0.003))

    # 预热，避免把首块/缓存冷态混进稳态
    for _ in range(200):
        lib.auradsp_process(h, INT16, OUTBUF, N)
    th = threading.Thread(target=tuner, daemon=True)
    th.start()
    blocks = 3000
    times = []
    bad_finite = 0
    peak = 0.0
    t0 = time.perf_counter_ns()
    for i in range(blocks):
        a = time.perf_counter_ns()
        lib.auradsp_process(h, INT16, OUTBUF, N)
        times.append((time.perf_counter_ns() - a) / 1000.0)
        if i % 20 == 0:
            for v in OUTBUF:
                if not math.isfinite(v):
                    bad_finite += 1
                    break
                if abs(v) > peak:
                    peak = abs(v)
    wall_ns = time.perf_counter_ns() - t0
    stop.set()
    th.join(timeout=2.0)

    times.sort()
    set_us.sort()
    audio_ms = blocks * BLOCK_MS
    total_us = sum(times)
    xrun = sum(1 for t in times if t > BLOCK_MS * 1000.0)
    stats = {
        "blocks": blocks,
        "audio_ms": audio_ms,
        "wall_ms": wall_ns / 1e6,
        "cpu_ratio": total_us / 1000.0 / audio_ms,
        "audio_p50_us": times[len(times) // 2],
        "audio_p95_us": times[int(len(times) * 0.95)],
        "audio_p99_us": times[int(len(times) * 0.99)],
        "audio_max_us": times[-1],
        "xrun_proxy": xrun,
        "set_calls": len(set_us),
        "set_err": set_err,
        "set_p50_us": set_us[len(set_us) // 2] if set_us else 0.0,
        "set_p95_us": set_us[int(len(set_us) * 0.95)] if set_us else 0.0,
        "set_p99_us": set_us[int(len(set_us) * 0.99)] if set_us else 0.0,
        "set_max_us": set_us[-1] if set_us else 0.0,
        "nonzero": peak > 1e-4,
        "finite": bad_finite == 0,
        "peak_abs": peak,
    }
    print("稳态 %d 块（音频 %.1fs）：p50=%.1f p95=%.1f p99=%.1f max=%.1f us | CPU %.2f%% | xrun(>10ms)=%d"
          % (blocks, audio_ms / 1000.0, stats["audio_p50_us"], stats["audio_p95_us"],
             stats["audio_p99_us"], stats["audio_max_us"], stats["cpu_ratio"] * 100, xrun))
    print("实时调参 %d 次（rc!=0 %d）：set p50=%.1f p95=%.1f p99=%.1f max=%.1f us | finite=%s peak=%.3f"
          % (len(set_us), set_err, stats["set_p50_us"], stats["set_p95_us"], stats["set_p99_us"],
             stats["set_max_us"], stats["finite"], peak))

    lib.auradsp_destroy(h)
    return stats, {"create_ms": create_ms, "params_ms": params_ms,
                   "first_block_ms": first_ms, "graph_effects": effects_csv}


def main():
    print("DLL: %s" % DLL)
    base, p1, heavy = part1()
    p2, startup = part2()
    out = os.path.join(TMP, "bench_full_chain.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"dll": DLL, "block": N, "sr": SR, "baseline": base,
                   "part1": p1, "heavy_setters": heavy, "part2": p2,
                   "startup": startup}, f, ensure_ascii=False, indent=2)
    print("\nJSON -> %s" % out)


if __name__ == "__main__":
    main()
