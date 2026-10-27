# -*- coding: utf-8 -*-
# ADR-006 契约：延迟不再有任何准入判定
#
# 撤销前本用例断言「默认档开混响 → E_LATENCY_GUARD(-3) → 切 quality 放行」。
# 该行为随 ADR-002 于 ADR-006 一并撤销，故本用例改为钉住新契约：
#   1) 混响/卷积/Freeverb 一律自由使能（不再返回 -3）；
#   2) mode.latency 已是非法入参（明确 -1，而非静默忽略）；
#   3) 延迟读数仍如实累加上报（测量量，不是闸门）。
import ctypes

dll = ctypes.CDLL(r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll")
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]
dll.auradsp_get_latency_ms.restype = ctypes.c_double
dll.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

h = dll.auradsp_create(48000.0, 240)
i32 = lambda v: ctypes.c_int32(v)
f32 = lambda v: ctypes.c_float(v)

# 1) 混响自由使能：rc 必须为 0，绝不是 -3（E_LATENCY_GUARD）
rc = dll.auradsp_set_param(h, b"reverb.preset", ctypes.byref(i32(0)), 4)
print("reverb preset rc =", rc, "| err:", dll.auradsp_last_error(h).decode())
assert rc == 0, "ADR-006: reverb must be freely enableable, got rc=%d" % rc
# 30ms 混响。D7（2026-10-24）修正：旧断言按"30 混响 + 2 limiter 默认"算 32ms，
# 但 limiter 的 2.0ms 是名义值虚报 —— limiter.lookahead 默认 0（0ms 实时模式），
# 脉冲实测位移确实为 0；只有 lookahead=1 才有 ~1.5ms 前瞻缓冲。
# 故默认配置下正确值就是 30ms（D7 门禁 smoke_d7_asrc_consistency.py 锁死）。
assert abs(dll.auradsp_get_latency_ms(h) - 30.0) < 0.05, (
    "reverb latency must be 30ms (limiter default lookahead=0 contributes 0ms), got %.3f"
    % dll.auradsp_get_latency_ms(h))

# 2) Freeverb / 卷积同样自由使能
rc_fv = dll.auradsp_set_param(h, b"freeverb.enable", ctypes.byref(i32(1)), 4)
print("freeverb.enable rc =", rc_fv)
assert rc_fv == 0, "ADR-006: freeverb must be freely enableable"

# 3) mode.latency 已是非法入参：明确报错(E_PARAM=-1)，不静默忽略
rc_mode = dll.auradsp_set_param(h, b"mode.latency", ctypes.byref(i32(2)), 4)
print("mode.latency rc =", rc_mode, "| err:", dll.auradsp_last_error(h).decode())
assert rc_mode == -1, "ADR-006: mode.latency must be rejected as invalid param"

out_i = ctypes.c_int32()
rc_get = dll.auradsp_get_param(h, b"mode.latency", ctypes.byref(out_i), 4)
print("mode.latency get rc =", rc_get)
assert rc_get == -1, "ADR-006: mode.latency must not be readable"

# 4) 延迟读数仍如实累加（测量量），关闭后回落
# 回落值 = 2ms limiter 基线（2026-10-16 决策 #1：UI 为真，limiter_enable
# 默认 1；混响 -1 关闭后仅剩 limiter 计入）
rc_off = dll.auradsp_set_param(h, b"reverb.preset", ctypes.byref(i32(-1)), 4)
lat_off = dll.auradsp_get_latency_ms(h)
print("reverb off rc=%d, latency=%.1f ms" % (rc_off, lat_off))
# D7：limiter 默认 lookahead=0 → 贡献 0ms，故全关时基线应为 0（原断言 2.0）。
assert rc_off == 0 and abs(lat_off) < 0.05, (
    "all-off baseline must be 0ms (limiter default lookahead=0), got %.3f" % lat_off)

# 5) 立体声上限映射：UI 100% → 引擎 0.75
rc = dll.auradsp_set_param(h, b"stereo.mix", ctypes.byref(f32(0.75)), 4)
out_v = ctypes.c_float()
dll.auradsp_get_param(h, b"stereo.mix", ctypes.byref(out_v), 4)
print("stereo.mix set 0.75 -> get %.3f rc=%d" % (out_v.value, rc))
assert rc == 0 and abs(out_v.value - 0.75) < 1e-6

print("PASS: ADR-006 no-latency-gating contract + latency measurement + stereo mapping")
dll.auradsp_destroy(h)