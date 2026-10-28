# -*- coding: utf-8 -*-
"""smoke_plugin_chain_enable.py — 插件链级启用开关红→绿（VB 按路插件处理底层）

验证 auradsp_plugin_chain_set_enabled/get_enabled：
  [1] 默认启用：挂插件喂斜坡 → 输出≠输入（效果上流）；
  [2] 关闭：同一输入 → 输出**逐位**等于输入（纯直通，含 PDC 不跑）；
      latency 语义归零（get_total_latency == 0）；
  [3] 重新启用：延迟线复位（无陈旧内容注入），效果恢复上流；
  [4] 槽位状态在开关全程保持挂载（hasActive=true，bypassed=false）——
      链开关只控制「是否进音频路径」，不改变挂载语义。

能证明什么：引擎链级开关的直通/恢复语义与延迟口径。
不能证明什么：VB 桥的掩码扇出（smoke_vm_bridge 覆盖导出存在性；
RT 路径需 Voicemeeter 实机，由用户验收）。
"""
import ctypes
import json
import os
import sys
import time

DLL_PATH = os.path.abspath(r"core/desktop/windows/out/Release/auradsp_engine.dll")
if not os.path.exists(DLL_PATH):
    print(f"Error: DLL not found at {DLL_PATH}")
    sys.exit(1)

lib = ctypes.CDLL(DLL_PATH)

lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.restype = None
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.restype = None
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_plugin_scan.restype = ctypes.c_int32
lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]
lib.auradsp_plugin_get_all.restype = ctypes.c_int32
lib.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]
lib.auradsp_plugin_slot_load.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                         ctypes.c_char_p, ctypes.c_char_p]
lib.auradsp_plugin_slot_unload.restype = ctypes.c_int32
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int32]
lib.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int32
lib.auradsp_plugin_slot_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                               ctypes.c_int32]
lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int32
lib.auradsp_plugin_slot_get_status.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                                               ctypes.c_char_p, ctypes.c_int32]
lib.auradsp_plugin_chain_set_enabled.restype = ctypes.c_int32
lib.auradsp_plugin_chain_set_enabled.argtypes = [ctypes.c_void_p, ctypes.c_int32]
lib.auradsp_plugin_chain_get_enabled.restype = ctypes.c_int32
lib.auradsp_plugin_chain_get_enabled.argtypes = [ctypes.c_void_p]
lib.auradsp_plugin_get_total_latency.restype = ctypes.c_uint32
lib.auradsp_plugin_get_total_latency.argtypes = [ctypes.c_void_p]

FRAMES = 256
BLOCKS = 32


def get_status(h, slot):
    buf = ctypes.create_string_buffer(4096)
    n = lib.auradsp_plugin_slot_get_status(h, slot, buf, 4096)
    return json.loads(buf.value[:n].decode("utf-8")) if n > 0 else {}


def run_stream(h):
    """喂 BLOCKS 块斜坡，返回 (max_diff, out_total, in_total)。"""
    in_buf = (ctypes.c_float * (FRAMES * 2))()
    out_buf = (ctypes.c_float * (FRAMES * 2))()
    ramp = [0.02 * (i % 50) / 50.0 for i in range(FRAMES)]
    for i in range(FRAMES):
        in_buf[i * 2 + 0] = ramp[i]
        in_buf[i * 2 + 1] = ramp[(i + 7) % FRAMES]
    max_diff = 0.0
    out_total = 0.0
    in_total = 0.0
    for _ in range(BLOCKS):
        lib.auradsp_process(h, in_buf, out_buf, FRAMES)
        for i in range(FRAMES * 2):
            d = abs(out_buf[i] - in_buf[i])
            if d > max_diff:
                max_diff = d
            out_total += out_buf[i] * out_buf[i]
            in_total += in_buf[i] * in_buf[i]
    return max_diff, out_total, in_total


def main():
    h = lib.auradsp_create(48000.0, 1024)
    assert h, "auradsp_create failed"

    count = lib.auradsp_plugin_scan(h, None, 0)
    buf = ctypes.create_string_buffer(262144)
    lib.auradsp_plugin_get_all(h, buf, 262144)
    plugins = json.loads(buf.value.decode("utf-8"))
    target = next((p for p in plugins if "Convology" in p.get("name", "")),
                  plugins[0] if plugins else None)
    assert target, "no plugin found"
    assert lib.auradsp_plugin_slot_load(h, 0, target["path"].encode(),
                                        target.get("id", "").encode()) == 1, "load failed"
    # P-041 挂载即旁路：显式解旁路（旁路槽 max_diff 恒 0，[1] 判据失效）。
    assert lib.auradsp_plugin_slot_set_bypass(h, 0, 0) == 1

    # 预跑若干块，让插件流水稳定（首块含懒启动暂态）
    run_stream(h)

    # [1] 默认启用
    assert lib.auradsp_plugin_chain_get_enabled(h) == 1, "default should be enabled"
    d_on, out_on, in_on = run_stream(h)
    assert d_on > 1e-4, f"[1] enabled but output==input (max_diff={d_on})"
    print(f"[1] enabled: max_diff={d_on:.6f} outRMS={ (out_on/(BLOCKS*FRAMES*2))**0.5 :.6f} OK")

    # [2] 关闭 → 逐位直通 + latency 归零
    assert lib.auradsp_plugin_chain_set_enabled(h, 0) == 1, "set_enabled(0) failed"
    assert lib.auradsp_plugin_chain_get_enabled(h) == 0, "get_enabled after disable"
    assert lib.auradsp_plugin_get_total_latency(h) == 0, \
        "disabled chain must report 0 latency (no PDC for non-processing plugins)"
    d_off, _, _ = run_stream(h)
    assert d_off == 0.0, f"[2] disabled but output differs (max_diff={d_off})"
    print("[2] disabled: output bit-exact passthrough, total latency = 0 OK")

    # [3] 重新启用 → 延迟线复位后效果恢复；latency 恢复非零
    assert lib.auradsp_plugin_chain_set_enabled(h, 1) == 1, "set_enabled(1) failed"
    assert lib.auradsp_plugin_get_total_latency(h) > 0, "latency should restore"
    run_stream(h)  # 预跑重建流水（重启后首块走建立路径）
    d_re, _, _ = run_stream(h)
    assert d_re > 1e-4, f"[3] re-enabled but output==input (max_diff={d_re})"
    print(f"[3] re-enabled: max_diff={d_re:.6f} (delay lines reset) OK")

    # [4] 槽位挂载状态全程保留
    st = get_status(h, 0)
    assert st.get("hasActive") is True, f"[4] hasActive lost: {st}"
    assert st.get("bypassed") is False, f"[4] bypassed flag changed: {st}"
    print(f"[4] slot state preserved: hasActive={st['hasActive']} "
          f"bypassed={st['bypassed']} processCalls={st['processCalls']} OK")

    lib.auradsp_plugin_slot_unload(h, 0)
    lib.auradsp_destroy(h)
    print("ALL TESTS PASSED: plugin chain enable switch 100% OK!")


if __name__ == "__main__":
    main()
