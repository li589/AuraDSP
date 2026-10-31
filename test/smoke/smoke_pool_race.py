#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_pool_race.py — 逐声道卷积池 / 主卷积 / 拓扑重置的并发门禁。

覆盖 2026-10-31 全量复核登记的三项高危并发遗留（P-047 专项）：

  - **L-01** eq 逐声道池：控制线程 `eq_pool_reload()` 对池内共享的
    `FFTConvolver1x1` 调 `LoadImpulseResponse`（其首步即 `FFTConvolver1x1Free`
    → free 掉 `_fftBuffer` / `_overlap` / `_inputBuffer` / `_segments*`），
    与 RT 的 `FFTConvolver1x1Process` 竞争 ⇒ 释放后使用（UAF，崩溃级）。
  - **L-03 池** arbmag 逐声道池：与 L-01 同型。
  - **L-03 主卷积** `arbMag.conv`：vendor 的
    `ArbitraryResponseEqualizerStringParser` 对其做**原位**
    `RefreshImpulseResponse`（改写 IR 段指针与 `_current` / `_overlap`），
    `ArbitraryResponseEqualizerEnable(forceRefresh)` 更会 Free + Load（UAF）；
    而 RT 的 `stage_arbmag` 正在同一对象上跑 `FFTConvolver2x2Process`。
  - **L-02** `reset_channel_state()`：控制线程直清 RT 正在使用的非原子状态
    （gate / filter / dyneq / tube / limiter / haas / spatial …）⇒ 数据竞争。

复刻手法沿用仓内既有竞态门禁形态（`smoke_comp_race.py` / `smoke_ddc_race.py`）：
ctypes 外部调用释放 GIL ⇒ 两条线程真实并发。

  - 「控制线程」：高频改曲线 / 切开关 / 改掩码（触发池重载与拓扑重置）；
  - 「RT 线程」：连续 `auradsp_process` 灌固定缓冲，抽样扫描输出有限性。

修复前（单池 + 控制线程直清 RT 状态）预期表现：进程级访问违例（UAF）或
输出被野指针污染成非有限 / 超大值；修复后必须进程存活、输出全程有限、
线程在超时前正常结束（无死锁）、且竞态结束后引擎功能完好。

阈值（吞吐 / 单块尖峰）经反向验证标定：临时还原 pre-fix 行为重建 DLL 后
核心断言必须转红。
"""
import ctypes
import math
import os
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 256
CH = 8
UI_SECONDS = 5.0          # 控制线程连续打压时长
JOIN_TIMEOUT = 25.0       # 死锁防御：超时即失败
FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


if not os.path.exists(DLL):
    print("SKIP（auradsp_engine.dll 不存在：%s）" % DLL)
    sys.exit(0)

dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]


def i32(v):
    return ctypes.c_int32(v)


def f32(v):
    return ctypes.c_float(v)


def set_i(h, pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)


def set_f(h, pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)


def set_s(h, pid, s):
    if isinstance(s, str):
        s = s.encode()
    return dll.auradsp_set_param(h, pid.encode(), s, len(s))


class Racer:
    """RT 线程 + 控制线程并发压测器。

    RT 线程：预分配缓冲连续 process，每 32 块抽样扫描有限性；逐块记录墙钟
    （单块尖峰）与总吞吐（RT 不得因控制侧等待而塌陷）。
    控制线程：由调用方给出 ui_fn（自己负责造参数对象，尽量把 Python 侧开销
    压到最低，使控制线程尽量停在 C 段的 IR 生成 + 池装载内）。
    """

    def __init__(self, h, ch=CH, seconds=UI_SECONDS, tag=""):
        self.h = h
        self.ch = ch
        self.seconds = seconds
        self.tag = tag
        self.stop = threading.Event()
        self.crash = []          # 访问违例等硬故障（UAF 的直接证据）
        self.nonfinite = []      # 输出被野指针污染
        self.blocks = 0
        self.max_block_ms = 0.0
        self.blocks_per_sec = 0.0
        self.ui_calls = 0
        self.ui_errors = []
        self._in = (ctypes.c_float * (BLOCK * ch))()
        self._out = (ctypes.c_float * (BLOCK * ch))()
        for i in range(BLOCK):
            for c in range(ch):
                self._in[i * ch + c] = 0.30 * math.sin(
                    2.0 * math.pi * (420.0 + 95.0 * c) * i / SR)

    def _rt(self):
        k = 0
        t_first = t_last = None
        while not self.stop.is_set():
            t0 = time.perf_counter()
            try:
                dll.auradsp_process(self.h, self._in, self._out, BLOCK)
            except OSError as e:
                # 访问违例 = 竞争致死的直接证据（修复前实测：access violation
                # reading 0x……，卷积器 IR 段指针表被控制线程 free 后读成野指针）。
                self.crash.append("block %d: %s" % (k, e))
                break
            t1 = time.perf_counter()
            if t_first is None:
                t_first = t0
            t_last = t1
            ms = (t1 - t0) * 1000.0
            if ms > self.max_block_ms:
                self.max_block_ms = ms
            if (k & 31) == 0:
                for i in range(0, BLOCK * self.ch, 4):
                    v = self._out[i]
                    if v != v or v > 1e6 or v < -1e6:
                        self.nonfinite.append(k)
                        break
            k += 1
        self.blocks = k
        if t_first is not None and t_last > t_first:
            self.blocks_per_sec = k / (t_last - t_first)

    def run(self, ui_fn):
        t_rt = threading.Thread(target=self._rt, daemon=True)
        t_ui = threading.Thread(target=ui_fn, daemon=True)
        t_rt.start()
        t_ui.start()
        t_ui.join(JOIN_TIMEOUT)
        ui_alive = t_ui.is_alive()
        self.stop.set()
        t_rt.join(JOIN_TIMEOUT)
        rt_alive = t_rt.is_alive()
        check("[%s] control thread finished (no deadlock/hang)" % self.tag,
              not ui_alive, "alive after %.0fs" % JOIN_TIMEOUT)
        check("[%s] rt thread finished (no deadlock/hang)" % self.tag,
              not rt_alive, "alive after %.0fs" % JOIN_TIMEOUT)
        check("[%s] rt no hard fault (access violation)" % self.tag,
              not self.crash, str(self.crash[:1]))
        check("[%s] rt output always finite" % self.tag,
              not self.nonfinite,
              "first bad block=%s" % (self.nonfinite[0] if self.nonfinite else None))
        check("[%s] rt produced audio (blocks>500)" % self.tag,
              self.blocks > 500, "blocks=%d" % self.blocks)
        check("[%s] control set_param all rc==0" % self.tag,
              not self.ui_errors, str(self.ui_errors[:3]))
        # RT 不被控制侧拖垮：P-047 的在途守卫只让**控制线程**等待（影子槽复用），
        # RT 永不取锁、永不等待 ⇒ 吞吐与单块尖峰都应保持正常。
        check("[%s] rt throughput not collapsed (blocks/s>=400)" % self.tag,
              self.blocks_per_sec >= 400,
              "blocks/s=%.0f" % self.blocks_per_sec)
        check("[%s] rt max block no wait spike (<25ms)" % self.tag,
              self.max_block_ms < 25.0, "max=%.2fms" % self.max_block_ms)
        print("  [info] %s ui_calls=%d rt_blocks=%d blocks/s=%.0f max_block=%.2fms"
              % (self.tag, self.ui_calls, self.blocks,
                 self.blocks_per_sec, self.max_block_ms))


# ----------------------------------------------------------------------
print("=== [1] L-01 eq 逐声道池：控制线程高频重载 + RT 连续 process（8ch 离散） ===")
h_eq = dll.auradsp_create(SR, BLOCK)
assert h_eq, "create failed"
set_i(h_eq, "channels.count", 8)
set_i(h_eq, "channels.mode", 1)      # 离散多声道（走 eq 逐声道池）
set_i(h_eq, "limiter.enable", 0)     # 隔离 limiter，避免门限掩盖失真
set_i(h_eq, "eq.enable", 1)
set_i(h_eq, "eq.channels", 0xFF)
set_s(h_eq, "eq.curve", "20:0.0;1000:6.0;20000:0.0")

CURVE_A = b"20:0.0;1000:6.0;20000:0.0"
CURVE_B = b"20:-3.0;800:9.0;4000:-6.0;20000:0.0"
r_eq = Racer(h_eq, CH, UI_SECONDS, "eq-pool")


def ui_eq():
    """高频改 EQ 曲线（每次都触发 eq_pool_reload）+ 切 enable + 改掩码。"""
    en = i32(1)
    en_ref = ctypes.byref(en)
    mask = i32(0xFF)
    mask_ref = ctypes.byref(mask)
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        rc = dll.auradsp_set_param(h_eq, b"eq.curve",
                                    CURVE_A if (n & 1) else CURVE_B, len(CURVE_A))
        if rc != 0:
            r_eq.ui_errors.append("curve rc=%d" % rc)
        if (n % 3) == 0:
            en.value = 0
            dll.auradsp_set_param(h_eq, b"eq.enable", en_ref, 4)
            en.value = 1
            dll.auradsp_set_param(h_eq, b"eq.enable", en_ref, 4)
        if (n % 5) == 0:
            mask.value = 0xFF if (n % 10) == 0 else 0x0F
            dll.auradsp_set_param(h_eq, b"eq.channels", mask_ref, 4)
        n += 1
    r_eq.ui_calls = n


r_eq.run(ui_eq)

# ----------------------------------------------------------------------
print()
print("=== [2] L-03 arbmag 逐声道池：控制线程高频重载 + RT 连续 process（8ch 离散） ===")
h_ar = dll.auradsp_create(SR, BLOCK)
assert h_ar, "create failed"
set_i(h_ar, "channels.count", 8)
set_i(h_ar, "channels.mode", 1)
set_i(h_ar, "limiter.enable", 0)
set_s(h_ar, "arbmag.string", "GraphicEQ: 20 6.0; 20000 6.0")
set_i(h_ar, "arbmag.enable", 1)
set_i(h_ar, "arbmag.channels", 0xFF)

ARB_A = b"GraphicEQ: 20 6.0; 20000 6.0"
ARB_B = b"GraphicEQ: 40 -4.0; 900 9.0; 6000 -5.0; 18000 3.0"
r_ar = Racer(h_ar, CH, UI_SECONDS, "arbmag-pool")


def ui_ar():
    en = i32(1)
    en_ref = ctypes.byref(en)
    mask = i32(0xFF)
    mask_ref = ctypes.byref(mask)
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        rc = dll.auradsp_set_param(h_ar, b"arbmag.string",
                                   ARB_A if (n & 1) else ARB_B, len(ARB_A))
        if rc != 0:
            r_ar.ui_errors.append("string rc=%d" % rc)
        if (n % 3) == 0:
            en.value = 0
            dll.auradsp_set_param(h_ar, b"arbmag.enable", en_ref, 4)
            en.value = 1
            dll.auradsp_set_param(h_ar, b"arbmag.enable", en_ref, 4)
        if (n % 5) == 0:
            mask.value = 0xFF if (n % 10) == 0 else 0x0F
            dll.auradsp_set_param(h_ar, b"arbmag.channels", mask_ref, 4)
        n += 1
    r_ar.ui_calls = n


r_ar.run(ui_ar)

# ----------------------------------------------------------------------
print()
print("=== [3] L-03 主卷积：arbMag.conv 原位刷新 vs RT 的 vendor stage（立体声） ===")
# 撕裂检测器：用**两条直流增益相同、频谱不同**的曲线交替刷新主卷积。
#   合法换曲线 → 稳态直流输出不变（两曲线 DC 增益都是 0 dB）；
#   撕裂的 IR  → 输出既不是 A 的也不是 B 的 → 幅度失控。
# 反向验证实测（同一探针 tools/probe/probe_arbmag_tear.py、同一曲线对，
# 4 次独立观测的块间最大相对偏离）：
#   pre-fix （无锁，原位刷新）  2397% / 1002% / 3794% / 50810%   ← 撕裂
#   post-fix（同持 jdsp_lock）  341.52% / 341.47% / 341.66% / 341.5%
# 两个分布**完全不重叠**（pre-fix 最小 1002% > post-fix 最大 341.7%），
# 故阈值取 700%：落在两者之间的空档，post-fix 侧余量 2.05×，
# pre-fix 侧最小观测仍超阈 1.43×。
# 注：mean 类统计在此**不可用**——修复版因 stage_arbmag 取锁而变慢，
# 单位块内的换曲线次数上升，合法瞬态的均值反而更高（19.4% vs 11.3%），
# 与撕裂信号混淆；只有极值统计能区分。
TEAR_A = b"GraphicEQ: 20 0.0; 8000 12.0"
TEAR_B = b"GraphicEQ: 20 0.0; 8000 -12.0"
TEAR_DC = 0.30
TEAR_MAX_DEV_PCT = 700.0

h_main = dll.auradsp_create(SR, BLOCK)
assert h_main, "create failed"
set_i(h_main, "limiter.enable", 0)
set_s(h_main, "arbmag.string", TEAR_A.decode())
set_i(h_main, "arbmag.enable", 1)

tear_stop = threading.Event()
tear_blocks = [0]
tear_max_dev = [0.0]
tear_max_abs = [0.0]
tear_curves = [0]
tear_crash = []
tear_ui_err = []

tear_in = (ctypes.c_float * (BLOCK * 2))()
tear_out = (ctypes.c_float * (BLOCK * 2))()
for i in range(BLOCK):
    tear_in[i * 2] = TEAR_DC
    tear_in[i * 2 + 1] = TEAR_DC


def tear_rt():
    k = 0
    prev = None
    while not tear_stop.is_set():
        try:
            dll.auradsp_process(h_main, tear_in, tear_out, BLOCK)
        except OSError as e:
            tear_crash.append("block %d: %s" % (k, e))
            break
        if k > 8:
            v = tear_out[0]
            a = abs(v)
            if a > tear_max_abs[0]:
                tear_max_abs[0] = a
            if prev is not None:
                dev = abs(v - prev) / max(abs(prev), 1e-9)
                if dev > tear_max_dev[0]:
                    tear_max_dev[0] = dev
            prev = v
        k += 1
    tear_blocks[0] = k


def ui_main():
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        rc = dll.auradsp_set_param(h_main, b"arbmag.string",
                                   TEAR_A if (n & 1) else TEAR_B, len(TEAR_A))
        if rc != 0:
            tear_ui_err.append("rc=%d" % rc)
        n += 1
    tear_curves[0] = n


t_tear = threading.Thread(target=tear_rt, daemon=True)
t_tear_ui = threading.Thread(target=ui_main, daemon=True)
t_tear.start()
t_tear_ui.start()
t_tear_ui.join(JOIN_TIMEOUT)
tear_ui_alive = t_tear_ui.is_alive()
tear_stop.set()
t_tear.join(JOIN_TIMEOUT)
check("[arbmag-main] control thread finished (no deadlock/hang)", not tear_ui_alive)
check("[arbmag-main] rt no hard fault (access violation)", not tear_crash,
      str(tear_crash[:1]))
check("[arbmag-main] control set_param all rc==0", not tear_ui_err,
      str(tear_ui_err[:3]))
check("[arbmag-main] rt produced audio (blocks>500)", tear_blocks[0] > 500,
      "blocks=%d" % tear_blocks[0])
tear_dev_pct = tear_max_dev[0] * 100.0
check("[arbmag-main] main conv never torn (block-to-block dev < %.0f%%)"
      % TEAR_MAX_DEV_PCT, tear_dev_pct < TEAR_MAX_DEV_PCT,
      "max_dev=%.1f%%" % tear_dev_pct)
check("[arbmag-main] output magnitude bounded (|out| <= 16x DC input)",
      tear_max_abs[0] <= 16.0 * TEAR_DC,
      "max_abs=%.4f (%.1fx)" % (tear_max_abs[0], tear_max_abs[0] / TEAR_DC))
print("  [info] arbmag-main curves=%d blocks=%d max_dev=%.1f%% max_abs=%.4f (%.2fx)"
      % (tear_curves[0], tear_blocks[0], tear_dev_pct,
         tear_max_abs[0], tear_max_abs[0] / TEAR_DC))

# ----------------------------------------------------------------------
print()
print("=== [4] L-02 拓扑重置：channels.mode / count / spatial 切换 vs RT 连续 process ===")
h_rst = dll.auradsp_create(SR, BLOCK)
assert h_rst, "create failed"
set_i(h_rst, "channels.count", 8)
set_i(h_rst, "channels.mode", 1)
set_i(h_rst, "limiter.enable", 0)
set_i(h_rst, "spatial.enable", 1)
# 打开 EQ：拓扑重置路径（reset_channel_state）会连带触发 eq 池重载，
# 于是本阶段同时覆盖「拓扑重置 → 池重载」这条 UAF 向量。
set_i(h_rst, "eq.enable", 1)
set_i(h_rst, "eq.channels", 0xFF)
set_s(h_rst, "eq.curve", "20:0.0;1000:6.0;20000:0.0")
r_rst = Racer(h_rst, CH, UI_SECONDS, "topo-reset")


def ui_rst():
    mode = i32(1)
    mode_ref = ctypes.byref(mode)
    cnt = i32(8)
    cnt_ref = ctypes.byref(cnt)
    spa = i32(1)
    spa_ref = ctypes.byref(spa)
    bin_ = i32(0)
    bin_ref = ctypes.byref(bin_)
    n = 0
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < UI_SECONDS:
        mode.value = (n & 1)
        dll.auradsp_set_param(h_rst, b"channels.mode", mode_ref, 4)
        if (n % 2) == 0:
            cnt.value = (2, 4, 6, 8)[(n // 2) % 4]
            dll.auradsp_set_param(h_rst, b"channels.count", cnt_ref, 4)
        spa.value = (n // 3) & 1
        dll.auradsp_set_param(h_rst, b"spatial.enable", spa_ref, 4)
        if (n % 4) == 0:
            bin_.value = (n // 4) & 1
            dll.auradsp_set_param(h_rst, b"spatial.binaural", bin_ref, 4)
        n += 1
    r_rst.ui_calls = n


r_rst.run(ui_rst)

# ----------------------------------------------------------------------
print()
print("=== [5] 收尾：竞态后引擎功能完好（eq 池仍按曲线生效，8ch 逐声道） ===")
# 竞态结束后 RT 已停 ⇒ 在途守卫的 in_flight==0 立即成立，池重载不再等待。
set_i(h_eq, "eq.channels", 0x04)          # 仅 ch2 生效
set_s(h_eq, "eq.curve", "20:0.0;1000:12.0;20000:0.0")
set_i(h_eq, "eq.enable", 1)

SINE_F = 1000.0
NBLK = 48
in_buf = (ctypes.c_float * (BLOCK * CH))()
out_buf = (ctypes.c_float * (BLOCK * CH))()
for i in range(BLOCK):
    v = 0.20 * math.sin(2.0 * math.pi * SINE_F * i / SR)
    for c in range(CH):
        in_buf[i * CH + c] = v

# 注意：auradsp_process 的 frames 会被引擎的 max_block（本例 = BLOCK）钳制，
# 必须按块喂；一次性喂大块只会处理前 max_block 帧，其余输出保持为 0。
tail_amp = 0.0
tail_finite = True
for b in range(NBLK):
    dll.auradsp_process(h_eq, in_buf, out_buf, BLOCK)
    if b >= NBLK - 16:
        for i in range(BLOCK):
            a = abs(out_buf[i * CH + 2])
            if a > tail_amp:
                tail_amp = a
    for i in range(BLOCK * CH):
        v = out_buf[i]
        if v != v or abs(v) > 1e6:
            tail_finite = False

expect = 0.20 * (10.0 ** (12.0 / 20.0))
gain_db = 20.0 * math.log10(tail_amp / 0.20) if tail_amp > 1e-9 else -120.0
check("eq pool still functional after race (gain ~= +12dB, got %.2fdB)" % gain_db,
      abs(gain_db - 12.0) < 1.0, "gain=%.2fdB amp=%.4f expect=%.4f" % (gain_db, tail_amp, expect))
check("eq pool output finite after race", tail_finite)

dll.auradsp_destroy(h_eq)
dll.auradsp_destroy(h_ar)
dll.auradsp_destroy(h_main)
dll.auradsp_destroy(h_rst)

print()
if FAIL:
    print("POOL RACE FAILURES:", FAIL)
    sys.exit(1)
print("pool race: all checks passed")
