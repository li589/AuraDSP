"""smoke_mc_channel_levels.py — ADR-003 Phase B 多声道电平遥测验收（ABI v2）。

设计文档：docs/20-执行/多声道电平PhaseB设计-2026-10-24.md §7 验证矩阵。

覆盖：
  [0] ABI 版本门禁：auradsp_abi() == 2（防 Dart/ctypes 结构体静默错位）
  [1] ch=8 逐声道异幅信号 → channel_levels 逐声道 == 20log10(幅值)
  [2] ch=6 同上
  [3] gate 深门限 → stage_ch[13] 逐声道动态更新、stage_ch[12] 保持输入原值
  [4] filter(LP) 开 → stage_ch[15] 行被真实更新（MC 采样非 stale）
  [5] vendor 段 → stage_ch[0..11][2..7] == -120；[0]/[1] 与 stage_levels_l/r 逐位一致
  [6] GR 槽 → stage_ch[24..29][*] == -120（单值语义）
  [7] stereo 回归（MC→stereo 切换）→ channel_levels[0]/[1] == level_l/r 逐位一致；
      stage_ch[*][0]/[1] == stage_levels_l/r；stage_ch[*][2..7] == -120（无 MC 残留泄漏）

测试信号纪律：逐声道异幅（0.5/2^c）即位置编码——常量同幅信号对结构错误零分辨力。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get(
    "AURADSP_DLL",
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))
if not os.path.exists(DLL):
    print(f"Error: DLL not found at {DLL}")
    sys.exit(1)

STAGE_MAX = 32
CH_MAX = 8
VIZ_BANDS = 32
SR = 48000.0
BLOCK = 512

FAILURES = []


def check(cond, label, detail=""):
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}  {detail}")
        FAILURES.append(label)


class VizFrame(ctypes.Structure):
    _fields_ = [
        ("seq", ctypes.c_uint64),
        ("timestamp_ms", ctypes.c_double),
        ("spectrum", ctypes.c_float * VIZ_BANDS),
        ("eq_in_spectrum", ctypes.c_float * VIZ_BANDS),
        ("level_l_dbfs", ctypes.c_float),
        ("level_r_dbfs", ctypes.c_float),
        ("stage_levels_l", ctypes.c_float * STAGE_MAX),
        ("stage_levels_r", ctypes.c_float * STAGE_MAX),
        ("channel_count", ctypes.c_uint32),
        ("channel_levels", ctypes.c_float * CH_MAX),
        ("stage_ch_levels", ctypes.c_float * (STAGE_MAX * CH_MAX)),
    ]


lib = ctypes.CDLL(DLL)
lib.auradsp_abi.restype = ctypes.c_uint32
lib.auradsp_abi.argtypes = []
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.restype = None
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.restype = None
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_viz_read.restype = ctypes.c_uint32
lib.auradsp_viz_read.argtypes = [ctypes.c_void_p,
                                 ctypes.POINTER(VizFrame), ctypes.c_uint32]


def set_i32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def set_f32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)


def set_str(h, k, s):
    bs = s.encode("utf-8")
    return lib.auradsp_set_param(h, k.encode(), bs, len(bs))


def db(x):
    return 20.0 * math.log10(x) if x > 1e-6 else -120.0


def ch_level(f, stage, ch):
    return f.stage_ch_levels[stage * CH_MAX + ch]


def new_engine():
    h = lib.auradsp_create(SR, BLOCK)
    if not h:
        print("FATAL: auradsp_create failed")
        sys.exit(1)
    return h


# 显式关闭一切可能改动幅值的效果器，保证直通基线。
# （limiter 默认开 —— PARAM 表 limiter_enable{1}，必须显式关。）
OFF_LIST = [
    ("limiter.enable", 0), ("gate.enable", 0), ("filter.enable", 0),
    ("shelf.enable", 0), ("dyneq.enable", 0), ("tube.enable", 0),
    ("exciter.enable", 0), ("loudness.enable", 0), ("haas.enable", 0),
    ("spatial.enable", 0), ("bassmono.enable", 0), ("bass.enable", 0),
    ("reverb.preset", -1), ("convolver.enable", 0), ("ddc.enable", 0),
    ("liveprog.enable", 0), ("arbmag.enable", 0), ("comp.enable", 0),
    ("eq.enable", 0), ("crossfeed.enable", 0),
]


def silence_all(h):
    for k, v in OFF_LIST:
        rc = set_i32(h, k, v)
        assert rc == 0, f"silence_all: {k}={v} rejected (rc={rc})"


def feed(h, ch, amps, blocks):
    """逐声道异幅恒定信号（amps 即位置编码），跑 blocks 块。"""
    inb = (ctypes.c_float * (BLOCK * ch))()
    outb = (ctypes.c_float * (BLOCK * ch))()
    for _ in range(blocks):
        for i in range(BLOCK):
            base = i * ch
            for c in range(ch):
                inb[base + c] = amps[c]
        lib.auradsp_process(h, inb, outb, BLOCK)
    return outb


def read_last_frame(h, maxn=32):
    arr = (VizFrame * maxn)()
    n = lib.auradsp_viz_read(h, arr, maxn)
    if n == 0:
        return None
    return arr[n - 1]


TOL = 0.5  # dB 直通容差


def assert_passthrough_row(f, stage, amps, tol=TOL, label=""):
    ok = True
    for c in range(len(amps)):
        got = ch_level(f, stage, c)
        if abs(got - db(amps[c])) > tol:
            ok = False
            print(f"      stage[{stage}] ch{c}: got {got:.2f} want {db(amps[c]):.2f}")
    check(ok, f"{label}stage_ch[{stage}] 逐声道 == 输入幅值 ±{tol}dB")


# ---------------------------------------------------------------- [0] ABI 门禁
print("=== [0] ABI 版本门禁 ===")
abi = lib.auradsp_abi()
check(abi == 2, "auradsp_abi() == 2", f"got {abi}")
check(ctypes.sizeof(VizFrame) == 1600, "ctypes.sizeof(VizFrame) == 1600",
      f"got {ctypes.sizeof(VizFrame)}")

# ---------------------------------------------------------------- [1] ch=8 基线
print("=== [1] ch=8 逐声道异幅 → per-channel 电平 ===")
h = new_engine()
silence_all(h)
assert set_i32(h, "channels.count", 8) == 0
assert set_i32(h, "channels.mode", 1) == 0  # 1 = 离散多声道链
amps8 = [0.5 / (2 ** c) for c in range(8)]
feed(h, 8, amps8, blocks=8)
f = read_last_frame(h)
check(f is not None, "viz 帧可读")
if f:
    check(f.channel_count == 8, "channel_count == 8", f"got {f.channel_count}")
    ok = True
    for c in range(8):
        if abs(f.channel_levels[c] - db(amps8[c])) > TOL:
            ok = False
            print(f"      ch{c}: got {f.channel_levels[c]:.2f} want {db(amps8[c]):.2f}")
    check(ok, "channel_levels 逐声道 == 20log10(幅值) ±0.5dB")
    assert_passthrough_row(f, 12, amps8, label="输入级 ")
    for st in (13, 14, 15, 18, 19):
        assert_passthrough_row(f, st, amps8)
    # Category B（仅 FL/FR 对）：ch>=2 恒 -120；ch0/1 与 L/R 列一致
    for st in (16, 17, 20):
        okc = all(ch_level(f, st, c) == -120.0 for c in range(2, 8))
        check(okc, f"stage_ch[{st}][2..7] == -120（Category B 作用域诚实）")
        check(abs(ch_level(f, st, 0) - f.stage_levels_l[st]) < 1e-6 and
              abs(ch_level(f, st, 1) - f.stage_levels_r[st]) < 1e-6,
              f"stage_ch[{st}][0]/[1] == stage_levels_l/r[{st}]")
    # vendor 段：仅 FL/FR 两列有效，且与 L/R 列逐位一致
    okv = True
    for i in range(12):
        if ch_level(f, i, 0) != f.stage_levels_l[i] or ch_level(f, i, 1) != f.stage_levels_r[i]:
            okv = False
        for c in range(2, 8):
            if ch_level(f, i, c) != -120.0:
                okv = False
    check(okv, "vendor 段 stage_ch[0..11]：[0]/[1] 逐位一致 + [2..7] 恒 -120")
    # GR 槽：全 -120
    okg = all(ch_level(f, i, c) == -120.0 for i in range(24, 30) for c in range(8))
    check(okg, "GR 槽 stage_ch[24..29][*] == -120（单值语义）")

# ---------------------------------------------------------------- [2] ch=6
print("=== [2] ch=6 逐声道异幅 → per-channel 电平 ===")
assert set_i32(h, "channels.count", 6) == 0
amps6 = [0.5 / (2 ** c) for c in range(6)]
feed(h, 6, amps6, blocks=8)
f = read_last_frame(h)
check(f is not None, "viz 帧可读")
if f:
    check(f.channel_count == 6, "channel_count == 6", f"got {f.channel_count}")
    ok = True
    for c in range(6):
        if abs(f.channel_levels[c] - db(amps6[c])) > TOL:
            ok = False
            print(f"      ch{c}: got {f.channel_levels[c]:.2f} want {db(amps6[c]):.2f}")
    check(ok, "channel_levels 逐声道 == 20log10(幅值) ±0.5dB")
    check(all(f.channel_levels[c] == -120.0 for c in range(6, 8)),
          "channel_levels[6..7] == -120（声道数下降清槽）")
    assert_passthrough_row(f, 12, amps6, label="输入级 ")
    assert_passthrough_row(f, 13, amps6)

# ---------------------------------------------------------------- [3] gate 深门限
print("=== [3] gate 深门限 → stage_ch[13] 动态更新 ===")
assert set_i32(h, "channels.count", 8) == 0
assert set_i32(h, "gate.enable", 1) == 0
assert set_f32(h, "gate.threshold", -30.0) == 0
assert set_f32(h, "gate.range", -80.0) == 0
# ch0 过门（-6dB），ch1 深低于门限（-60dB），其余中等
g_amps = [0.5, 0.001, 0.1, 0.05, 0.05, 0.05, 0.05, 0.05]
feed(h, 8, g_amps, blocks=24)
f = read_last_frame(h)
check(f is not None, "viz 帧可读")
if f:
    ok = all(abs(ch_level(f, 12, c) - db(g_amps[c])) <= TOL for c in range(8))
    check(ok, "stage_ch[12] 保持输入原值（gate 前）")
    check(ch_level(f, 13, 0) >= db(0.5) - 3.0,
          "stage_ch[13][0] 过门不压", f"got {ch_level(f, 13, 0):.2f}")
    check(ch_level(f, 13, 1) <= -70.0,
          "stage_ch[13][1] 深压（range -80dB）", f"got {ch_level(f, 13, 1):.2f}")
    check(abs(ch_level(f, 13, 2) - db(0.1)) <= TOL,
          "stage_ch[13][2] 中等电平不压", f"got {ch_level(f, 13, 2):.2f}")
assert set_i32(h, "gate.enable", 0) == 0

# ---------------------------------------------------------------- [4] filter 行更新
print("=== [4] filter(LP) 开 → stage_ch[15] 行被真实更新 ===")
assert set_i32(h, "filter.enable", 1) == 0
assert set_i32(h, "filter.type", 1) == 0   # LP（对 DC 增益精确 1）
assert set_f32(h, "filter.freq", 1000.0) == 0
feed(h, 8, amps8, blocks=24)
f = read_last_frame(h)
check(f is not None, "viz 帧可读")
if f:
    assert_passthrough_row(f, 15, amps8, tol=1.0, label="filter 后 ")
    check(ch_level(f, 15, 3) != -120.0 or db(amps8[3]) == -120.0,
          "stage_ch[15] 非陈旧值（MC 采样生效）")
assert set_i32(h, "filter.enable", 0) == 0

# ---------------------------------------------------------------- [5][6] 复断言
print("=== [5][6] vendor 段 / GR 槽语义复断言（效果器动过后） ===")
feed(h, 8, amps8, blocks=8)
f = read_last_frame(h)
if f:
    okv = True
    for i in range(12):
        if ch_level(f, i, 0) != f.stage_levels_l[i] or ch_level(f, i, 1) != f.stage_levels_r[i]:
            okv = False
        for c in range(2, 8):
            if ch_level(f, i, c) != -120.0:
                okv = False
    check(okv, "vendor 段 stage_ch[0..11]：[0]/[1] 逐位一致 + [2..7] 恒 -120")
    okg = all(ch_level(f, i, c) == -120.0 for i in range(24, 30) for c in range(8))
    check(okg, "GR 槽 stage_ch[24..29][*] == -120")

# ---------------------------------------------------------------- [7] stereo 回归
print("=== [7] stereo 回归（MC→stereo 切换，无残留泄漏） ===")
assert set_i32(h, "channels.count", 2) == 0
assert set_i32(h, "channels.mode", 0) == 0
st_amps = [0.5, 0.25]
feed(h, 2, st_amps, blocks=8)
f = read_last_frame(h)
check(f is not None, "viz 帧可读")
if f:
    check(f.channel_count == 2, "channel_count == 2", f"got {f.channel_count}")
    check(f.channel_levels[0] == f.level_l_dbfs and f.channel_levels[1] == f.level_r_dbfs,
          "channel_levels[0]/[1] == level_l/r_dbfs（逐位一致）",
          f"{f.channel_levels[0]} vs {f.level_l_dbfs}; {f.channel_levels[1]} vs {f.level_r_dbfs}")
    check(all(f.channel_levels[c] == -120.0 for c in range(2, 8)),
          "channel_levels[2..7] == -120")
    oklr = True
    for i in range(STAGE_MAX):
        if 24 <= i <= 29:
            continue  # GR 槽：设计语义 per-channel 恒 -120（单值计量），不与 L/R 列比较
        if ch_level(f, i, 0) != f.stage_levels_l[i] or ch_level(f, i, 1) != f.stage_levels_r[i]:
            oklr = False
            print(f"      stage {i}: {ch_level(f, i, 0)} vs {f.stage_levels_l[i]}; "
                  f"{ch_level(f, i, 1)} vs {f.stage_levels_r[i]}")
    check(oklr, "stage_ch[*][0]/[1] == stage_levels_l/r（stereo 非 GR 槽逐位一致）")
    okm = all(ch_level(f, i, c) == -120.0 for i in range(STAGE_MAX) for c in range(2, 8))
    check(okm, "stage_ch[*][2..7] == -120（MC 残留不泄漏进 stereo 帧）")

lib.auradsp_destroy(h)

# ---------------------------------------------------------------- 汇总
print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} 项未过")
    for x in FAILURES:
        print(f"  - {x}")
    sys.exit(1)
print("ALL PASS: 多声道电平 Phase B 遥测验收全部通过")
