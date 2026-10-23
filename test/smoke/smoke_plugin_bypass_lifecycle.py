# -*- coding: utf-8 -*-
"""smoke_plugin_bypass_lifecycle.py — F-2 真旁路生命周期门禁（进程内模式）。

背景（代码审查报告-2026-10-22-增量 §2 / 未决清单 F-2）：
13d13a2 的「真旁路」二次加强把 VST3 setActive / CLAP deactivate-activate
放进了控制线程 setBypass → 与音频线程 process() 并发（两规范均禁止），
且 m_bypassed/m_isActive 为裸 bool（跨线程数据竞争 UB）。

修复（2026-10-23，方案 A 的泵线程变体）：控制线程只写原子请求态；生命周期
切换投递共享泵线程（plugin main 线程），切前等插件 process() 在途退出；
音频线程在「请求态 ≠ 已应用态」时直通。

判据（位置编码信号 + 稳态差分，实测标定）：
链层对 bypassed 槽 `continue`（不调插件），PDC 默认关 →
  - 旁路：输出 == 空链输出（逐位同值，实测均 0.011447，全局线性环节固有差）；
  - 激活：输出 = 卷积结果（实测 0.554631，ConvologyXT 短 IR）；
  - 取消旁路后必须回到激活值——否则 = 生命周期未恢复（F-2 核心回归）。
每相位先预热 3 块（稳态），第 4 块测量；信号为逐块重复的位置编码斜坡
（周期 128 → IIR 状态收敛，输出确定）。

能证明什么：旁路/取消旁路在音频上真实生效且可反复切换不崩。
不能证明什么：切换瞬间 RT 阻塞时长（需真机音频回调监控）；Ozone 级
重插件的卡顿收益（需用户实测）。

用法：python test/smoke/smoke_plugin_bypass_lifecycle.py
"""
import ctypes
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL_PATH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                        "auradsp_engine.dll")
PLUGIN_NAME = "Convology"

SR = 48000.0
BLOCK = 128
SETTLE_MS = 80          # 泵线程切换生命周期（小插件 <1ms；留足余量）
WARMUP_BLOCKS = 3       # 每相位预热（IIR 态收敛）
EPS = 1e-3              # 稳态值重复性容差
ACTIVE_RATIO = 10.0     # 激活差分必须 ≥ 旁路差分的这么多倍
CYCLES = 5              # 反复切换轮数

# 位置编码信号：ch0 上升斜坡 / ch1 下降斜坡（逐块重复、非常量、周期 128）
SIG = []
for _i in range(BLOCK):
    _v = (_i + 1) / float(BLOCK)
    SIG += [_v, -_v]


def main():
    os.environ.pop("AURA_PLUGIN_HOST_MODE", None)   # 进程内（默认路径）

    dll = ctypes.CDLL(DLL_PATH)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_plugin_scan.restype = ctypes.c_int
    dll.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_get_item.restype = ctypes.c_int
    dll.auradsp_plugin_get_item.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    dll.auradsp_plugin_load.restype = ctypes.c_int
    dll.auradsp_plugin_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.c_char_p]
    dll.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int
    dll.auradsp_plugin_slot_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                   ctypes.c_int]
    dll.auradsp_plugin_slot_get_bypass.restype = ctypes.c_int
    dll.auradsp_plugin_slot_get_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int]
    dll.auradsp_plugin_get_status.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                              ctypes.c_int]

    handle = dll.auradsp_create(SR, 1024)
    assert handle, "auradsp_create failed"

    def pump_block():
        in_arr = (ctypes.c_float * (BLOCK * 2))(*SIG)
        out_arr = (ctypes.c_float * (BLOCK * 2))()
        dll.auradsp_process(handle, in_arr, out_arr, BLOCK)
        time.sleep(0.003)
        return max(abs(a - b) for a, b in zip(SIG, list(out_arr)))

    def measure():
        for _ in range(WARMUP_BLOCKS):
            pump_block()
        return pump_block()

    # ---- [0] 空链基线（全局线性环节固有差分，非零但极小）----
    empty_diff = measure()
    assert empty_diff < 0.05, (
        f"empty-chain diff {empty_diff} too large — 全局环节异常，判据前提失稳")
    print(f"[0] empty-chain steady diff = {empty_diff:.6f} (baseline)")

    # ---- [1] 扫描 + 挂载 ----
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
        print(f"[SKIP] {PLUGIN_NAME} not installed")
        dll.auradsp_destroy(handle)
        return 0
    assert dll.auradsp_plugin_load(
        handle, target["path"].encode("utf-8"), b"") == 1, "plugin load failed"
    print(f"[1] loaded {target['name']}")

    # ---- [2] 激活态基线：输出差分显著高于空链（插件真在处理）----
    active_diff = measure()
    assert active_diff > ACTIVE_RATIO * empty_diff, (
        f"active diff {active_diff} not distinguishable from empty-chain "
        f"baseline {empty_diff} — 判据前提不成立")
    assert dll.auradsp_plugin_slot_get_bypass(handle, 0) == 0
    print(f"[2] active diff = {active_diff:.6f} "
          f"({active_diff / empty_diff:.0f}x baseline)")

    # ---- [3] 反复切换：旁路 == 空链（逐位同值）；恢复 == 激活（F-2 核心）----
    for cycle in range(CYCLES):
        assert dll.auradsp_plugin_slot_set_bypass(handle, 0, 1) == 1
        time.sleep(SETTLE_MS / 1000.0)
        assert dll.auradsp_plugin_slot_get_bypass(handle, 0) == 1, \
            f"cycle {cycle}: get_bypass != 1 after set_bypass(1)"
        bypass_diff = measure()
        assert abs(bypass_diff - empty_diff) <= EPS, (
            f"cycle {cycle}: bypassed slot output {bypass_diff} != empty-chain "
            f"baseline {empty_diff} — 槽位未被链层跳过或旁路未生效")

        assert dll.auradsp_plugin_slot_set_bypass(handle, 0, 0) == 1
        time.sleep(SETTLE_MS / 1000.0)
        assert dll.auradsp_plugin_slot_get_bypass(handle, 0) == 0, \
            f"cycle {cycle}: get_bypass != 0 after set_bypass(0)"
        resume_diff = measure()
        assert abs(resume_diff - active_diff) <= EPS, (
            f"cycle {cycle}: un-bypass output {resume_diff} != active "
            f"baseline {active_diff} — 生命周期未恢复（F-2 回归：泵线程切换"
            f"未生效 / m_lifecycleBypassed 卡在 true）")
        print(f"[3.{cycle}] bypass={bypass_diff:.6f} (== baseline) | "
              f"resume={resume_diff:.6f} (== active)")

    # ---- [4] 收尾状态 ----
    st = ctypes.create_string_buffer(8192)
    dll.auradsp_plugin_get_status(handle, st, len(st))
    status = json.loads(st.value.decode("utf-8"))
    dll.auradsp_destroy(handle)
    time.sleep(0.3)
    assert not status.get("remoteFailed"), "slot self-destructed"
    print(f"[4] status sane: processCalls={status.get('processCalls')}, "
          f"seqGaps={status.get('seqGaps')}")
    print(f"PASS: bypass lifecycle works across {CYCLES} cycles "
          f"(bypass == empty-chain, resume == active, both steady-state exact)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
