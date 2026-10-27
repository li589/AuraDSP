#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_channel_switch_reset.py — WP6 拓扑切换清理门禁。

断言（工程文档 §7.1）：
  - 8→2→8 切换后无旧布局残留；
  - 延迟按新拓扑重算；
  - 切换瞬态无爆炸（输出值有限、无爆音）。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 512
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
dll.auradsp_get_latency_ms.restype = ctypes.c_double
dll.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]


def i32(v):
    return ctypes.c_int32(v)


def f32(v):
    return ctypes.c_float(v)


class Engine:
    def __init__(self, sr=SR):
        self.h = dll.auradsp_create(float(sr), BLOCK)
        assert self.h, "auradsp_create failed"

    def close(self):
        if self.h:
            dll.auradsp_destroy(self.h)
            self.h = None

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(i32(v)), 4)

    def set_f(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(f32(v)), 4)

    def get_i(self, pid):
        v = i32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def get_f(self, pid):
        v = f32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def latency(self):
        return dll.auradsp_get_latency_ms(self.h)

    def process(self, buf):
        out = (ctypes.c_float * len(buf))()
        dll.auradsp_process(self.h, buf, out, BLOCK)
        return out


def make_sine(ch, freq=440.0, amp=0.5):
    buf = (ctypes.c_float * (BLOCK * ch))()
    for i in range(BLOCK):
        s = amp * math.sin(2.0 * math.pi * freq * i / SR)
        for c in range(ch):
            buf[i * ch + c] = s
    return buf


def make_silence(ch):
    return (ctypes.c_float * (BLOCK * ch))()


print("=== [1] 8→2→8 拓扑切换无旧布局残留 ===")
e = Engine()
e.set_i("channels.mode", 1)   # discrete
e.set_i("channels.count", 8)  # 8ch
e.set_i("filter.enable", 1)
e.set_i("gate.enable", 1)
e.set_i("dyneq.enable", 1)
e.set_i("limiter.enable", 1)

# 喂入几块大信号让滤波器/包络累积状态
hot_buf = make_sine(8, freq=1000.0, amp=0.9)
for _ in range(10):
    e.process(hot_buf)

# 切换通道数 8 -> 2（触发 reset_channel_state）
check("channels.count 8->2", e.set_i("channels.count", 2) == 0)

# 切回 8ch
check("channels.count 2->8", e.set_i("channels.count", 8) == 0)

# 喂静音，断言输出立即为 0（无上一次 8ch 状态的历史残留与拖尾）
silence = make_silence(8)
out = e.process(silence)
max_val = max(abs(out[k]) for k in range(len(out)))
check("8->2->8 切回后喂静音无残留拖尾 (max < 1e-4)", max_val < 1e-4, f"max={max_val:e}")
e.close()


print("=== [2] 拓扑切换后延迟实时重算 (M-7) ===")
e = Engine()
# 初始 stereo
e.set_i("channels.mode", 1)   # discrete
e.set_i("channels.count", 8)
e.set_i("reverb.preset", 0)   # 开启混响
# 在离散多声道下，混响为 MC FDN，延迟报 0ms
lat_discrete = e.latency()
check("离散多声道下混响延迟为 0ms", abs(lat_discrete) < 0.1, f"lat={lat_discrete}")

# 切换为矩阵模式 (mode=0)：混响变为 vendor Progenitor2，延迟增加 30ms
e.set_i("channels.mode", 0)
lat_matrix = e.latency()
check("切到矩阵模式延迟重算增加 30ms", abs(lat_matrix - 30.0) < 1.0, f"lat={lat_matrix}")

# 切回离散模式：延迟回落到 0ms
e.set_i("channels.mode", 1)
lat_discrete_again = e.latency()
check("切回离散模式延迟重算回落 0ms", abs(lat_discrete_again) < 0.1, f"lat={lat_discrete_again}")

# 开启双耳虚拟化 (spatial.binaural=1 & spatial.enable=1)
# 注意 spatial_enable 本身贡献 1ms ITD 标称延迟，混响切走 vendor reverb 贡献 30ms
e.set_i("spatial.enable", 1)
e.set_i("spatial.binaural", 1)
lat_binaural = e.latency()
check("开启双耳路径延迟重算增加 30ms (走 vendor reverb)", abs(lat_binaural - 31.0) < 0.5, f"lat={lat_binaural}")

# 关闭双耳
e.set_i("spatial.binaural", 0)
lat_no_bin = e.latency()
check("关闭双耳延迟重算回落 (仅留 spatial 1ms)", abs(lat_no_bin - 1.0) < 0.5, f"lat={lat_no_bin}")

# 关闭混响与空间音效
e.set_i("spatial.enable", 0)
e.set_i("reverb.preset", -1)
e.set_i("channels.mode", 0)
lat_reverb_off = e.latency()
check("混响与空间关闭时矩阵模式延迟亦为 0ms", abs(lat_reverb_off) < 0.1, f"lat={lat_reverb_off}")
e.close()


print("=== [3] 拓扑热切换瞬态平稳（无爆炸数值） ===")
e = Engine()
e.set_i("channels.mode", 1)
e.set_i("channels.count", 8)
sig = make_sine(8, freq=300.0, amp=0.5)

# 处理几块正常信号
for _ in range(5):
    e.process(sig)

# 在连续音频流中热切换 mode
e.set_i("channels.mode", 0)
out_switched = e.process(sig)
finite_ok = all(math.isfinite(out_switched[k]) for k in range(len(out_switched)))
max_peak = max(abs(out_switched[k]) for k in range(len(out_switched)))
check("热切换模式首块全部样本有限", finite_ok)
check("热切换模式首块无爆炸尖峰 (< 2.0)", max_peak < 2.0, f"peak={max_peak}")

e.set_i("channels.mode", 1)
out_switched_back = e.process(sig)
finite_ok2 = all(math.isfinite(out_switched_back[k]) for k in range(len(out_switched_back)))
max_peak2 = max(abs(out_switched_back[k]) for k in range(len(out_switched_back)))
check("热切回首块全部样本有限", finite_ok2)
check("热切回首块无爆炸尖峰 (< 2.0)", max_peak2 < 2.0, f"peak={max_peak2}")
e.close()


if FAIL:
    print(f"\nFAIL: {len(FAIL)} 项断言未通过")
    sys.exit(1)
print("\nchannel_switch_reset: all checks passed")
sys.exit(0)
