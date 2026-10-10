"""smoke_config_and_matrix.py — 验证 AppConfig 接线(D1) 与多声道矩阵混音(D8/ADR-003)

覆盖：
  [1] gate.maxIrSeconds / gate.maxFileMb 真正改变 FileGate 行为（D1）
  [2] viz.fftSize 参数校验与生效（D1）
  [3] channels.count 声道数契约：只接受 2/6/8（D8）
  [4] 5.1 矩阵：LFE 直通 / 环绕并入 L&R / 上混回填（D8）
  [5] 立体声路径未被多声道改造影响（D8 不回归保证）
"""
import ctypes
import math
import os
import struct
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
if not os.path.exists(DLL):
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


def set_i32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def set_f32(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)


def get_i32(h, k):
    out = ctypes.c_int32(0)
    rc = lib.auradsp_get_param(h, k.encode(), ctypes.byref(out), 4)
    return rc, out.value


def get_f32(h, k):
    out = ctypes.c_float(0.0)
    rc = lib.auradsp_get_param(h, k.encode(), ctypes.byref(out), 4)
    return rc, out.value


def check(cond, label):
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}")
        FAILURES.append(label)


def new_engine(rate=48000.0, block=2048):
    h = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(rate), block))
    if not h:
        print("FATAL: auradsp_create failed")
        sys.exit(1)
    set_i32(h, "mode.latency", 2)
    return h


def process(h, frames, ch):
    n = frames * ch
    buf = (ctypes.c_float * n)()
    out = (ctypes.c_float * n)()
    return buf, out, ctypes.cast(buf, ctypes.POINTER(ctypes.c_float)), \
        ctypes.cast(out, ctypes.POINTER(ctypes.c_float))


# ---------------------------------------------------------------- [1] FileGate
print("=== [1] gate.maxIrSeconds / gate.maxFileMb 真正生效 (D1) ===")
tmpdir = tempfile.mkdtemp(prefix="aura_gate_")
ir_path = os.path.join(tmpdir, "long.wav")
RATE = 48000
SECONDS = 40.0
frames = int(RATE * SECONDS)
with open(ir_path, "wb") as f:
    # 用衰减正弦而非静音：FileGate 会以 "all-silent IR" 拒收全零 IR，
    # 那样就测不到时长门卫了。
    data = b"".join(
        struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440.0 * n / RATE)
                              * math.exp(-2.0 * n / frames)))
        for n in range(frames))
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + \
        struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16) + \
        b"data" + struct.pack("<I", len(data))
    f.write(hdr + data)

h = new_engine()
set_i32(h, "channels.mode", 0)
set_i32(h, "mode.latency", 2)

rc, v = get_f32(h, "gate.maxIrSeconds")
check(rc == 0 and abs(v - 30.0) < 1e-4, f"gate.maxIrSeconds 默认 30s (got {v})")
set_f32(h, "gate.maxIrSeconds", 5.0)
rc, v = get_f32(h, "gate.maxIrSeconds")
check(abs(v - 5.0) < 1e-4, f"gate.maxIrSeconds 可写可回读 (got {v})")

buf = ir_path.encode()
n = len(buf)
cbuf = ctypes.create_string_buffer(buf)
rc = lib.auradsp_set_param(h, b"convolver.ir.path", cbuf, n)
# 40s IR 在 5s 上限下必须被拒
check(rc != 0, f"40s IR 在 gate.maxIrSeconds=5 下被拒 (rc={rc})")

set_f32(h, "gate.maxIrSeconds", 60.0)
cbuf = ctypes.create_string_buffer(buf)
rc = lib.auradsp_set_param(h, b"convolver.ir.path", cbuf, n)
check(rc == 0, f"40s IR 在 gate.maxIrSeconds=60 下放行 (rc={rc})")

rc, v = get_f32(h, "gate.maxFileMb")
check(abs(v - 64.0) < 1e-4, f"gate.maxFileMb 默认 64 (got {v})")
set_f32(h, "gate.maxFileMb", 1.0)
cbuf = ctypes.create_string_buffer(buf)
rc = lib.auradsp_set_param(h, b"convolver.ir.path", cbuf, n)
check(rc != 0, f"大文件在 gate.maxFileMb=1 下被拒 (rc={rc})")
lib.auradsp_destroy(h)

# ---------------------------------------------------------------- [2] viz.fftSize
print("\n=== [2] viz.fftSize 参数 (D1) ===")
h = new_engine()
rc, v = get_i32(h, "viz.fftSize")
check(rc == 0 and v == 4096, f"viz.fftSize 默认 4096 (got {v})")
check(set_i32(h, "viz.fftSize", 2048) == 0, "viz.fftSize=2048 接受")
rc, v = get_i32(h, "viz.fftSize")
check(v == 2048, f"viz.fftSize 回读 2048 (got {v})")
check(set_i32(h, "viz.fftSize", 3000) != 0, "viz.fftSize=3000 (非2的幂) 拒绝")
check(set_i32(h, "viz.fftSize", 512) != 0, "viz.fftSize=512 (<1024) 拒绝")
check(set_i32(h, "viz.fftSize", 16384) != 0, "viz.fftSize=16384 (>8192) 拒绝")
lib.auradsp_destroy(h)

# ---------------------------------------------------------------- [3] channels.count
print("\n=== [3] channels.count 契约 (D8) ===")
h = new_engine()
rc, v = get_i32(h, "channels.count")
check(rc == 0 and v == 2, f"channels.count 默认 2 (got {v})")
check(set_i32(h, "channels.count", 6) == 0, "channels.count=6 (5.1) 接受")
check(set_i32(h, "channels.count", 8) == 0, "channels.count=8 (7.1) 接受")
for bad in (1, 3, 4, 5, 7, 0, -1):
    check(set_i32(h, "channels.count", bad) != 0, f"channels.count={bad} 拒绝")
rc, v = get_i32(h, "channels.count")
check(v == 8, f"拒绝后保持原值 8 (got {v})")
lib.auradsp_destroy(h)

# ---------------------------------------------------------------- [4] 5.1 矩阵
print("\n=== [4] 5.1 矩阵下混/上混 (D8/ADR-003 Phase A) ===")
CH = 6   # FL FR C LFE SL SR
F = 256
h = new_engine()
set_i32(h, "channels.count", CH)
set_i32(h, "channels.mode", 0)

# 开一条有增益的处理链，确保矩阵在"处理中"状态下也被正确处理
set_i32(h, "bass.enable", 1)
set_f32(h, "bass.gain", 3.0)

# 用真实音频（440Hz）而非直流：直流经 bass shelf + 输出限幅的结果没有物理意义，
# 断言"幅度上升"会变成对限幅器的猜测。改为断言"确实被处理过且非直通"。
src, dst, sp, dp = process(h, F, CH)
for i in range(F):
    s = 0.25 * math.sin(2 * math.pi * 440.0 * i / 48000.0)
    for c in range(CH):
        src[i * CH + c] = s
lib.auradsp_process(h, sp, dp, F)

# LFE 必须是**原样直通**：输入正弦，输出应与之逐样本相同（DSP 完全不碰它）
lfe_ok = True
max_dev = 0.0
for i in range(F):
    want = src[i * CH + 3]
    dev = abs(dst[i * CH + 3] - want)
    max_dev = max(max_dev, dev)
    if dev > 1e-6:
        lfe_ok = False
check(lfe_ok, f"LFE 逐样本直通不经 DSP (max dev={max_dev:.2e})")

# 前置 L/R 必须被链处理过：与输入存在可测差异，且幅度在合理范围内
diff = sum(abs(dst[i * CH + 0] - src[i * CH + 0]) for i in range(F)) / F
fl_rms = math.sqrt(sum(dst[i * CH + 0] ** 2 for i in range(F)) / F)
in_rms = 0.25 / math.sqrt(2.0)
check(diff > 1e-3, f"FL 被处理链修改（与输入平均差 {diff:.4f}）")
check(0.2 < fl_rms / in_rms < 3.0,
      f"FL 幅度在合理范围 (in_rms={in_rms:.4f} out_rms={fl_rms:.4f})")

# 环绕声道应被回填（非零，且量级合理）
sl_rms = math.sqrt(sum(dst[i * CH + 4] ** 2 for i in range(F)) / F)
check(sl_rms > 1e-4, f"SL 被上混回填非零 (rms={sl_rms:.4f})")
check(sl_rms < fl_rms, "SL 回填增益小于前置 (0.7 < 1.0)")

# 仅在 SL 有信号时，它必须出现在 L/R（下混生效）
for i in range(F):
    for c in range(CH):
        src[i * CH + c] = 0.0
    src[i * CH + 4] = 0.5
lib.auradsp_process(h, sp, dp, F)
check(abs(dst[0 * CH + 4]) > 1e-4, "仅 SL 有信号时 SL 输出非零")
check(abs(dst[0 * CH + 0]) > 1e-4, "仅 SL 有信号时 FL 得到下混内容 (LFE 不受 SL 影响)")
check(abs(dst[0 * CH + 3]) < 1e-6, "仅 SL 有信号时 LFE 保持静音")
lib.auradsp_destroy(h)

# ---------------------------------------------------------------- [5] 立体声不回归
print("\n=== [5] 立体声路径不受多声道改造影响 ===")
h = new_engine()
N = 512
src, dst, sp, dp = process(h, N, 2)
for i in range(N):
    src[i * 2] = 0.4 * math.sin(2 * math.pi * 440.0 * i / 48000.0)
    src[i * 2 + 1] = 0.3 * math.sin(2 * math.pi * 660.0 * i / 48000.0)
lib.auradsp_process(h, sp, dp, N)
in_rms = math.sqrt(sum((src[i * 2] ** 2) for i in range(N)) / N)
out_rms = math.sqrt(sum((dst[i * 2] ** 2) for i in range(N)) / N)
check(0.5 < out_rms / in_rms < 2.0,
      f"立体声直通比例合理 (in={in_rms:.4f} out={out_rms:.4f})")
lib.auradsp_destroy(h)

try:
    os.remove(ir_path)
    os.rmdir(tmpdir)
except OSError:
    pass

print()
if FAILURES:
    print(f"FAILED ({len(FAILURES)}):")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1)
print("ALL TESTS PASSED: AppConfig wiring (D1) + multichannel matrix (D8/ADR-003) 100% OK!")