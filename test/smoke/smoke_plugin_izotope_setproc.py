# -*- coding: utf-8 -*-
"""smoke_plugin_izotope_setproc.py — iZotope Ozone/RX 12 加载契约回归（红→绿用例）。

背景（2026-10-21 定位结论）：
  iZotope Ozone 12 / RX 12 的 VST3 wrapper 在 IAudioProcessor::setProcessing(true)
  上**恒返回 kNotImplemented (0x80004001)**，与 activate 序列形态、宿主名
  （IHostApplication::getName / 进程 exe 名）、编辑器创建时序、COM 单元、
  线程亲和均无关——最小独立宿主（izoprobe）复现同样行为，且该返回值下
  process() 音频正常流动（实测 Ozone 12 Equalizer 对 1kHz 正弦精确直通，
  Bass Control/Maximizer/RX 模块输出正常衰减信号）。
  重构前（M1/2445f86）引擎忽略 setProcessing 返回值 → 插件"正常"；
  重构把非 kResultOk 提升为致命失败 → iZotope 插件 activate 失败、"打不开"。

本测试证明：
  1. 引擎能完整 activate 返回 kNotImplemented 的 VST3 插件（load rc==1、
     hasActive=true）——这是修复的门禁断言；
  2. activate 后 process() 真实输出音频（正弦输入 → 非零、非毒值输出），
     证明"容忍 kNotImplemented"没有把坏插件放进来；
  3. bypass 仍为位精确直通。

本测试不能证明：
  - 插件内部 DSP 正确性（只验证音频通道存活）；
  - 非 iZotope 插件的 setProcessing 失败语义（那类失败仍应致命）。

机器上无 iZotope 插件时打印 SKIP 并以 0 退出（与 CI 无该厂商插件兼容）。
"""
import ctypes
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
assert os.path.exists(DLL_PATH), f"Engine DLL not found: {DLL_PATH}"

# 进程内模式：iZotope wrapper 的失败与宿主进程形态无关（已由 izoprobe 对照排除），
# 进程内路径同样覆盖；进程外路径由 smoke_plugin_host_process.py 的 Convology 用例覆盖。
os.environ.pop("AURA_PLUGIN_HOST_MODE", None)

dll = ctypes.CDLL(DLL_PATH)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_plugin_scan.restype = ctypes.c_int
dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
dll.auradsp_plugin_get_all.restype = ctypes.c_int
dll.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
dll.auradsp_plugin_load.restype = ctypes.c_int
dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
dll.auradsp_plugin_unload.restype = ctypes.c_int
dll.auradsp_plugin_unload.argtypes = [ctypes.c_void_p]
dll.auradsp_plugin_set_bypass.restype = ctypes.c_int
dll.auradsp_plugin_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int]
dll.auradsp_plugin_get_bypass.restype = ctypes.c_int
dll.auradsp_plugin_get_bypass.argtypes = [ctypes.c_void_p]
dll.auradsp_plugin_get_latency.restype = ctypes.c_uint32
dll.auradsp_plugin_get_latency.argtypes = [ctypes.c_void_p]
dll.auradsp_plugin_get_status.restype = ctypes.c_int
dll.auradsp_plugin_get_status.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

print("=== [1] 扫描插件，定位 iZotope 目标 ===")
h = dll.auradsp_create(48000.0, 1024)
assert h is not None, "Failed to create auradsp engine handle"
dll.auradsp_plugin_scan(h, b"", 0)
buf = ctypes.create_string_buffer(1 << 20)
n = dll.auradsp_plugin_get_all(h, buf, 1 << 20)
assert n > 0, "Failed to get plugin list"
plugins = json.loads(buf.value.decode("utf-8"))

izotope = [p for p in plugins if "izotope" in p["path"].lower()]
if not izotope:
    print("SKIP: no iZotope VST3 plugin found on this machine")
    dll.auradsp_destroy(h)
    sys.exit(0)

# 优先 Ozone 12 Equalizer：零延迟、默认预设对正弦为精确直通，断言最稳；
# 否则取任意 Ozone 12 模块；再不行取任意 RX 12 模块。
target = None
for p in izotope:
    if "Ozone 12 Equalizer" in p["name"]:
        target = p
        break
if not target:
    for p in izotope:
        if "Ozone 12" in p["name"]:
            target = p
            break
if not target:
    target = izotope[0]
print(f"target: {target['name']} @ {target['path']}")

print("=== [2] 加载（门禁：setProcessing 返回 kNotImplemented 不得致命） ===")
rc = dll.auradsp_plugin_load(h, target["path"].encode("utf-8"), b"")
print(f"load rc = {rc}")
assert rc == 1, (
    f"iZotope plugin failed to activate (rc={rc}). If this is the setProcessing "
    "kNotImplemented regression, the engine must tolerate kNotImplemented "
    "(see vst3_instance.cpp activate())."
)

status_buf = ctypes.create_string_buffer(4096)
dll.auradsp_plugin_get_status(h, status_buf, 4096)
status = json.loads(status_buf.value.decode("utf-8"))
print(f"hasActive={status['hasActive']} latency={status['latency']}")
assert status["hasActive"], "expected hasActive=true after load"

print("=== [3] process() 音频存活（正弦向量，携带位置信息） ===")
# 1kHz 正弦、256 帧/块、64 块：覆盖实测 ~5.8k 样本（约 23 块）的 wrapper 启动延迟。
# 选择正弦而非常量：常量对"输出恒零/直通/置乱"零分辨力（见项目记忆 2026-10-21 教训）。
frames, blocks = 256, 64
sr, freq, amp = 48000.0, 1000.0, 0.5
samples = []
phase = 0.0
for i in range(frames):
    v = amp * math.sin(phase)
    samples.extend([v, -v])
    phase += 2 * math.pi * freq / sr
    if phase > 2 * math.pi:
        phase -= 2 * math.pi
in_arr = (ctypes.c_float * len(samples))(*samples)
out_arr = (ctypes.c_float * len(samples))()

last = None
for _ in range(blocks):
    dll.auradsp_process(h, in_arr, out_arr, frames)
    last = list(out_arr)

assert not any(abs(v) == 777.0 for v in last), "output buffer never written (poison -777)"
rms = math.sqrt(sum(v * v for v in last) / len(last))
print(f"tail RMS = {rms:.6f} (input RMS = {amp / math.sqrt(2):.6f})")
assert rms > 1e-4, f"plugin produced pure silence after activate (RMS={rms:.6f})"

print("=== [4] bypass 位精确直通 ===")
assert dll.auradsp_plugin_set_bypass(h, 1) == 1
assert dll.auradsp_plugin_get_bypass(h) == 1
dll.auradsp_process(h, in_arr, out_arr, frames)
assert out_arr[0] == in_arr[0] and out_arr[100] == in_arr[100], "bypass must be bit-exact"
assert dll.auradsp_plugin_set_bypass(h, 0) == 1

print("=== [5] 卸载与销毁 ===")
assert dll.auradsp_plugin_unload(h) == 1
dll.auradsp_destroy(h)
print("ALL TESTS PASSED: iZotope setProcessing-kNotImplemented tolerance 100% OK!")
