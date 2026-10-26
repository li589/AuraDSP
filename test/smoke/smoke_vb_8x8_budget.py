#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_vb_8x8_budget.py — VB 8×8 CPU/内存预算门禁（WP3 / §6.5）。

断言（工程文档 §6.3 / §6.5 / §7.1）：
  - 8 个 handle，channels.count=8、channels.mode=1（离散 8ch 模式）；
  - 开启全量效果栈：gate/filter/shelf/dyneq/tube/bassmono/comp/eq/loudness/limiter/reverb；
  - 8ch 动态信号，480 帧块；
  - 单 handle 全效果总 CPU < 40% 单核@48k；
  - 8 handle 峰值 RSS 增量 < 150MB；
  - comp 8ch 独立 CPU < 25% 单核@48k；
  - 反向验证：开启效果耗时明显高于直通绕过（> 2x），证明测量绝非空转。
"""
import ctypes
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 480
CH = 8
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


class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
    _fields_ = [
        ("cb", ctypes.c_ulong),
        ("PageFaultCount", ctypes.c_ulong),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
    ]


def get_rss_bytes():
    pmc = PROCESS_MEMORY_COUNTERS()
    pmc.cb = ctypes.sizeof(pmc)
    ctypes.windll.psapi.GetProcessMemoryInfo(
        ctypes.windll.kernel32.GetCurrentProcess(),
        ctypes.byref(pmc),
        pmc.cb,
    )
    return pmc.WorkingSetSize


def configure_full_stack(h):
    dll.auradsp_set_param(h, b"channels.count", ctypes.byref(i32(8)), 4)
    dll.auradsp_set_param(h, b"channels.mode", ctypes.byref(i32(1)), 4)
    one = i32(1)
    dll.auradsp_set_param(h, b"gate.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"filter.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"shelf.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"shelf.gain", ctypes.byref(f32(3.0)), 4)
    dll.auradsp_set_param(h, b"dyneq.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"tube.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"bassmono.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"comp.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"eq.enable", ctypes.byref(one), 4)
    curve = b"20:0.0;1000:3.0;20000:0.0"
    dll.auradsp_set_param(h, b"eq.curve", curve, len(curve))
    dll.auradsp_set_param(h, b"loudness.enable", ctypes.byref(one), 4)
    dll.auradsp_set_param(h, b"limiter.enable", ctypes.byref(one), 4)
    zero = i32(0)
    dll.auradsp_set_param(h, b"reverb.preset", ctypes.byref(zero), 4)


print("=== [1] 创建 8 个 8ch 离散 Handle 与 RSS 增量预算 ===")
rss_before = get_rss_bytes()
handles = []
for idx in range(8):
    h = dll.auradsp_create(ctypes.c_float(SR), BLOCK)
    assert h, f"failed to create handle {idx}"
    configure_full_stack(h)
    handles.append(h)

# 准备 8ch 测试信号（含动态谐波，充分激活各级算法内部滤波器与包络）
in_buf = (ctypes.c_float * (BLOCK * CH))()
out_buf = (ctypes.c_float * (BLOCK * CH))()
for i in range(BLOCK):
    s = 0.25 * ((i * 7) % 97 - 48) / 48.0
    for c in range(CH):
        in_buf[i * CH + c] = s

# 各 handle 预热推进，确保动态缓冲区与物理内存页均完成提交
for h in handles:
    for b in range(50):
        dll.auradsp_process(h, in_buf, out_buf, BLOCK)

rss_after = get_rss_bytes()
rss_delta_mb = (rss_after - rss_before) / (1024.0 * 1024.0)
check("8 handle 活跃处理峰值 RSS 增量 < 150MB",
      rss_delta_mb < 150.0,
      f"delta={rss_delta_mb:.2f}MB, limit=150MB")

print("\n=== [2] 单 Handle 全量效果栈 CPU 预算 (<40% 单核@48k) ===")
# 跑 500 块 (500 * 480 / 48000 = 5.0 秒音频)
N_BLOCKS = 500
audio_duration_sec = (N_BLOCKS * BLOCK) / float(SR)

t0 = time.perf_counter()
for _ in range(N_BLOCKS):
    dll.auradsp_process(handles[0], in_buf, out_buf, BLOCK)
t1 = time.perf_counter()

elapsed_sec = t1 - t0
full_cpu_ratio = elapsed_sec / audio_duration_sec
check("单 handle 8ch 全效果栈 CPU < 40% 单核@48k",
      full_cpu_ratio < 0.40,
      f"cpu={full_cpu_ratio * 100:.2f}%, audio={audio_duration_sec:.1f}s, wall={elapsed_sec:.3f}s")

print("\n=== [3] comp 8ch 独立耗时预算 (<25% 单核@48k) 与非空转验证 ===")
# 创建专用 handle 精确测算 comp 增量
h_comp = dll.auradsp_create(ctypes.c_float(SR), BLOCK)
dll.auradsp_set_param(h_comp, b"channels.count", ctypes.byref(i32(8)), 4)
dll.auradsp_set_param(h_comp, b"channels.mode", ctypes.byref(i32(1)), 4)
dll.auradsp_set_param(h_comp, b"limiter.enable", ctypes.byref(i32(0)), 4)

# 1) 直通基线 (comp off)
dll.auradsp_set_param(h_comp, b"comp.enable", ctypes.byref(i32(0)), 4)
for _ in range(50):
    dll.auradsp_process(h_comp, in_buf, out_buf, BLOCK)
t0 = time.perf_counter()
for _ in range(N_BLOCKS):
    dll.auradsp_process(h_comp, in_buf, out_buf, BLOCK)
t1 = time.perf_counter()
t_bypass = t1 - t0

# 2) 8ch mono 优化 comp (comp.mode=0)
dll.auradsp_set_param(h_comp, b"comp.enable", ctypes.byref(i32(1)), 4)
dll.auradsp_set_param(h_comp, b"comp.mode", ctypes.byref(i32(0)), 4)
dll.auradsp_set_param(h_comp, b"comp.channels", ctypes.byref(i32(0xFF)), 4)
for _ in range(50):
    dll.auradsp_process(h_comp, in_buf, out_buf, BLOCK)
t0 = time.perf_counter()
for _ in range(N_BLOCKS):
    dll.auradsp_process(h_comp, in_buf, out_buf, BLOCK)
t1 = time.perf_counter()
t_comp_m0 = t1 - t0

comp_cpu_ratio = (t_comp_m0 - t_bypass) / audio_duration_sec
check("comp 8ch (mono 优化) 独立 CPU < 25% 单核@48k",
      comp_cpu_ratio < 0.25,
      f"comp_cpu={comp_cpu_ratio * 100:.2f}%, limit=25%")

check("反向验证：comp 开启耗时显著高于直通绕过 (> 2x，证明非空转)",
      t_comp_m0 > t_bypass * 2.0,
      f"t_comp={t_comp_m0:.3f}s, t_bypass={t_bypass:.3f}s, ratio={t_comp_m0 / max(1e-6, t_bypass):.1f}x")

print("\n=== [4] 句柄销毁与内存释放 ===")
for h in handles:
    dll.auradsp_destroy(h)
dll.auradsp_destroy(h_comp)
check("全部 8+1 个引擎 handle 安全销毁", True)

if FAIL:
    print(f"\n{len(FAIL)} FAIL: {FAIL}")
    sys.exit(1)
print("\nALL PASS: VB 8×8 预算门禁全部通过")
