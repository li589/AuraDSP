# -*- coding: utf-8 -*-
"""smoke_plugin_prime_no_double_send.py — E14 预热直通双发门禁（进程外专用）。

背景（审查报告 §11.6 遗留观察② / 未决清单 E14）：
代理 `processInterleaved` 的帧级语义是「无输出可用 → 当前帧原样保留
（直通）」，而块级无条件 `submitChunk`——两者叠加使宿主懒启动窗口内的
直通块**既被上层听见又被宿主处理回放**：同一段音频在输出流出现两遍
（R-1 轮实测「帧 0 与帧 544 双脉冲」同源）。

判据设计（对启动时序鲁棒）：
宿主懒启动期间第 0 块必然整体直通（首块提交完成往返前不可能有任何输出
可取）→ 第 0 块注入 ch0 单样本脉冲 0.5：
  - 直通面（fail-open 语义，两版皆然）：输出帧 0 == 0.5；
  - 双发面（E14 修复前）：脉冲块仍被提交，宿主启动后处理之，其 IR
    （ConvologyXT 峰值 ~0.3）稍后出现在输出流 → 后续窗口非零；
  - 修复后：直通块不提交，代之以静音 prime 块破鸡生蛋（宿主需输入才产
    输出；prime 回声≈静音无听感）→ 后续窗口逐位为零。

能证明什么：预热直通块不再被宿主重复回放（同内容不出现两遍）。
不能证明什么：宿主慢启动（>80 块）场景的 prime 时序；直通语义本身的
fail-open 正确性（由 smoke_plugin_host_process [6] 死亡路径守卫）。

用法：python smoke_plugin_prime_no_double_send.py
"""
import ctypes
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll")
PLUGIN_NAME = "Convology"

SR = 48000.0
BLOCK = 128
SILENCE_BLOCKS = 80          # 脉冲后观察窗（0.21s，覆盖宿主启动 + 排队排空）
IMPULSE_AMP = 0.5
ECHO_FLOOR = 0.05            # 观察窗内 |ch0| 超过此值 = 脉冲被宿主回放（双发）


def main():
    os.environ["AURA_PLUGIN_HOST_MODE"] = "process"
    dll = ctypes.CDLL(DLL_PATH)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float),
        ctypes.c_int,
    ]
    dll.auradsp_plugin_scan.restype = ctypes.c_int
    dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_get_count.restype = ctypes.c_int
    dll.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
    dll.auradsp_plugin_get_item.restype = ctypes.c_int
    dll.auradsp_plugin_get_item.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_load.restype = ctypes.c_int
    dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    dll.auradsp_plugin_get_status.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

    handle = dll.auradsp_create(SR, 1024)
    assert handle, "auradsp_create failed"

    # 找 ConvologyXT（latency 288，IR 短——峰值能量集中 1 块，见 E9 实测）
    count = dll.auradsp_plugin_scan(handle, b"", 0)
    assert count > 0, "plugin scan found nothing"
    buf = ctypes.create_string_buffer(4096)
    target = None
    for i in range(count):
        dll.auradsp_plugin_get_item(handle, i, buf, len(buf))
        item = json.loads(buf.value.decode("utf-8"))
        if PLUGIN_NAME in item.get("name", ""):
            target = item
            break
    if target is None:
        print(f"[SKIP] prime-no-double-send: {PLUGIN_NAME} not installed")
        dll.auradsp_destroy(handle)
        return 0

    assert dll.auradsp_plugin_load(
        handle, target["path"].encode("utf-8"), b"") == 1, "plugin load failed"
    time.sleep(0.003)            # 与 E9 同款节奏，给宿主音频线程让路

    state = {"blocks": 0}

    def pump(samples):
        in_arr = (ctypes.c_float * (BLOCK * 2))(*samples)
        out_arr = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(handle, in_arr, out_arr, BLOCK)
        state["blocks"] += 1
        time.sleep(0.003)
        return list(out_arr)

    # 第 0 块：ch0 单样本脉冲。宿主懒启动 → 本块必然整体直通（帧 0 = 0.5）。
    impulse = [0.0] * (BLOCK * 2)
    impulse[0] = IMPULSE_AMP
    first = pump(impulse)

    # 观察窗：脉冲之后的全部输出。
    tail = []
    for _ in range(SILENCE_BLOCKS):
        tail.append(pump([0.0] * (BLOCK * 2)))

    st = ctypes.create_string_buffer(8192)
    dll.auradsp_plugin_get_status(handle, st, len(st))
    status = json.loads(st.value.decode("utf-8"))
    dll.auradsp_destroy(handle)
    time.sleep(0.5)

    flat0 = first[0::2]          # ch0
    tail_flat = [v for blk in tail for v in blk[0::2]]
    passthrough_ok = abs(flat0[0] - IMPULSE_AMP) < 1e-3
    echo_peak = max(abs(v) for v in tail_flat)
    echo_frames = [i for i, v in enumerate(tail_flat) if abs(v) > ECHO_FLOOR]

    print(f"passthrough frame0 = {flat0[0]:.6f} (expect {IMPULSE_AMP})")
    print(f"echo window [{BLOCK}, {(SILENCE_BLOCKS + 1) * BLOCK}) frames: "
          f"peak={echo_peak:.6f}, nonzero>{ECHO_FLOOR}: {len(echo_frames)} samples")
    print(f"slot: remoteFailed={status.get('remoteFailed')}, "
          f"seqGaps={status.get('seqGaps')}, "
          f"ovf={status.get('inputOverflows')}/{status.get('outputOverflows')}")

    assert passthrough_ok, (
        f"frame 0 = {flat0[0]:.6f}: lazy-start passthrough not observed — "
        "test precondition broken (host active before first block finished?)")
    assert not status.get("remoteFailed"), "slot self-destructed (E12 regression)"
    assert echo_peak <= ECHO_FLOOR, (
        f"impulse echoed back through the plugin (peak {echo_peak:.6f} at "
        f"frames {echo_frames[:5]}): warm-up passthrough block was ALSO "
        "submitted and replayed — double-send (review E14)")
    print("PASS: warm-up passthrough block not replayed (prime-block kick, "
          "no double-send)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
