# -*- coding: utf-8 -*-
# M4 卷积/IR + FileGate 引擎级验证
import ctypes, math, struct, os

DIR = r"D:\temp_desktop\Proj\JamesDSP\.tmp\irtest"
os.makedirs(DIR, exist_ok=True)

def write_wav16(path, frames_l, frames_r, rate):
    n = len(frames_l)
    data = b"".join(struct.pack("<hh", int(max(-1, min(1, l)) * 32767),
                                      int(max(-1, min(1, r)) * 32767))
                    for l, r in zip(frames_l, frames_r))
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16)
    hdr += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as f:
        f.write(hdr + data)

def write_wavf32(path, ch_data, rate, float32=True):
    nch = len(ch_data); n = len(ch_data[0])
    fmt_tag = 3 if float32 else 1
    bps = 4 if float32 else 2
    data = b"".join(struct.pack("<" + "f" * nch, *[ch_data[c][i] for c in range(nch)])
                    for i in range(n))
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, fmt_tag, nch, rate, rate * nch * bps, nch * bps, bps * 8)
    hdr += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as f:
        f.write(hdr + data)

# --- 测试文件 ---
# 1) 48k 立体声 delta IR（左右都在 0 点 = 单位冲激 → 直通）
N = 64
write_wav16(os.path.join(DIR, "delta48.wav"), 
            [1.0] + [0.0] * (N - 1), [1.0] + [0.0] * (N - 1), 48000)
# 2) 44.1k delta（重采样路径）
write_wav16(os.path.join(DIR, "delta44.wav"),
            [1.0] + [0.0] * (N - 1), [1.0] + [0.0] * (N - 1), 44100)
# 3) 纯乱字节（未知格式）
with open(os.path.join(DIR, "garbage.bin"), "wb") as f:
    f.write(os.urandom(1024))
# 4) 假 WAV（RIFF 头 + 垃圾）
with open(os.path.join(DIR, "fake.wav"), "wb") as f:
    f.write(b"RIFF" + struct.pack("<I", 1000) + b"WAVE" + os.urandom(512))
# 5) 含 NaN 的 float32 WAV
nan_l = [float("nan")] * 16
nan_r = [0.0] * 16
write_wavf32(os.path.join(DIR, "nan.wav"), [nan_l, nan_r], 48000)
# 6) 截断 WAV（头声明 64 帧，实际只写 10 帧）
half = [1.0] + [0.0] * 9
data = b"".join(struct.pack("<hh", int(l * 32767), int(r * 32767)) for l, r in zip(half, half))
hdr = b"RIFF" + struct.pack("<I", 36 + N * 4) + b"WAVE"
hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, 48000, 48000 * 4, 4, 16)
hdr += b"data" + struct.pack("<I", N * 4)
with open(os.path.join(DIR, "trunc.wav"), "wb") as f:
    f.write(hdr + data)

dll = ctypes.CDLL(r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll")
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]

h = dll.auradsp_create(48000.0, 480)
i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)
def set_i(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(i32(v)), 4)
def set_str(pid, s):
    b = s.encode("utf-8")
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))
def get_i(pid):
    v = ctypes.c_int32(); dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4); return v.value
def get_f(pid):
    v = ctypes.c_float(); dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4); return v.value
def err(): return dll.auradsp_last_error(h).decode()

N = 480
buf = (ctypes.c_float * (N * 2))()
out = (ctypes.c_float * (N * 2))()

def run(k=3):
    ph = 0.0
    for _ in range(k):
        for n in range(N):
            s = 0.3 * math.sin(ph)
            ph += 2 * math.pi * 220.0 / 48000.0
            buf[2 * n] = s; buf[2 * n + 1] = s
        dll.auradsp_process(h, buf, out, N)

def snapshot():
    return [out[i] for i in range(N * 2)]

# 1) 门卫：未知格式 / 假 WAV / NaN / 截断
for fn, want in [("garbage.bin", "unknown format"), ("fake.wav", "corrupt|truncated|invalid"),
                 ("nan.wav", "NaN/Inf"), ("trunc.wav", "truncated")]:
    rc = set_str("convolver.ir.path", os.path.join(DIR, fn))
    e = err()
    print("1) %-12s rc=%d err=%r" % (fn, rc, e))
    assert rc != 0
# 2) 48k delta 加载 + 元数据
rc = set_str("convolver.ir.path", os.path.join(DIR, "delta48.wav"))
print("2) delta48 load rc=%d ready=%d frames=%d ch=%d src=%d peak=%.2f" % (
    rc, get_i("convolver.ready"), get_i("convolver.ir.frames"),
    get_i("convolver.ir.channels"), get_i("convolver.ir.srcRate"), get_f("convolver.ir.peak")))
assert rc == 0 and get_i("convolver.ready") == 1 and get_i("convolver.ir.channels") == 2
assert get_i("convolver.ir.srcRate") == 48000 and abs(get_f("convolver.ir.peak") - 1.0) < 0.01
# 3) 守卫：音乐档使能 → 拒绝；品质档 → 放行 + 延迟 10ms
rc = set_i("convolver.enable", 1)
print("3) music-mode enable rc=%d err=%r" % (rc, err()))
assert rc == -3 and "T2" in err()
assert set_i("mode.latency", 2) == 0
assert set_i("convolver.enable", 1) == 0
lat = ctypes.c_double(); 
dll.auradsp_get_latency_ms.restype = ctypes.c_double
dll.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]
print("3) quality enable ok, latency=%.1f ms" % dll.auradsp_get_latency_ms(h))
assert abs(dll.auradsp_get_latency_ms(h) - 10.0) < 0.01
# 4) delta 卷积 = 直通
run(40); run(2)
sig = snapshot()
p = max(abs(v) for v in sig)
ref = max(abs(buf[i]) for i in range(N * 2))
diff = max(abs(sig[i] - buf[i]) for i in range(N * 2))
print("4) passthrough: out_peak=%.4f max_diff=%.2e" % (p, diff))
assert abs(p - 0.3) < 0.01 and diff < 1e-3
# 5) 44.1k delta 重采样加载
rc = set_str("convolver.ir.path", os.path.join(DIR, "delta44.wav"))
print("5) delta44 rc=%d src=%d frames=%d ready=%d" % (
    rc, get_i("convolver.ir.srcRate"), get_i("convolver.ir.frames"), get_i("convolver.ready")))
assert rc == 0 and get_i("convolver.ir.srcRate") == 44100 and get_i("convolver.ready") == 1
# 6) 停用 → 直通恢复
set_i("convolver.enable", 0)
run(40); run(2)
diff2 = max(abs(snapshot()[i] - buf[i]) for i in range(N * 2))
print("6) disabled diff=%.2e" % diff2)
assert diff2 < 1e-3
# 7) clear
assert set_i("convolver.clear", 0) == 0
print("7) clear: ready=%d enable=%d" % (get_i("convolver.ready"), get_i("convolver.enable")))
assert get_i("convolver.ready") == 0 and get_i("convolver.enable") == 0
print("PASS: convolver + FileGate engine flow all OK")
