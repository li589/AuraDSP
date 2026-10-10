"""probe_latency.py — 组件延迟实测输出（开发诊断）

用真实脉冲响应测量各组件的算法延迟并换算成 ms。
注意 convolver / ddc / liveprog 需要外部资源，探针无法就绪，如实返回不可测。
运行：python tools/probe_latency.py
"""
import ctypes
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")
lib = ctypes.CDLL(DLL)
lib.auradsp_probe_component.restype = ctypes.c_int32
lib.auradsp_probe_component.argtypes = [ctypes.c_char_p, ctypes.c_double,
                                       ctypes.POINTER(ctypes.c_uint32)]

RATE = 48000.0
COMPONENTS = ['bass', 'reverb', 'eq', 'tube', 'crossfeed', 'limiter',
              'post', 'shelf', 'convolver', 'ddc', 'liveprog', 'bogus_name']

print(f"{'component':<14}{'samples':>10}{'ms@48k':>10}{'probe ms':>10}  note")
print("-" * 62)
total_ms = 0.0
for comp in COMPONENTS:
    out = ctypes.c_uint32(0)
    t0 = time.perf_counter()
    rc = lib.auradsp_probe_component(comp.encode(), RATE, ctypes.byref(out))
    dt = (time.perf_counter() - t0) * 1000.0
    if rc != 0:
        note = {-1: '不支持（需外部资源）', -2: '探针创建失败',
                -3: '无法测量（组件未真正生效）'}.get(rc, f'rc={rc}')
        print(f"{comp:<14}{'-':>10}{'-':>10}{dt:>9.1f}  {note}")
        continue
    ms = out.value / RATE * 1000.0
    total_ms += ms
    print(f"{comp:<14}{out.value:>10}{ms:>10.2f}{dt:>10.1f}")
print("-" * 62)
print(f"{'可测合计':<14}{'':>10}{total_ms:>10.2f}   (实测，非查表)")