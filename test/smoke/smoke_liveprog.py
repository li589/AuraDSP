# -*- coding: utf-8 -*-
# M2 Liveprog 引擎级验证：代码加载/编译错误/滑块/使能旁路/卸载/回读
import ctypes, math

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
def set_f(pid, v): return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(f32(v)), 4)
def set_str(pid, s):
    b = s.encode("utf-8")
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return dll.auradsp_set_param(h, pid.encode(), buf, len(b))
def get_i(pid):
    v = ctypes.c_int32()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value
def get_f(pid):
    v = ctypes.c_float()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value
def get_str(pid, n=4096):
    buf = ctypes.create_string_buffer(n)
    rc = dll.auradsp_get_param(h, pid.encode(), buf, n)
    return rc, buf.value.decode("utf-8", "replace")

N = 480
buf = (ctypes.c_float * (N*2))()
out = (ctypes.c_float * (N*2))()

def peak():
    return max(abs(out[i]) for i in range(N*2))

def run_blocks(k=30):
    ph = 0.0
    for _ in range(k):
        for n in range(N):
            s = 0.3 * math.sin(ph)
            ph += 2*math.pi*220.0/48000.0
            buf[2*n] = s; buf[2*n+1] = s
        dll.auradsp_process(h, buf, out, N)

script = """/* 增益 × slider1（实时读值） */
@init
dbg = 1;
@sample
spl0 *= slider1;
spl1 *= slider1;
"""

# 1) 正常脚本加载
rc = set_str("liveprog.code", script)
st = get_i("liveprog.status")
print("1) code rc=%d status=%d err=%s" % (rc, st, dll.auradsp_last_error(h).decode()))
assert rc == 0 and st == 1

# 2) 滑块增益 2.0 + 使能 → 输出翻倍
assert set_f("liveprog.param1", 2.0) == 0
assert set_i("liveprog.enable", 1) == 0
run_blocks(40)   # 预热（脚本 VM 状态稳定）
run_blocks(3)
p = peak()
print("2) enabled gain: out_peak=%.4f (expect 0.6)" % p)
assert abs(p - 0.6) < 0.01, p

# 3) 停用 → 直通
set_i("liveprog.enable", 0)
run_blocks(3)
p = peak()
print("3) disabled: out_peak=%.4f (expect 0.3)" % p)
assert abs(p - 0.3) < 0.01, p

# 4) 语法错误 → E_PARAM + 文案
bad = "@init\nthis is not eel (((\n@sample\nspl0 *= 2;\n"
rc = set_str("liveprog.code", bad)
err = dll.auradsp_last_error(h).decode()
st = get_i("liveprog.status")
print("4) bad code rc=%d status=%d err=%r" % (rc, st, err))
assert rc != 0 and st != 1 and "Syntax error" in err

# 5) 重新加载好脚本恢复 + 滑块值保持
rc = set_str("liveprog.code", script)
st = get_i("liveprog.status")
set_i("liveprog.enable", 1)
run_blocks(40); run_blocks(3)
p = peak()
print("5) reload ok rc=%d status=%d, slider1 persisted=%.1f -> peak=%.4f" % (
    rc, st, get_f("liveprog.param1"), p))
assert rc == 0 and st == 1 and abs(p - 0.6) < 0.01

# 6) 代码回读
rc, code_out = get_str("liveprog.code")
print("6) code roundtrip rc=%d match=%s len=%d" % (rc, code_out == script, len(code_out)))
assert rc == 0 and code_out == script

# 7) unload → status 0 + 直通
assert set_i("liveprog.unload", 0) == 0
st = get_i("liveprog.status")
en = get_i("liveprog.enable")
run_blocks(3)
p = peak()
print("7) unload: status=%d enable=%d peak=%.4f" % (st, en, p))
assert st == 0 and en == 0 and abs(p - 0.3) < 0.01

print("PASS: liveprog engine flow all OK")
