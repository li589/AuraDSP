# -*- coding: utf-8 -*-
# 验证 UI 自动升档等效链路：音乐档下混响被拒 → 切品质档 → 混响放行
import ctypes

dll = ctypes.CDLL(r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll")
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]
dll.auradsp_get_latency_ms.restype = ctypes.c_double
dll.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

h = dll.auradsp_create(48000.0, 240)
i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)

# 1) 默认音乐档(1)下开混响 → 应被拒 E_LATENCY_GUARD(-3)
rc = dll.auradsp_set_param(h, b"reverb.preset", ctypes.byref(i32(0)), 4)
print("music-mode reverb rc =", rc, "| err:", dll.auradsp_last_error(h).decode())
assert rc == -3

# 2) UI 自动升档：mode.latency=2 → 混响放行
rc1 = dll.auradsp_set_param(h, b"mode.latency", ctypes.byref(i32(2)), 4)
rc2 = dll.auradsp_set_param(h, b"reverb.preset", ctypes.byref(i32(0)), 4)
lat = dll.auradsp_get_latency_ms(h)
print("quality-mode switch rc=%d, reverb rc=%d, latency=%.1f ms" % (rc1, rc2, lat))
assert rc1 == 0 and rc2 == 0 and lat == 30.0

# 3) 关闭混响 → 延迟回落 0
rc = dll.auradsp_set_param(h, b"reverb.preset", ctypes.byref(i32(-1)), 4)
print("reverb off rc=%d, latency=%.1f ms" % (rc, dll.auradsp_get_latency_ms(h)))
assert dll.auradsp_get_latency_ms(h) == 0.0

# 4) 立体声上限映射：UI 100% → 引擎 0.75
rc = dll.auradsp_set_param(h, b"stereo.mix", ctypes.byref(f32(0.75)), 4)
out_v = ctypes.c_float()
dll.auradsp_get_param(h, b"stereo.mix", ctypes.byref(out_v), 4)
print("stereo.mix set 0.75 -> get %.3f rc=%d" % (out_v.value, rc))
assert rc == 0 and abs(out_v.value - 0.75) < 1e-6

print("PASS: guard auto-upgrade flow + latency + stereo mapping all OK")
dll.auradsp_destroy(h)
