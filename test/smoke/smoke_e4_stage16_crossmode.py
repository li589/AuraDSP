# -*- coding: utf-8 -*-
"""smoke_e4_stage16_crossmode.py — E4 门禁：viz Stage 16 采样点跨模式同语义。

缺陷（审查 E4）：同一 "BassMono" 槽（viz stage 16）在两种链模式量的是**不同
链位置**——

    MC     process_multichannel_chain：bassmono → basspsycho → 采样   （采晚了）
    stereo process_stereo_chain     ：bassmono → 采样 → basspsycho     （本来就对）

切模式时该柱跳变，违反「同槽同语义」；且 auradsp_engine.h 文档写的是
「16: bassmono 低频单声道输出电平」，采在 basspsycho 之后会把心理声学低音的
增益算进 BassMono 柱——槽名失真。

修法（P-026）：MC 采样点挪到 bassmono 与 basspsycho **之间**。选 MC 向文档
语义收敛而不是 stereo 挪后：stereo 的柱一直是 BassMono 输出（smoke_chain_meter
的 20 级表也按此标定），反向改会连带变掉既有读数语义。

本测试的判红原理：采样点在 basspsycho 之前 ⇔ **basspsycho 开/关两态下
stage 16 读数必须相等**（采样发生在 basspsycho 改写缓冲之前，同一输入下逐位
一致）。pre-fix 的 MC 侧 basspsycho 会先放大 60Hz 再被采样 → 两态读数必然
分叉 → 该断言在 pre-fix 判红（反向验证已实测）。

辅以非空转证明：basspsycho 开/关两态的最终输出 RMS 必须可测地不同——否则
"两态相等"可能只是 basspsycho 压根没生效的假绿。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get(
    "AURADSP_DLL",
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                 "auradsp_engine.dll"))
if not os.path.exists(DLL):
    print("Error: DLL not found at %s" % DLL)
    sys.exit(1)

# --- VizFrame 单一来源（§7-1 ABI 镜像门禁）---
# ctypes 镜像只在 tools/bin/viz_frame.py 定义一次，这里不再手抄。
_VIZ_ROOT = os.path.dirname(os.path.abspath(__file__))
while not os.path.isfile(os.path.join(_VIZ_ROOT, 'tools', 'bin', 'viz_frame.py')):
    _VIZ_PARENT = os.path.dirname(_VIZ_ROOT)
    if _VIZ_PARENT == _VIZ_ROOT:
        raise ImportError('未找到 tools/bin/viz_frame.py（VizFrame 的唯一定义处）')
    _VIZ_ROOT = _VIZ_PARENT
if os.path.join(_VIZ_ROOT, 'tools', 'bin') not in sys.path:
    sys.path.insert(0, os.path.join(_VIZ_ROOT, 'tools', 'bin'))
from viz_frame import VizFrame  # noqa: E402

SR = 48000.0
BLOCK = 512
CH_MAX = 8
FREQ = 60.0          # basspsycho 的作用频段
AMP = 0.5
BASS_GAIN = 9.0      # bass.gain（0..15dB），取大值让两态差异远超浮点噪声
TOL_DB = 1e-4        # 同一确定性计算，两态读数应逐位一致；留浮点余量

lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_viz_read.restype = ctypes.c_uint32
lib.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(VizFrame),
                                 ctypes.c_uint32]

fails = []
passes = 0


def check(name, ok, note=""):
    global passes
    if ok:
        passes += 1
        print("PASS  %s%s" % (name, ("  (%s)" % note) if note else ""))
    else:
        fails.append(name)
        print("FAIL  %s%s" % (name, ("  (%s)" % note) if note else ""))


def set_i32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def set_f32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)


OFF_LIST = [
    ("limiter.enable", 0), ("gate.enable", 0), ("filter.enable", 0),
    ("shelf.enable", 0), ("dyneq.enable", 0), ("tube.enable", 0),
    ("exciter.enable", 0), ("loudness.enable", 0), ("haas.enable", 0),
    ("spatial.enable", 0), ("bassmono.enable", 0), ("bass.enable", 0),
    ("reverb.preset", -1), ("convolver.enable", 0), ("ddc.enable", 0),
    ("liveprog.enable", 0), ("arbmag.enable", 0), ("comp.enable", 0),
    ("eq.enable", 0), ("crossfeed.enable", 0), ("stereo.enable", 0),
]


def silence_all(h):
    for k, v in OFF_LIST:
        rc = set_i32(h, k, v)
        assert rc == 0, "silence_all: %s=%d rejected (rc=%d)" % (k, v, rc)


def blk_ptr(buf, b, ch):
    """第 b 块起始地址 → POINTER(c_float)（byref 保型，argtypes 不认）。"""
    addr = ctypes.addressof(buf) + b * BLOCK * ch * 4
    return ctypes.cast(addr, ctypes.POINTER(ctypes.c_float))


def make_signal(ch, blocks):
    """FL/FR 60Hz 正弦（相位连续，不重用块缓冲），其余声道静音。"""
    n = BLOCK * blocks
    buf = (ctypes.c_float * (n * ch))()
    w = 2.0 * math.pi * FREQ / SR
    for i in range(n):
        v = AMP * math.sin(w * i)
        base = i * ch
        buf[base + 0] = v
        if ch > 1:
            buf[base + 1] = v
    return buf


def run_case(h, mode, bass_on):
    """返回 (stage16_l_max_db, stage_ch16_0_max_db, out_rms)。"""
    silence_all(h)
    assert set_i32(h, "bassmono.enable", 1) == 0
    assert set_f32(h, "bassmono.freq", 120.0) == 0
    assert set_i32(h, "bass.enable", 1 if bass_on else 0) == 0
    assert set_f32(h, "bass.gain", BASS_GAIN) == 0
    if mode == "mc":
        assert set_i32(h, "channels.count", 8) == 0
        assert set_i32(h, "channels.mode", 1) == 0
    else:
        assert set_i32(h, "channels.count", 2) == 0
        assert set_i32(h, "channels.mode", 0) == 0
    ch = 8 if mode == "mc" else 2

    # 预热 + 排空 viz 环（丢弃切换参数前的旧帧）
    warm = make_signal(ch, 8)
    out = (ctypes.c_float * (BLOCK * ch))()
    for b in range(8):
        lib.auradsp_process(h, blk_ptr(warm, b, ch), out, BLOCK)
    drain = (VizFrame * 32)()
    while lib.auradsp_viz_read(h, drain, 32) > 0:
        pass

    # 正式测量段
    sig = make_signal(ch, 12)
    rms_acc = 0.0
    rms_n = 0
    for b in range(12):
        lib.auradsp_process(h, blk_ptr(sig, b, ch), out, BLOCK)
        for i in range(BLOCK * ch):
            rms_acc += out[i] * out[i]
            rms_n += 1
    frames = (VizFrame * 32)()
    got = lib.auradsp_viz_read(h, frames, 32)
    assert got > 0, "viz_read 返回 0（%s bass=%s）" % (mode, bass_on)
    s16 = max(frames[i].stage_levels_l[16] for i in range(got))
    sc16 = max(frames[i].stage_ch_levels[16 * CH_MAX + 0] for i in range(got))
    return s16, sc16, math.sqrt(rms_acc / max(rms_n, 1))


h = lib.auradsp_create(SR, BLOCK)
assert h, "auradsp_create failed"
try:
    # ---------------------------------------------------- stereo（语义基准）
    print("== [S] stereo 路径（本来就是 BassMono 输出，回归守卫）==")
    st_off, st_ch_off, st_rms_off = run_case(h, "stereo", False)
    st_on, st_ch_on, st_rms_on = run_case(h, "stereo", True)
    check("[S1] stereo: stage16 两态相等（采样在 basspsycho 之前）",
          abs(st_on - st_off) <= TOL_DB,
          "off=%.4f on=%.4f diff=%.2e" % (st_off, st_on, abs(st_on - st_off)))
    check("[S1b] stereo: stage_ch[16][0] 与 stage_levels_l[16] 同源",
          abs(st_ch_off - st_off) <= TOL_DB and abs(st_ch_on - st_on) <= TOL_DB,
          "off=%.4f on=%.4f" % (st_ch_off, st_ch_on))
    check("[S2] stereo: basspsycho 确实起效（输出 RMS 变化，非空转证明）",
          abs(st_rms_on - st_rms_off) > 1e-4,
          "off=%.6f on=%.6f" % (st_rms_off, st_rms_on))

    # ---------------------------------------------------- MC（本次修复对象）
    print("== [M] 离散多声道路径（E4 修复对象）==")
    mc_off, mc_ch_off, mc_rms_off = run_case(h, "mc", False)
    mc_on, mc_ch_on, mc_rms_on = run_case(h, "mc", True)
    check("[M1] MC: stage16 两态相等（采样点在 basspsycho 之前）",
          abs(mc_on - mc_off) <= TOL_DB,
          "off=%.4f on=%.4f diff=%.2e" % (mc_off, mc_on, abs(mc_on - mc_off)))
    check("[M1b] MC: stage_ch[16][0] 与 stage_levels_l[16] 同源",
          abs(mc_ch_off - mc_off) <= TOL_DB and abs(mc_ch_on - mc_on) <= TOL_DB,
          "off=%.4f on=%.4f" % (mc_ch_off, mc_ch_on))
    check("[M2] MC: basspsycho 确实起效（输出 RMS 变化，非空转证明）",
          abs(mc_rms_on - mc_rms_off) > 1e-4,
          "off=%.6f on=%.6f" % (mc_rms_off, mc_rms_on))

    # -------------------------------------------- 跨模式同槽同语义（E4 主旨）
    print("== [X] 跨模式：同一输入下两模式的 stage16 读数应收敛 ==")
    # 两模式链结构不同（MC 有 Category A 前级），不要求逐位相等；但同一
    # 信号、同一效果配置下 BassMono 柱的量级必须一致（此前 MC 含 basspsycho
    # 增益会系统性虚高）。给 1dB 容差覆盖链结构差异。
    check("[X1] MC/stereo 的 stage16（bass off）量级一致",
          abs(mc_off - st_off) <= 1.0,
          "stereo=%.4f mc=%.4f" % (st_off, mc_off))
    check("[X2] MC/stereo 的 stage16（bass on）量级一致（pre-fix 此处虚高判红）",
          abs(mc_on - st_on) <= 1.0,
          "stereo=%.4f mc=%.4f" % (st_on, mc_on))
finally:
    lib.auradsp_destroy(h)

print("\n" + "=" * 46)
if fails:
    print("FAILED %d / %d" % (len(fails), passes + len(fails)))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS: %d 项断言，E4 stage16 跨模式同语义门禁全绿" % passes)
