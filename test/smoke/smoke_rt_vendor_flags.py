# -*- coding: utf-8 -*-
"""smoke_rt_vendor_flags.py — B4 验收：RT 不得改写 vendor 开关（lost update）。

背景（审查 B4，P1）：多声道链 Category B 段原先在音频线程内
save→写 0→restore 五个 vendor 开关（tubeEnabled / limiterEnabled /
compEnabled / equalizerEnabled / arbitraryMagEnabled）。这些字段由控制线程
（VacuumTubeEnable/Disable、CompressorEnable/Disable、MultimodalEQEnable、
ArbitraryResponseEqualizer…）随时改写——用户操作落在 save 与 restore 之间
就会被 restore 静默回滚（界面显示开着、实际关了）= lost update。

修法：`AuraStageGates` 调用级门控参数（jdsp_header.h），RT 只读全局开关。

本门禁三层：
  [A] 源码不变式（确定性）：engine/chain/*.cpp 内不得出现 vendor 开关写入；
      也不得出现 save/restore 五连（tube_saved 之类）。
  [B] 门控接线（确定性）：comp 的 FL/FR 门控必须真的生效——mask 覆盖 FL/FR
      时压缩生效，mask 不覆盖时 FL/FR 输出与「comp 关闭」逐位相同，且
      mask 覆盖的 ch2/ch3 仍被压缩（防「整体不压缩」蒙过）。
  [C] 竞态（概率性，60 轮）：MC 重负载处理中反复翻转 tube.enable，末次写入
      停在「关」；随后切 stereo 测量——若曾发生 lost update，vendor
      tubeEnabled 会残留 1，stereo 输出将带管味失真。断言「param=0 的每一轮
      都必须与从未开过 tube 的参照逐位一致」。

反向验证（2026-10-24，临时还原 save/写0/restore 重建）：[A] 直接判红；
[C] 60 轮中 16 轮判红（26.7%/轮，60 轮近必然）；修复版 [C] 0/60。
"""
import ctypes
import glob
import os
import re
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get(
    "AURADSP_DLL",
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))
SR = 48000.0
BLOCK = 4096
CH = 6
RACE_ROUNDS = 60

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


# ------------------------------------------------------------------ [A] 源码不变式
print("=== [A] 源码不变式：RT 链不得写 vendor 开关 ===")
chain_dir = os.path.join(ROOT, "engine", "chain")
srcs = sorted(glob.glob(os.path.join(chain_dir, "*.cpp")) + glob.glob(os.path.join(chain_dir, "*.h")))
check("engine/chain 源文件可见", len(srcs) > 0, str(chain_dir))

# 允许的「读」形式（比较 / 传参）；命中的是赋值。
FLAGS = ["tubeEnabled", "limiterEnabled", "compEnabled", "equalizerEnabled",
         "arbitraryMagEnabled", "bassBoostEnabled", "crossfeedEnabled",
         "sterEnhEnabled", "reverbEnabled", "convolverEnabled", "ddcEnabled"]
assign_re = re.compile(r"\bjdsp\b\s*(?:\.|->)\s*(?:" + "|".join(FLAGS) + r")\s*=(?!=)")
# 控制侧写开关是合法的（apply_* / hook_* / set_*）：它们本来就不在音频线程。
ctrl_prefix = ("apply_", "hook_", "set_")
fn_re = re.compile(r"^[A-Za-z_][\w \*&:<>]*?\b([A-Za-z_]\w*)\s*\(")
hits = []
for p in srcs:
    cur = ""
    for i, line in enumerate(open(p, encoding="utf-8", errors="replace").read().splitlines(), 1):
        if line[:1] not in (" ", "\t"):        # 顶格 = 顶层函数定义/声明
            m = fn_re.match(line)
            if m:
                cur = m.group(1)
        if assign_re.search(line) and not cur.startswith(ctrl_prefix):
            hits.append("%s:%d[%s]: %s" % (os.path.basename(p), i, cur, line.strip()))
check("engine/chain 无 RT 侧 vendor 开关写入", not hits, "; ".join(hits[:3]))

saved_re = re.compile(r"\b(?:tube|limiter|comp|eq|arbmag|arbitraryMag)_saved\b")
hits2 = []
for p in srcs:
    txt = open(p, encoding="utf-8", errors="replace").read()
    for i, line in enumerate(txt.splitlines(), 1):
        if saved_re.search(line):
            hits2.append("%s:%d: %s" % (os.path.basename(p), i, line.strip()))
check("engine/chain 无 save/restore 五连", not hits2, "; ".join(hits2[:3]))

# ------------------------------------------------------------------ 引擎绑定
lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]


def si(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def sf(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)


def gi(h, k):
    out = ctypes.c_int32(0)
    rc = lib.auradsp_get_param(h, k.encode(), ctypes.byref(out), 4)
    return rc, out.value


OFF = [("limiter.enable", 0), ("gate.enable", 0), ("filter.enable", 0), ("shelf.enable", 0),
       ("dyneq.enable", 0), ("tube.enable", 0), ("exciter.enable", 0), ("loudness.enable", 0),
       ("haas.enable", 0), ("spatial.enable", 0), ("bassmono.enable", 0), ("bass.enable", 0),
       ("reverb.preset", -1), ("convolver.enable", 0), ("ddc.enable", 0), ("liveprog.enable", 0),
       ("arbmag.enable", 0), ("comp.enable", 0), ("eq.enable", 0), ("crossfeed.enable", 0)]


def setup(ch=CH, heavy=True):
    h = lib.auradsp_create(SR, BLOCK)
    for k, v in OFF:
        assert si(h, k, v) == 0, k
    assert si(h, "channels.count", ch) == 0
    assert si(h, "channels.mode", 1) == 0
    if heavy:
        # Category B 重负载（拉长 save→restore 窗口，[C] 才有检出率）
        assert si(h, "comp.enable", 1) == 0
        assert si(h, "comp.channels", 0x3F) == 0
        assert si(h, "eq.enable", 1) == 0
        assert si(h, "eq.channels", 0x3F) == 0
    return h


# ------------------------------------------------------------------ [B] 门控接线
print("=== [B] 调用级门控接线（comp 的 FL/FR mask） ===")


def comp_scenario(comp_en, comp_mask):
    """MC ch=6 + comp 的三种配置，返回各声道 abs-sum。"""
    h = setup(heavy=False)
    assert si(h, "comp.enable", comp_en) == 0
    assert si(h, "comp.channels", comp_mask) == 0
    assert sf(h, "comp.timeconstant", 0.02) == 0
    for i in range(1, 8):
        assert sf(h, "comp.gain%d" % i, 0.9 if i % 2 else -0.9) == 0
    inb = (ctypes.c_float * (BLOCK * CH))()
    outb = (ctypes.c_float * (BLOCK * CH))()
    acc = [0.0] * CH
    for b in range(4):
        for i in range(BLOCK):
            n = b * BLOCK + i
            for c in range(CH):
                inb[i * CH + c] = (0.6 / (1 + c)) * ((n * (c + 3)) % 97 - 48) / 48.0
        lib.auradsp_process(h, inb, outb, BLOCK)
        for i in range(BLOCK):
            for c in range(CH):
                acc[c] += abs(outb[i * CH + c])
    lib.auradsp_destroy(h)
    return acc


off = comp_scenario(0, 0x3F)
allp = comp_scenario(1, 0x3F)   # mask 覆盖 FL/FR → 压缩必须生效
rest = comp_scenario(1, 0x0C)   # mask 只覆盖 ch2/3 → FL/FR 必须完全跳过

check("comp 覆盖 FL/FR 时生效",
      abs(allp[0] - off[0]) / max(off[0], 1e-9) > 0.1,
      "off=%.3f on=%.3f" % (off[0], allp[0]))
check("comp 不覆盖 FL/FR 时逐位跳过",
      abs(rest[0] - off[0]) < 1e-9 and abs(rest[1] - off[1]) < 1e-9,
      "off=%.6f got=%.6f" % (off[0], rest[0]))
check("comp 对 mask 命中的 ch2/ch3 仍生效（防整体失效蒙过）",
      abs(rest[2] - off[2]) / max(off[2], 1e-9) > 0.1,
      "off=%.3f got=%.3f" % (off[2], rest[2]))

# ------------------------------------------------------------------ [C] 竞态
print("=== [C] 竞态：MC 处理中翻转 tube.enable，结束后 vendor 开关必须归零 ===")


def run_rt(h, nblocks):
    inb = (ctypes.c_float * (BLOCK * CH))()
    outb = (ctypes.c_float * (BLOCK * CH))()
    for b in range(nblocks):
        for i in range(BLOCK):
            for c in range(CH):
                inb[i * CH + c] = 0.3 * (((i + c * 7 + b) % 23) - 11) / 11.0
        lib.auradsp_process(h, inb, outb, BLOCK)


def finish(h):
    """收尾测量：先关掉 MC 期间跑过的效果器（否则其 vendor 滤波器残态污染
    stereo 测量），再切 stereo 喂确定性信号取 abs-sum。"""
    assert si(h, "comp.enable", 0) == 0
    assert si(h, "eq.enable", 0) == 0
    assert si(h, "channels.count", 2) == 0
    assert si(h, "channels.mode", 0) == 0
    inb = (ctypes.c_float * (BLOCK * 2))()
    outb = (ctypes.c_float * (BLOCK * 2))()
    acc = 0.0
    for b in range(4):
        for i in range(BLOCK):
            n = b * BLOCK + i
            inb[i * 2] = 0.7 * ((n % 37) - 18) / 18.0
            inb[i * 2 + 1] = 0.6 * ((n % 29) - 14) / 14.0
        lib.auradsp_process(h, inb, outb, BLOCK)
        for i in range(BLOCK * 2):
            acc += abs(outb[i])
    lib.auradsp_destroy(h)
    return acc


hc = setup()
t0 = time.time()
run_rt(hc, 8)
T_CLEAN = time.time() - t0
clean = finish(hc)
print("      参照（从未开过 tube）: %.9f  (8 blocks = %.1f ms)" % (clean, T_CLEAN * 1000))

# 非空转：tube 常开时该观测量必须有显著差异，否则 [C] 的断言等于白跑
ht = setup()
assert si(ht, "tube.enable", 1) == 0
assert sf(ht, "tube.gain", 9.0) == 0
assert si(ht, "tube.style", 1) == 0
run_rt(ht, 8)
ontube = finish(ht)
check("观测量非空转（tube 常开 → stereo 输出显著不同）",
      abs(ontube - clean) > 1.0, "clean=%.3f ontube=%.3f" % (clean, ontube))

lost = 0
usable = 0
for r in range(RACE_ROUNDS):
    h = setup()
    assert si(h, "tube.enable", 1) == 0
    assert sf(h, "tube.gain", 9.0) == 0
    assert si(h, "tube.style", 1) == 0
    t = threading.Thread(target=run_rt, args=(h, 8))
    t.start()
    t0 = time.time()
    n = 0
    # 翻转到 RT 总时长的 40% 后写一次 0：此时 RT 仍有 4~5 块要跑，写入落在
    # 某块中途（而非块尾），才可能撞进 save→restore 窗口。
    while t.is_alive() and (time.time() - t0) < 0.4 * T_CLEAN:
        si(h, "tube.enable", 0 if (n % 2) else 1)
        n += 1
    si(h, "tube.enable", 0)
    t.join()
    _, param = gi(h, "tube.enable")
    m = finish(h)
    if param != 0:
        continue
    usable += 1
    if abs(m - clean) > 1.0:
        lost += 1
        print("      round %d: LOST UPDATE（param=0 但 vendor 开关残留 1）diff=%.3f"
              % (r, abs(m - clean)))

check("竞态轮次充足（可判定）", usable >= RACE_ROUNDS // 3, "usable=%d" % usable)
check("无 lost update（param=0 ⟹ vendor 开关为 0）", lost == 0,
      "lost=%d/%d" % (lost, usable))

# ------------------------------------------------------------------ 结果
if FAIL:
    print("RTVENDORFLAGS FAILURES:", FAIL)
    sys.exit(1)
print("RTVENDORFLAGS ALL PASSED (rounds=%d usable=%d)" % (RACE_ROUNDS, usable))
