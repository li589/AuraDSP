import ctypes
import os
import struct

DLL_PATH = r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll"
DIR = r"D:\temp_desktop\Proj\JamesDSP\.tmp\irtest"
os.makedirs(DIR, exist_ok=True)

# 生成一个简单的立体声 IR (48kHz, 256 采样点)
# L 通道为尖锐 delta 脉冲 (宽带响应)
# R 通道为低通滤波脉冲 (高频滚降)
RATE = 48000
N = 256
l_data = [1.0] + [0.0] * (N - 1)
# 简单指数衰减高频模拟低通
r_data = [math_exp for math_exp in [math__v for math__v in [0.9 * (0.8 ** i) for i in range(N)]]]

def write_wav16(path, frames_l, frames_r, rate):
    data = b"".join(struct.pack("<hh", int(max(-1, min(1, l)) * 32767),
                                      int(max(-1, min(1, r)) * 32767))
                    for l, r in zip(frames_l, frames_r))
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16)
    hdr += b"data" + struct.pack("<I", len(data))
    with open(path, "wb") as f:
        f.write(hdr + data)

test_ir = os.path.join(DIR, "test_stereo_ir.wav")
write_wav16(test_ir, l_data, r_data, RATE)

dll = ctypes.CDLL(DLL_PATH)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]

h = dll.auradsp_create(48000.0, 512)
assert h, "create failed"

# 加载 IR
path_bytes = test_ir.encode("utf-8")
rc = dll.auradsp_set_param(h, b"convolver.ir.path", path_bytes, len(path_bytes))
print(f"1) load IR rc: {rc}")
assert rc == 0, f"load failed rc={rc}"

# 读取声道数
ch = ctypes.c_int32(0)
rc = dll.auradsp_get_param(h, b"convolver.ir.channels", ctypes.byref(ch), 4)
print(f"2) channels: {ch.value}")
assert ch.value == 2, f"expected 2 channels, got {ch.value}"

# 读取 32 带频谱 (2 声道 * 32 浮点 = 64 floats)
spec_buf = (ctypes.c_float * 64)()
rc = dll.auradsp_get_param(h, b"convolver.ir.spectrum", spec_buf, ctypes.sizeof(spec_buf))
print(f"3) get spectrum rc: {rc}")
assert rc == 0, f"get spectrum failed rc={rc}"

l_bands = list(spec_buf[:32])
r_bands = list(spec_buf[32:])

print(f"4) L 通道前 8 带: {[round(x, 3) for x in l_bands[:8]]}")
print(f"   R 通道前 8 带: {[round(x, 3) for x in r_bands[:8]]}")

# 校验数值有效性
assert all(0.0 <= v <= 1.0 for v in l_bands), "L bands out of range [0, 1]"
assert all(0.0 <= v <= 1.0 for v in r_bands), "R bands out of range [0, 1]"
assert any(v > 0.1 for v in l_bands), "L bands all zero"
assert any(v > 0.1 for v in r_bands), "R bands all zero"

# 清除并检验
rc = dll.auradsp_set_param(h, b"convolver.clear", ctypes.byref(ctypes.c_int32(0)), 4)
rc_clear = dll.auradsp_get_param(h, b"convolver.ir.spectrum", spec_buf, ctypes.sizeof(spec_buf))
print(f"5) clear 后 get_param rc: {rc_clear} (非0即状态拒绝)")
assert rc_clear != 0, "clear 后应拒绝读取"

dll.auradsp_destroy(h)
print("PASS: smoke_convolver_spectrum passed successfully!")
