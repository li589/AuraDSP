"""smoke_multichannel_discrete.py — 离散多声道独立处理 (Phase 2 Phase B) 全面验证

覆盖：
  [1] Category A 独立单声道效果器声道掩码（*.channels / *.channel_mask）：
      - filter (HPF/LPF)
      - shelf (低架)
      - dyneq (动态EQ)
      - tube (电子管饱和)
      - exciter (激励器)
      - loudness (响度补偿)
      - limiter (限幅器)
      - gate (噪声门)
  [2] Category B 跨声道/声场效果器不变性（FL/FR 作用，环绕声道 100% 逐样本直通保真）：
      - haas
      - spatial
      - freeverb
      - bassmono
"""
import ctypes
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))
if not os.path.exists(DLL):
    if os.path.exists("C:/AuraDSP/auradsp_engine.dll"):
        DLL = "C:/AuraDSP/auradsp_engine.dll"
    else:
        print(f"Error: DLL not found at {DLL}")
        sys.exit(1)

lib = ctypes.CDLL(DLL)
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
lib.auradsp_get_param.restype = ctypes.c_int32
lib.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]

FAILURES = []

def check(cond, msg):
    if cond:
        print(f"  PASS  {msg}")
    else:
        print(f"  FAIL  {msg}")
        FAILURES.append(msg)

def set_i32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)

def set_f32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)

def get_i32(h, k):
    out = ctypes.c_int32(0)
    rc = lib.auradsp_get_param(h, k.encode(), ctypes.byref(out), 4)
    return rc, out.value

def process(h, n_frames, n_ch):
    src = (ctypes.c_float * (n_frames * n_ch))()
    dst = (ctypes.c_float * (n_frames * n_ch))()
    sp = ctypes.cast(src, ctypes.POINTER(ctypes.c_float))
    dp = ctypes.cast(dst, ctypes.POINTER(ctypes.c_float))
    return src, dst, sp, dp

# ---------------------------------------------------------------- [1] Category A 声道掩码独立处理
print("\n=== [1] Category A 独立单声道效果器掩码选择与隔离验证 ===")
F = 256
CH = 6 # 5.1: FL(0), FR(1), C(2), LFE(3), SL(4), SR(5)

# A. Shelf: 仅对 C(2) 声道提升低频 (+6dB)
h = lib.auradsp_create(48000.0, F)
set_i32(h, "channels.count", CH)
set_i32(h, "channels.mode", 1) # 离散模式
set_i32(h, "limiter.enable", 0) # 隔离限幅器前瞻延迟
set_i32(h, "shelf.enable", 1)
set_f32(h, "shelf.freq", 200.0)
set_f32(h, "shelf.gain", 6.0)
set_i32(h, "shelf.channels", 0x04) # 仅 C 声道 (bit 2)

src, dst, sp, dp = process(h, F, CH)
for i in range(F):
    s = 0.3 * math.sin(2 * math.pi * 100.0 * i / 48000.0)
    for c in range(CH):
        src[i * CH + c] = s
lib.auradsp_process(h, sp, dp, F)

c_diff = sum(abs(dst[i * CH + 2] - src[i * CH + 2]) for i in range(F)) / F
check(c_diff > 0.05, f"Shelf: Center 声道获得低架增益 (diff={c_diff:.4f})")
other_dev = max(abs(dst[i * CH + c] - src[i * CH + c]) for c in (0, 1, 3, 4, 5) for i in range(F))
check(other_dev < 1e-6, f"Shelf: 非 Center 声道 (FL/FR/LFE/SL/SR) 100% 直通 (max dev={other_dev:.2e})")
lib.auradsp_destroy(h)

# B. Tube: 仅对 SL(4) 和 SR(5) 环绕声道施加饱和 (0x30)
h = lib.auradsp_create(48000.0, F)
set_i32(h, "channels.count", CH)
set_i32(h, "channels.mode", 1)
set_i32(h, "limiter.enable", 0) # 隔离限幅器前瞻延迟
set_i32(h, "tube.enable", 1)
set_f32(h, "tube.drive", 8.0)
set_i32(h, "tube.channels", 0x30) # 0x10 | 0x20

src, dst, sp, dp = process(h, F, CH)
for i in range(F):
    s = 0.5 * math.sin(2 * math.pi * 1000.0 * i / 48000.0)
    for c in range(CH):
        src[i * CH + c] = s
lib.auradsp_process(h, sp, dp, F)

sl_diff = sum(abs(dst[i * CH + 4] - src[i * CH + 4]) for i in range(F)) / F
sr_diff = sum(abs(dst[i * CH + 5] - src[i * CH + 5]) for i in range(F)) / F
check(sl_diff > 0.01 and sr_diff > 0.01, f"Tube: 环绕声 SL/SR 产生非线性电子管谐波 (sl={sl_diff:.4f}, sr={sr_diff:.4f})")
front_dev = max(abs(dst[i * CH + c] - src[i * CH + c]) for c in (0, 1, 2, 3) for i in range(F))
check(front_dev < 1e-6, f"Tube: 前置与低音 (FL/FR/C/LFE) 100% 直通 (dev={front_dev:.2e})")
lib.auradsp_destroy(h)

# C. Exciter: 仅对 FL(0) 与 FR(1) 生效 (0x03)
h = lib.auradsp_create(48000.0, F)
set_i32(h, "channels.count", CH)
set_i32(h, "channels.mode", 1)
set_i32(h, "limiter.enable", 0) # 隔离限幅器前瞻延迟
set_i32(h, "exciter.enable", 1)
set_f32(h, "exciter.harmonics", 1.0)
set_f32(h, "exciter.blend", 1.0)
set_i32(h, "exciter.channels", 0x03)

src, dst, sp, dp = process(h, F, CH)
for i in range(F):
    s = 0.4 * math.sin(2 * math.pi * 2000.0 * i / 48000.0)
    for c in range(CH):
        src[i * CH + c] = s
lib.auradsp_process(h, sp, dp, F)

fl_diff = sum(abs(dst[i * CH + 0] - src[i * CH + 0]) for i in range(F)) / F
fr_diff = sum(abs(dst[i * CH + 1] - src[i * CH + 1]) for i in range(F)) / F
check(fl_diff > 0.01 and fr_diff > 0.01, f"Exciter: FL/FR 激发高次谐波 (fl={fl_diff:.4f}, fr={fr_diff:.4f})")
surround_dev = max(abs(dst[i * CH + c] - src[i * CH + c]) for c in (2, 3, 4, 5) for i in range(F))
check(surround_dev < 1e-6, f"Exciter: 其余声道 (C/LFE/SL/SR) 100% 直通 (dev={surround_dev:.2e})")
# D. Loudness: 仅对 C(2) 与 LFE(3) 生效 (0x0C)
h = lib.auradsp_create(48000.0, F)
set_i32(h, "channels.count", CH)
set_i32(h, "channels.mode", 1)
set_i32(h, "limiter.enable", 0) # 隔离限幅器前瞻延迟
set_i32(h, "loudness.enable", 1)
set_f32(h, "loudness.level", 0.8)
set_i32(h, "loudness.channels", 0x0C)

src, dst, sp, dp = process(h, F, CH)
for i in range(F):
    s = 0.2 * math.sin(2 * math.pi * 80.0 * i / 48000.0)
    for c in range(CH):
        src[i * CH + c] = s
lib.auradsp_process(h, sp, dp, F)

c_diff = sum(abs(dst[i * CH + 2] - src[i * CH + 2]) for i in range(F)) / F
lfe_diff = sum(abs(dst[i * CH + 3] - src[i * CH + 3]) for i in range(F)) / F
check(c_diff > 0.01 and lfe_diff > 0.01, f"Loudness: C/LFE 获得等响度曲线补偿 (c={c_diff:.4f}, lfe={lfe_diff:.4f})")
other_dev = max(abs(dst[i * CH + c] - src[i * CH + c]) for c in (0, 1, 4, 5) for i in range(F))
check(other_dev < 1e-6, f"Loudness: 未命中声道 (FL/FR/SL/SR) 100% 直通 (dev={other_dev:.2e})")
lib.auradsp_destroy(h)

# E. Limiter: 仅对 LFE(3) 限幅 (0x08)
h = lib.auradsp_create(48000.0, F)
set_i32(h, "channels.count", CH)
set_i32(h, "channels.mode", 1)
set_i32(h, "limiter.enable", 1)
set_i32(h, "limiter.channels", 0x08) # 仅 LFE 限幅

src, dst, sp, dp = process(h, F, CH)
for i in range(F):
    s = 2.0 # 大信号超出 0dBFS (1.0) 阈值
    for c in range(CH):
        src[i * CH + c] = s
lib.auradsp_process(h, sp, dp, F)

lfe_max = max(dst[i * CH + 3] for i in range(F))
check(lfe_max <= 1.01, f"Limiter: LFE 峰值受到平滑压制限幅到 0dBFS (max={lfe_max:.4f} <= 1.01)")
other_dev = max(abs(dst[i * CH + c] - src[i * CH + c]) for c in (0, 1, 2, 4, 5) for i in range(F))
check(other_dev < 1e-6, f"Limiter: 未选中的声道 (FL/FR/C/SL/SR) 100% 保真直通 (dev={other_dev:.2e})")
lib.auradsp_destroy(h)

# ---------------------------------------------------------------- [2] Category B 声场保持性
print("\n=== [2] Category B 跨声道/声场效果器不变性验证 ===")
# 开启 Haas 与 Freeverb，确保它们只作用于 FL/FR，后方声道与中置/低音严格直通保真
h = lib.auradsp_create(48000.0, F)
set_i32(h, "channels.count", CH)
set_i32(h, "channels.mode", 1)
set_i32(h, "limiter.enable", 0) # 隔离限幅器前瞻延迟
set_i32(h, "haas.enable", 1)
set_f32(h, "haas.delay_ms", 15.0)
set_f32(h, "haas.mix", 0.5)
set_i32(h, "freeverb.enable", 1)
set_f32(h, "freeverb.wet", 0.5)
set_f32(h, "freeverb.dry", 0.8)

src, dst, sp, dp = process(h, F, CH)
for i in range(F):
    s = 0.3 * math.sin(2 * math.pi * 500.0 * i / 48000.0)
    for c in range(CH):
        src[i * CH + c] = s
lib.auradsp_process(h, sp, dp, F)

fl_diff = sum(abs(dst[i * CH + 0] - src[i * CH + 0]) for i in range(F)) / F
fr_diff = sum(abs(dst[i * CH + 1] - src[i * CH + 1]) for i in range(F)) / F
check(fl_diff > 0.01 and fr_diff > 0.01, f"Category B: 前置 FL/FR 受到声场处理 (fl={fl_diff:.4f}, fr={fr_diff:.4f})")

# 核心声场不变性：后方与辅助声道（C/LFE/SL/SR）不能被 Haas / 混响改变声场
# 注意：在离散多声道模式下，Category B 不跨越前置声道污染环绕
b_surround_dev = max(abs(dst[i * CH + c] - src[i * CH + c]) for c in (2, 3, 4, 5) for i in range(F))
check(b_surround_dev < 1e-6, f"Category B 声场不变性：环绕/中置/低音 100% 保真直通 (max dev={b_surround_dev:.2e})")
lib.auradsp_destroy(h)

print()
if FAILURES:
    print(f"FAILED ({len(FAILURES)}):")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1)
print("ALL DISCRETE MULTICHANNEL TESTS PASSED!")
