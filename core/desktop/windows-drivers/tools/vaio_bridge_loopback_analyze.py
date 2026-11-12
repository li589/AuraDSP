#!/usr/bin/env python3
# vaio_bridge_loopback_analyze.py — 环回录制的频谱判读（配套
# vaio_bridge_loopback_check.cpp 的 .raw 输出）。
#
# 判读口径（第十七轮定型）：探针送的是幅值 0.5 的纯正弦，落点录回后——
#   纯净：目标频点分量 ≈ 0.5、ac1（一阶自相关）≈ 0.99、谐波点接近 0；
#   被破坏：目标分量塌陷、高频谐波簇（如 11k/19k）冒头、ac1 转负、
#           相邻采样最大跳变接近满幅。
# 本脚本只做数值判读，不下结论；结论要结合录制场次的上下文（见第十七轮
# 收口文档里两场脚手架污染的教训）。
#
# 用法：
#   python vaio_bridge_loopback_analyze.py <raw文件> [--rate 48000] [--ch 2]
#       [--freq 1000] [--windows 0.5-3,4-8] [--buckets 60]
#   --windows  逗号分隔的秒区间，逐窗打印细判；
#   --buckets  把前 N 秒按 1 秒打印 RMS 总览（找声音何时出现/消失）。
import argparse
import math
import struct
import sys


def goertzel(data, freq, rate):
    w = 2 * math.pi * freq / rate
    coeff = 2 * math.cos(w)
    s1 = s2 = 0.0
    for x in data:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return math.sqrt(max(power, 0.0)) / len(data) * 2


def window_stats(seg, rate, freq):
    peak = max(abs(x) for x in seg)
    rms = math.sqrt(sum(x * x for x in seg) / len(seg))
    blk = seg[500:4596] if len(seg) > 5096 else seg
    n = min(len(seg) - 1, 20000)
    denom = max(sum(x * x for x in seg[: n + 1]), 1e-12)
    ac1 = sum(seg[i] * seg[i + 1] for i in range(n)) / denom
    step = max(abs(seg[i + 1] - seg[i]) for i in range(min(len(seg) - 1, 50000)))
    return {
        "peak": peak,
        "rms": rms,
        "target": goertzel(blk, freq, rate),
        "h11k": goertzel(blk, 11000, rate),
        "h19k": goertzel(blk, 19000, rate),
        "ac1": ac1,
        "maxstep": step,
    }


def main():
    ap = argparse.ArgumentParser(description="VAIO bridge loopback raw analyzer")
    ap.add_argument("raw")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--ch", type=int, default=2)
    ap.add_argument("--freq", type=float, default=1000.0)
    ap.add_argument("--windows", default="1-3,3-5")
    ap.add_argument("--buckets", type=int, default=0)
    args = ap.parse_args()

    data = open(args.raw, "rb").read()
    samples = struct.unpack("<%df" % (len(data) // 4), data)
    frames = len(samples) // args.ch
    print(f"frames={frames} dur={frames / args.rate:.2f}s ch={args.ch} rate={args.rate}")
    left = samples[0::args.ch]

    if args.buckets > 0:
        for s in range(min(args.buckets, int(frames / args.rate))):
            seg = left[s * args.rate:(s + 1) * args.rate]
            rms = math.sqrt(sum(x * x for x in seg) / len(seg))
            print(f"{s:4d}s rms={rms:.3f} {'#' * int(rms * 60)}")
        return

    for w in args.windows.split(","):
        t0, t1 = (float(v) for v in w.split("-"))
        seg = left[int(args.rate * t0):int(args.rate * t1)]
        if len(seg) < 5000:
            print(f"[{t0}-{t1}s] too short")
            continue
        st = window_stats(seg, args.rate, args.freq)
        print(
            f"[{t0}-{t1}s] peak={st['peak']:.3f} rms={st['rms']:.3f} "
            f"target@{args.freq:.0f}Hz={st['target']:.4f} "
            f"11k={st['h11k']:.4f} 19k={st['h19k']:.4f} "
            f"ac1={st['ac1']:.3f} maxstep={st['maxstep']:.3f}"
        )


if __name__ == "__main__":
    sys.exit(main())
