#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
cal2vdc.py — 麦克风 / 声卡校准曲线 → AuraDSP VDC 文件转换器

把第三方校准数据（频率-幅度表）拟合为级联二阶节（biquad peaking）滤波器，
输出 libjamesdsp / ViPER DDC 兼容的 .vdc 文件。

支持的输入格式（自动识别，无需手工指定）：
  1. REW / LUOLAN 导出：制表符分隔，4 列 Frequency/Magnitude/Phase/Coherence
  2. Studio Six Digital：'*' 注释头 + "freq, dB" CSV
  3. MATAA：'%' 注释 + name=/type=/sensitivity= 元数据 + 制表符两列

依赖：numpy, scipy（本仓 Python 3.12 已具备）

用法示例：
  python tools/calibration/cal2vdc.py ^
      --in "D:/temp_desktop/Proj/校准" ^
      --out "D:/temp_desktop/Proj/校准/Output" ^
      --sections 8 --polarity compensate

  # 单文件，指定品牌型号
  python tools/calibration/cal2vdc.py --in FILE.txt --brand BEHRINGER --model "ECM8000"

  # 审计：回读已有 VDC，报告其频率响应（验证系数符号约定）
  python tools/calibration/cal2vdc.py --inspect assets/ddc/AKG/AKG\ K240.vdc
"""

import argparse
import csv
import json
import math
import os
import re
import sys

try:
    import numpy as np
    from scipy.optimize import least_squares
except ImportError as e:
    sys.stderr.write(
        "缺少依赖：%s\n请安装：python -m pip install numpy scipy\n"
        "（本仓 Python 3.12 位于 C:\\Program Files\\Python\\Python312\\python.exe）\n" % e
    )
    sys.exit(2)

TARGET_RATES = (44100, 48000)
# 单个 peaking 的增益上下限（dB）。超出会显著放大噪声并可能推爆后级
DEFAULT_MAX_GAIN = 24.0


# ---------------------------------------------------------------- 输入解析

_NUM_START = tuple("0123456789.-+")
# 分隔符必须包含空格：MATAA 大量文件用等宽空格对齐（"15          0"），
# 只认 tab/逗号会让这整个库 57/61 解析为空。
_SPLIT_RE = re.compile(r"[\s,;]+")


class NoDataError(Exception):
    """文件里没有可拟合的数据（非解析故障，属文件本身性质）。"""
    pass


def read_curve(path):
    """读取校准表，返回 (freqs, mags_db, meta)。

    规则：只有以数字开头的行才可能是数据；取该行前两个可解析为 float 的字段。
    这样可同时吃掉 REW 表头、MATAA 的 name=/type=/sensitivity= 元数据行、
    Studio Six 的 '*' 注释头，无需为每种格式写分支。
    """
    freqs, mags = [], []
    meta = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fp:
        raw_text = fp.read()
    for raw in raw_text.splitlines():
        line = raw.strip()
        if not line or not line.startswith(_NUM_START):
            # 顺带捞取 MATAA 风格的元数据，用于品牌/型号推断
            if "=" in line and not line.startswith(("*", "%", "#")):
                k, _, v = line.partition("=")
                # MATAA 用制表符把取值与行尾注释分开（"name = X \t % 说明"），
                # 不剥离会把整段注释当成型号名，进而生成非法文件名。
                v = v.split("\t")[0].split("%")[0].split("#")[0].strip()
                if v:
                    meta[k.strip().lower()] = v
            continue
        parts = [p.strip() for p in _SPLIT_RE.split(line) if p.strip()]
        vals = []
        for p in parts:
            try:
                vals.append(float(p))
            except ValueError:
                break  # 遇到非数字列（如单位）即停止，不跨列拼凑
        if len(vals) < 2:
            continue
        f, m = vals[0], vals[1]
        if f <= 0 or not math.isfinite(f) or not math.isfinite(m):
            continue
        freqs.append(f)
        mags.append(m)

    if len(freqs) == 0:
        # 区分"文件本身没数据"与"解析失败"，避免把性质问题伪装成故障
        low = raw_text.lower()
        if re.search(r"(notes|readme|license|integration)", os.path.basename(path), re.I):
            raise NoDataError("说明文档，非校准数据")
        if "sensitivity" in meta:
            raise NoDataError("只有元数据、无传输函数（MATAA 中即视为平直）")
        if re.search(r"^\s*file\s*=", raw_text, re.M | re.I):
            raise NoDataError("MATAA 组合式 chain 文件，只引用其它 .txt，自身无数据")
        if "no transfer function" in low or ("flat" in low and "transfer" in low):
            raise NoDataError("文件声明响应平直，未收录传输函数数据")
        raise NoDataError("未识别到数据行")
    if len(freqs) < 4:
        if max(abs(v) for v in mags) < 0.05:
            raise NoDataError("仅 %d 个数据点且全为 0 dB（平直定义），无需滤波" % len(freqs))
        raise ValueError("有效数据点不足（%d 个），无法拟合" % len(freqs))

    order = np.argsort(np.asarray(freqs, dtype=float))
    f = np.asarray(freqs, dtype=float)[order]
    m = np.asarray(mags, dtype=float)[order]
    # 同一频点重复取平均，避免插值抖动
    keep_f, keep_m = [], []
    i = 0
    while i < len(f):
        j = i
        while j + 1 < len(f) and f[j + 1] == f[i]:
            j += 1
        keep_f.append(f[i])
        keep_m.append(m[i:j + 1].mean())
        i = j + 1
    return np.asarray(keep_f), np.asarray(keep_m), meta


# ---------------------------------------------------------------- 目标曲线

def smooth_curve(freqs, mags, octaves):
    """对数频率域的分数倍频程平滑。

    实测校准曲线（尤其是消费级测量麦克风）在高频常有 ±2 dB 的相干性噪声纹波，
    直接拟合会让优化器用大增益 + 大 Q 去追噪声——节数越多过拟合越严重
    （实测 10 节时峰增益从 6 dB 飙到 16.6 dB，而 RMS 只降 0.01 dB）。
    先平滑再拟合是声学测量的常规做法。0 表示不平滑。
    """
    if not octaves or octaves <= 0:
        return mags
    lf = np.log2(freqs)
    half = octaves / 2.0
    out = np.empty_like(mags)
    for i in range(len(freqs)):
        sel = np.abs(lf - lf[i]) <= half
        out[i] = mags[sel].mean()
    return out

def build_target(freqs, mags, fs, npts=240):
    """把离散校准点变成待拟合的目标曲线（对数频率网格，两端 taper 到 0 dB）。

    peaking 滤波器在 DC 与 Nyquist 处增益恒为 0 dB，因此目标曲线两端必须
    收敛到 0，否则拟合会被迫在端点产生巨大误差——这与库中既有 VDC
    （DC 处增益为 0）的行为一致。
    """
    nyq = fs / 2.0
    f_lo = float(freqs.min())
    f_hi = float(min(freqs.max(), nyq * 0.98))
    if f_hi <= f_lo * 1.05:
        raise ValueError("数据频率范围过窄或全部超出 Nyquist")

    lo0, lo1 = max(f_lo * 0.5, 1.0), f_lo
    grid = np.logspace(math.log10(lo0), math.log10(nyq), npts)
    mag = np.interp(np.log10(grid), np.log10(freqs), mags)

    w = np.ones_like(grid)
    m_low = grid < lo1
    if m_low.any():
        t = (np.log10(grid[m_low]) - math.log10(lo0)) / (math.log10(lo1) - math.log10(lo0))
        w[m_low] = 0.5 * (1.0 - np.cos(np.pi * np.clip(t, 0.0, 1.0)))
    m_hi = grid > f_hi
    if m_hi.any():
        t = 1.0 - (np.log10(grid[m_hi]) - math.log10(f_hi)) / (math.log10(nyq) - math.log10(f_hi))
        w[m_hi] = 0.5 * (1.0 - np.cos(np.pi * np.clip(t, 0.0, 1.0)))

    # 拟合权重：taper 区是为满足 peaking 端点特性而人为构造的，真实数据不存在，
    # 权重压低——否则优化器会为了迎合端点牺牲数据区精度，且 RMS 会被伪影污染。
    fit_w = np.where((grid >= f_lo) & (grid <= f_hi), 1.0, 0.15)
    return grid, mag * w, (f_lo, f_hi), fit_w


# ---------------------------------------------------------------- peaking 滤波器

def peaking_coeffs(fs, gain_db, fc, q):
    """RBJ peaking（Audio EQ Cookbook），返回归一化 [b0,b1,b2,a1,a2]，a0=1。"""
    a = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * fc / fs
    alpha = math.sin(w0) / (2.0 * q)
    cw = math.cos(w0)
    b0 = 1.0 + alpha * a
    b1 = -2.0 * cw
    b2 = 1.0 - alpha * a
    a0 = 1.0 + alpha / a
    a1 = -2.0 * cw
    a2 = 1.0 - alpha / a
    return np.array([b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0])


def peaking_db(f, fs, gain_db, fc, q):
    """peaking 滤波器在频率 f 处的幅度响应（dB）。"""
    b0, b1, b2, a1, a2 = peaking_coeffs(fs, gain_db, fc, q)
    w = 2.0 * math.pi * f / fs
    c1, s1 = np.cos(w), np.sin(w)
    c2, s2 = np.cos(2 * w), np.sin(2 * w)
    nr = b0 + b1 * c1 + b2 * c2
    ni = -(b1 * s1 + b2 * s2)
    dr = 1.0 + a1 * c1 + a2 * c2
    di = -(a1 * s1 + a2 * s2)
    return 20.0 * np.log10(np.sqrt(nr * nr + ni * ni) / np.sqrt(dr * dr + di * di) + 1e-30)


def cascade_db(f, fs, params):
    """params: (N,3) 数组 [gain_db, fc, q]；级联响应的 dB 值。"""
    total = np.zeros_like(np.asarray(f, dtype=float))
    for gain_db, fc, q in params:
        total += peaking_db(f, fs, gain_db, fc, q)
    return total


# ---------------------------------------------------------------- 拟合

def fit_peaks(grid, target_db, fit_w, fs, nsec, max_gain, seed=0):
    """在给定采样率网格上拟合 nsec 个 peaking。

    返回 (params, weighted_rms, weighted_maxerr)。
    加权：taper 区权重低（见 build_target），残差以权重平方计入。
    """
    rng = np.random.default_rng(seed)
    f_lo, f_hi = float(grid.min()), float(grid.max())
    nyq = fs / 2.0
    fc_hi = min(f_hi, nyq * 0.95)
    sq = np.sqrt(fit_w)

    def unpack(x):
        g = x[:nsec]
        fc = 10.0 ** x[nsec:2 * nsec]
        q = 10.0 ** x[2 * nsec:]
        return np.column_stack([g, fc, q])

    def resid(x):
        return (cascade_db(grid, fs, unpack(x)) - target_db) * sq

    best = None
    # 两组初值：确定性对数均布 + 轻微扰动，取较优者，避免陷在局部极小
    for attempt in range(2):
        fc0 = np.geomspace(max(f_lo * 1.05, 20.0), fc_hi, nsec)
        if attempt:
            fc0 = np.clip(fc0 * (1.0 + 0.25 * rng.standard_normal(nsec)), 20.0, fc_hi)
        q0 = np.full(nsec, 1.2)
        x0 = np.concatenate([np.zeros(nsec), np.log10(fc0), np.log10(q0)])
        lo = np.concatenate([np.full(nsec, -max_gain),
                             np.full(nsec, math.log10(10.0)),
                             np.full(nsec, math.log10(0.2))])
        hi = np.concatenate([np.full(nsec, max_gain),
                             np.full(nsec, math.log10(fc_hi)),
                             np.full(nsec, math.log10(30.0))])
        sol = least_squares(resid, x0, bounds=(lo, hi), method="trf",
                            xtol=1e-12, ftol=1e-12, max_nfev=4000)
        r = resid(sol.x) / sq  # 还原为 dB 残差便于解读
        rms = float(np.sqrt(np.average(r * r, weights=fit_w)))
        if best is None or rms < best[1]:
            best = (unpack(sol.x), rms, float(np.max(np.abs(r))))
    return best


# ---------------------------------------------------------------- VDC 输出

def _fmt(v):
    if v == 0.0:
        v = 0.0  # 消除 -0.0
    s = "%.15g" % v
    return s


def build_vdc_text(params):
    """params: (N,3)。生成 VDC 文本。

    格式：SR_44100:b0,b1,b2,a1,a2,...,SR_48000:...
    系数符号：引擎 DDCParser 对 a1/a2 **取负**后存入 DirectForm2，
    因此这里写出的是标准 biquad 分母系数的相反数（a_out = -a_scipy）。
    SR_44100 必须在前：DDCParser 用 SR_48000 之后的逗号总数反推节数，
    若 48000 段在前会把两段逗号一起数进去，节数翻倍。
    """
    segs = []
    for fs in TARGET_RATES:
        nums = []
        for gain_db, fc, q in params:
            b0, b1, b2, a1, a2 = peaking_coeffs(fs, float(gain_db), float(fc), float(q))
            nums.extend([_fmt(b0), _fmt(b1), _fmt(b2), _fmt(-a1), _fmt(-a2)])
        segs.append("SR_%d:%s" % (fs, ",".join(nums)))
    return ",".join(segs)


# ---------------------------------------------------------------- 回读校验

def parse_vdc(path):
    """按引擎 DDCParser 的语义解析 VDC，返回 {fs: (N,5) 系数}（已还原符号）。"""
    with open(path, "r", encoding="utf-8", errors="replace") as fp:
        text = fp.read()
    out = {}
    for rate in TARGET_RATES:
        key = "SR_%d" % rate
        idx = text.find(key)
        if idx < 0:
            continue
        seg = text[idx + len(key) + 1:]
        nxt = seg.find("SR_")
        if nxt >= 0:
            seg = seg[:nxt]
        vals = [float(x) for x in seg.replace(";", ",").split(",") if x.strip()]
        if len(vals) % 5:
            raise ValueError("%s 段系数个数 %d 不是 5 的倍数" % (key, len(vals)))
        arr = np.asarray(vals, dtype=float).reshape(-1, 5)
        arr[:, 3] = -arr[:, 3]  # 还原 a1
        arr[:, 4] = -arr[:, 4]  # 还原 a2
        out[rate] = arr
    return out


def sos_cascade_db(f, fs, sos):
    """按引擎实际运算路径计算级联响应（用于校验生成结果）。"""
    total = np.zeros_like(np.asarray(f, dtype=float))
    w = 2.0 * math.pi * np.asarray(f, dtype=float) / fs
    c1, s1 = np.cos(w), np.sin(w)
    c2, s2 = np.cos(2 * w), np.sin(2 * w)
    for b0, b1, b2, a1, a2 in sos:
        nr = b0 + b1 * c1 + b2 * c2
        ni = -(b1 * s1 + b2 * s2)
        dr = 1.0 + a1 * c1 + a2 * c2
        di = -(a1 * s1 + a2 * s2)
        total += 20.0 * np.log10(np.sqrt(nr * nr + ni * ni) / np.sqrt(dr * dr + di * di) + 1e-30)
    return total


# ---------------------------------------------------------------- 命名

_KNOWN_BRANDS = [
    "BEHRINGER", "BEYERDYNAMIC", "EARTHWORKS", "ISEMCON", "SENNHEISER",
    "NEUROCHROME", "RTX", "STUDIOSIX", "STUDIO SIX", "MINIDSP", "DAYTON",
    "AUDIX", "DPA", "SCHOEPS", "NEUMANN", "AKG", "SHURE", "SONY",
]
_TAIL_TAGS = {"MICROPHONE", "MIC", "ADC", "DAC", "SOUNDCARD", "HEADPHONEOUT",
              "LINEIN", "LINEOUT", "MICIN", "CHAIN", "DUT", "REF", "SENSOR"}


def guess_names(path, meta, brand=None, model=None):
    stem = os.path.splitext(os.path.basename(path))[0]
    if model:
        m = model
    else:
        m = stem
        # MATAA 风格：BRAND_MODEL_SN_TYPE → 去掉尾部类型标签
        parts = [p for p in re.split(r"[_\-]+", m) if p]
        while len(parts) > 2 and parts[-1].upper() in _TAIL_TAGS:
            parts.pop()
        m = " ".join(parts)
    if brand:
        b = brand
    else:
        b = None
        up = stem.upper()
        for kb in _KNOWN_BRANDS:
            if up.startswith(kb) or kb in up:
                b = kb.title() if not kb.isupper() else kb
                break
        if b is None:
            b = (meta.get("name", stem)[:24].strip() or "Calibration")
    # Windows 文件名禁用的字符，另含制表符/换行
    b = re.sub(r'[\\/:*?"<>|\t\r\n]', " ", b)
    return b, m


# ---------------------------------------------------------------- 主流程

def convert_one(src, outdir, nsec, polarity, max_gain, offset_db, brand, model,
                norm_ref, smooth, report_rows):
    freqs, mags, meta = read_curve(src)
    name_hint = meta.get("name", "")
    b, m = guess_names(src, meta, brand, model)

    if smooth and smooth > 0:
        mags = smooth_curve(freqs, mags, smooth)
    if polarity == "compensate":
        mags = -mags
    if norm_ref and norm_ref > 0:
        ref = float(np.interp(math.log10(norm_ref), np.log10(freqs), mags))
        mags = mags - ref
    if offset_db:
        mags = mags + offset_db

    grid, target, (f_lo, f_hi), fit_w = build_target(freqs, mags, TARGET_RATES[0])
    params, rms, maxerr = fit_peaks(grid, target, fit_w, TARGET_RATES[0], nsec, max_gain)

    text = build_vdc_text(params)
    safe_b = re.sub(r'[\\/:*?"<>|\t\r\n]', " ", b).strip() or "Others"
    safe_m = re.sub(r'[\\/:*?"<>|\t\r\n]', " ", m).strip()
    dst_dir = os.path.join(outdir, "ddc", safe_b)
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, safe_m + ".vdc")
    with open(dst, "w", encoding="utf-8", newline="\n") as fp:
        fp.write(text)

    # 独立回读校验：确认写出的文件能被 DDCParser 语义正确还原
    parsed = parse_vdc(dst)
    check = ""
    if TARGET_RATES[0] in parsed:
        got = sos_cascade_db(grid, TARGET_RATES[0], parsed[TARGET_RATES[0]])
        err = np.abs(got - target)
        data_rms = float(np.sqrt(np.average((err ** 2)[fit_w >= 1.0], axis=0))) \
            if (fit_w >= 1.0).any() else float("nan")
        check_rms = float(np.sqrt(np.average(err ** 2, weights=fit_w)))
        check = "回读 %.3f / 数据区 %.3f dB" % (check_rms, data_rms)
        if check_rms > rms + 0.05:
            check += " [WARN: 回读偏差大于拟合误差]"
        data_err_db = round(data_rms, 3)
    else:
        data_err_db = None
    n44 = parsed.get(TARGET_RATES[0], np.zeros((0, 5))).shape[0]
    n48 = parsed.get(TARGET_RATES[1], np.zeros((0, 5))).shape[0]

    peak = float(np.max(np.abs(params[:, 0])))
    if peak >= max_gain * 0.98:
        check += " [WARN: 增益撞上限，疑似过拟合]"
    row = {
        "file": os.path.relpath(dst, outdir).replace("\\", "/"),
        "source": os.path.basename(src),
        "brand": safe_b,
        "model": safe_m,
        "points": int(len(freqs)),
        "range_hz": "%.1f-%.1f" % (f_lo, f_hi),
        "sections": int(len(params)),
        "parsed_44k_48k": "%d/%d" % (n44, n48),
        "rms_db": round(rms, 3),
        "data_rms_db": data_err_db,
        "max_err_db": round(maxerr, 3),
        "peak_gain_db": round(peak, 2),
        "peak_q": round(float(np.max(params[:, 2])), 2),
        "smooth_oct": smooth or 0,
        "polarity": polarity,
        "roundtrip": check,
        "name_hint": name_hint,
    }
    report_rows.append(row)
    return row


def inspect(path):
    parsed = parse_vdc(path)
    print("文件: %s" % path)
    for rate in TARGET_RATES:
        if rate not in parsed:
            print("  SR_%d: 缺失" % rate)
            continue
        sos = parsed[rate]
        print("  SR_%d: %d 节" % (rate, sos.shape[0]))
        grid = np.logspace(math.log10(10), math.log10(rate / 2.0 * 0.999), 24)
        db = sos_cascade_db(grid, rate, sos)
        print("    频点响应(dB):")
        for f, v in zip(grid, db):
            print("      %9.1f Hz  %+7.2f" % (f, v))
        # 稳定性：极点是否在单位圆内
        unstable = 0
        for b0, b1, b2, a1, a2 in sos:
            disc = a1 * a1 - 4 * a2
            if disc >= 0:
                r1 = (-a1 + math.sqrt(disc)) / 2.0
                r2 = (-a1 - math.sqrt(disc)) / 2.0
                if max(abs(r1), abs(r2)) >= 1.0:
                    unstable += 1
            else:
                if abs(a2) >= 1.0:
                    unstable += 1
        print("    极点模：%s" % ("全部在单位圆内" if unstable == 0 else "%d 节不稳定!" % unstable))


def main():
    ap = argparse.ArgumentParser(description="校准曲线 → AuraDSP VDC 转换器")
    ap.add_argument("--in", dest="inp", default=None,
                    help="输入文件或目录（目录会递归扫描 .txt）")
    ap.add_argument("--out", dest="out", default=None,
                    help="输出根目录，默认 <输入目录>/Output，内部按 ddc/<Brand>/ 组织")
    ap.add_argument("--sections", type=int, default=8,
                    help="二阶节数量，默认 8（库内既有文件主流为 5）")
    ap.add_argument("--polarity", choices=["compensate", "raw"], default="compensate",
                    help="compensate=取反（把测得响应变成补偿曲线，默认）；raw=原样使用")
    ap.add_argument("--max-gain", type=float, default=DEFAULT_MAX_GAIN,
                    help="单节增益上限 dB，默认 24")
    ap.add_argument("--offset-db", type=float, default=0.0,
                    help="整体增益偏置 dB")
    ap.add_argument("--norm-ref", type=float, default=0.0,
                    help="把该频点（Hz）的增益归零，0=不归一")
    ap.add_argument("--smooth", type=float, default=0.0,
                    help="先对源曲线做分数倍频程平滑（如 0.083=1/12 oct），抑制测量纹波，0=不平滑")
    ap.add_argument("--brand", default=None, help="覆盖品牌名")
    ap.add_argument("--model", default=None, help="覆盖型号名")
    ap.add_argument("--inspect", dest="inspect_path", default=None,
                    help="审计模式：回读已有 VDC 并打印响应，不做转换")
    args = ap.parse_args()

    if args.inspect_path:
        inspect(args.inspect_path)
        return 0
    if not args.inp:
        ap.error("需要 --in（转换模式）或 --inspect（审计模式）")

    src = args.inp
    if os.path.isdir(src):
        files = []
        for root, _, names in os.walk(src):
            for n in sorted(names):
                if n.lower().endswith(".txt"):
                    files.append(os.path.join(root, n))
        files.sort()
    else:
        files = [src]
    if not files:
        sys.stderr.write("未找到输入文件\n")
        return 1

    outdir = args.out or (src if os.path.isdir(src) else os.path.dirname(src))
    outdir = os.path.join(outdir, "Output") if args.out is None else outdir
    os.makedirs(outdir, exist_ok=True)

    rows = []
    skipped = []
    ok = fail = 0
    for f in files:
        try:
            row = convert_one(f, outdir, args.sections, args.polarity, args.max_gain,
                              args.offset_db, args.brand, args.model, args.norm_ref,
                              args.smooth, rows)
            ok += 1
            print("OK   %-52s 节=%d RMS=%.3f dB 峰增益=%.1f dB  %s"
                  % (row["file"], row["sections"], row["rms_db"],
                     row["peak_gain_db"], row["roundtrip"]))
        except NoDataError as e:
            skipped.append((os.path.basename(f), str(e)))
        except Exception as e:
            fail += 1
            print("FAIL %-52s %s" % (os.path.basename(f), e))

    if rows:
        rep = os.path.join(outdir, "conversion_report.csv")
        # 多次运行合并：同 file 的旧记录被本次覆盖，其余保留
        old = []
        if os.path.exists(rep):
            with open(rep, "r", encoding="utf-8-sig", newline="") as fp:
                old = [r for r in csv.DictReader(fp)]
        merged = {r["file"]: r for r in old}
        for r in rows:
            merged[r["file"]] = r
        fieldnames = list(rows[0].keys())
        for r in old:
            for k in r:
                if k not in fieldnames:
                    fieldnames.append(k)
        with open(rep, "w", encoding="utf-8-sig", newline="") as fp:
            w = csv.DictWriter(fp, fieldnames=fieldnames, extrasaction="ignore")
            w.writeheader()
            for r in merged.values():
                w.writerow(r)
        print("\n报告: %s（累计 %d 条）" % (rep, len(merged)))
    if skipped:
        print("\n跳过（文件本身无可拟合数据，非解析故障）:")
        for n, why in skipped:
            print("  - %-52s %s" % (n, why))
    print("\n完成: 成功 %d，跳过 %d，失败 %d；输出目录 %s"
          % (ok, len(skipped), fail, outdir))
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
