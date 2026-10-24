#!/usr/bin/env python3
"""runner.py — AuraDSP 测试总入口

支持运行：
1. 全量引擎 smoke 测试: python test/runner.py --smoke
2. UI 自动化验证测试: python test/runner.py --ui [test_name]
3. 默认全量验证 (smoke): python test/runner.py
"""

import argparse
import os
import subprocess
import sys

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_DIR = os.path.join(ROOT_DIR, "test")
SMOKE_DIR = os.path.join(TEST_DIR, "smoke")
UI_DIR = os.path.join(TEST_DIR, "ui")


def run_smoke_tests():
    print("========================================")
    print("  Running AuraDSP Engine Smoke Tests   ")
    print("========================================")
    smoke_files = [
        "smoke_convolver_spectrum.py",
        "smoke_chain_meter.py",
        "smoke_convolver.py",
        "smoke_guard_flow.py",
        "smoke_liveprog.py",
        "smoke_viz_lowfreq.py",
        "smoke_latency_probe.py",
        "smoke_block1056.py",
        "smoke_plugin_host.py",
        "smoke_plugin_host_process.py",
        "smoke_plugin_host_editor.py",
        # iZotope Ozone/RX 12 加载契约：setProcessing 返回 kNotImplemented 不得致命，
        # 且 process() 音频必须存活；机器上无 iZotope 插件时自动 SKIP
        "smoke_plugin_izotope_setproc.py",
        "smoke_plugin_pdc.py",
        "smoke_plugin_bus.py",
        "smoke_plugin_chain.py",
        "smoke_plugin_chain_stages.py",
        "smoke_plugin_channels.py",
        "smoke_plugin_metadata.py",
        "smoke_plugin_arch_detect.py",
        "smoke_multislot_and_stages.py",
        # E9 跨模式一致性（进程内 vs 进程外逐位比对）。历史：建门禁时对 HEAD
        # 报红抓出 E12 P0（missStreak 自毁）；E12/E13 修复后转绿，现为常驻
        # 回归守卫（slot 健康 + processCalls 推进 + 对齐逐位一致）。
        "smoke_cross_mode_consistency.py",
        # E14 预热直通双发门禁：直通块不得被宿主回放（prime 补位机制守卫）
        "smoke_plugin_prime_no_double_send.py",
        # 链级启用开关（VB 按路插件处理底层）：关=逐位直通+latency 归零，
        # 重启用=延迟线复位后效果恢复，槽位挂载状态全程保留
        "smoke_plugin_chain_enable.py",
        # F-2 真旁路生命周期门禁：旁路=空链同值（链层跳过槽位）、取消旁路
        # 必须恢复激活处理（泵线程生命周期切换 + 在途 process 握手）
        "smoke_plugin_bypass_lifecycle.py",
        # 桥挂载提速门禁（2026-10-23）：eng[0] 同步 + 其余组后台补齐；
        # 掩码外组不加载、掩码新使能组自动补挂。App 占槽时自动让路。
        "smoke_vm_plugin_load_fast.py",
        # F-4 裁定守卫（2026-10-23）：宿主进程 BELOW_NORMAL 不得外溢到 RT
        # 音频线程（实测音频线程仍 15=TIME_CRITICAL，降级只作用于工作线程）。
        "smoke_plugin_host_priority.py",
        # B3 卸载隔离门禁（2026-10-24）：RT 滞留（假实例 process 阻塞）时卸载
        # 必须按墙钟上界返回并保留实例，不得硬清零后照常销毁（use-after-free）。
        "smoke_plugin_quarantine.py",
        "smoke_config_and_matrix.py",
        # ADR-003 Phase B 多声道电平门禁（2026-10-24）：ABI v2 尺寸/版本 +
        # ch=8/6 逐声道异幅电平 + gate 动态行更新 + vendor/GR 作用域语义 +
        # stereo 回归（MC→stereo 切换无残留泄漏）
        "smoke_mc_channel_levels.py",
        # B4 门禁（2026-10-24）：RT 不得改写 vendor 开关（lost update）。
        # 源码不变式 + 调用级门控接线（comp FL/FR mask）+ 60 轮竞态
        # （MC 处理中翻转 tube.enable，结束后 vendor 开关必须为 0）。
        "smoke_rt_vendor_flags.py",
        # F1 门禁（2026-10-24）：插件 DLL 目录通用化 + AddDllDirectory cookie
        # 引用计数回收。不得识别任何厂商名（源码不变式），卸载必须 RemoveDllDirectory
        # 否则进程搜索路径单调增长 → 后续插件解析同名 DLL 绑到私有副本 → ABI 崩溃。
        "smoke_dll_dirs.py",
        # D2 门禁（2026-10-24）：三桥释放前的 Sleep(50) 猜测改 rtInBlock 确定
        # 性排空（含审查漏点 VmBridge.FreeTestFile）。三层：源码不变式 /
        # guard+排空单测 / ASIO 实测 test_stop 不再是固定 50ms。
        "smoke_d2_rt_drain.py",
        "smoke_d3_vaio_pump_wait.py",
        # B1-d 门禁（2026-10-24）：comp 启动段原声直通。旧实现的抽干循环在
        # 管线首块产出前不执行，输出缓冲里仍是未处理输入（调用方 in==out）；
        # 块长不整除 hop 时还会周期性复发。改为显式启动缺额 D（吐静音）+
        # 抽干不足补静音，延迟 = frames + D 且计入上报。
        "smoke_b1d_comp_startup.py",
        # D1 门禁（2026-10-24）：延迟表口径——结构性帧数不再当毫秒常量。
        # D7（同日）修正其换算基准为工作采样率，具体标定值移入 D7 门禁。
        "smoke_d1_latency_sr.py",
        # D7 门禁（2026-10-24）：ASRC taps 单点定义（64/32 分叉已收）+ 延迟口径
        # 按工作采样率域 + comp 剖面随 tf 变（块长口径后来被 B1-d 推翻并重写，
        # 见下）+ limiter 按 lookahead 模式（默认 0ms）+ ASRC 环形缓冲分量 +
        # 上报值==脉冲实测。
        "smoke_d7_asrc_consistency.py",
        # D5 门禁（2026-10-24）：插件槽异步等待上界 150s → 5s + 墙钟收口 +
        # 超时兜底（同步 unload）+ timedOut 上报。数值与链路任一项回退即红。
        "smoke_d5_slot_timeout.py",
        # D4-b 门禁（2026-10-24）：全仓静默异常。97 处 catch 既不留痕也不绑定
        # 异常，泵循环更是整个迭代体包在 catch (_) {} + continue 里——一次类型
        # 错误就能让可视化永远冻结且日志无痕。四类分治 + 四条规则（R1 空块必留痕
        # /R2 循环包壳必限流/R3 禁匿名 catch/R4 理由不得敷衍），含规则引擎单测、
        # 全仓扫描、接线完整性（part 共享 library import）与两处反向判红。
        "smoke_d4b_swallow.py",
        "smoke_eq_response.py",
        "smoke_latency_real_resource.py",
        "smoke_abi_consistency.py",
        # B-1 调试串门禁：源码零 cout [DBG + Release DLL 无 [DBG（计划 D1 §3.3）
        "smoke_release_strings.py",
    "smoke_ir_block_jitter.py",
    "smoke_eq_viz_tap.py",
    "smoke_bassmono.py",
    "smoke_haas.py",
    "smoke_spatial.py",
    "smoke_spatial_binaural.py",
    "smoke_exciter.py",
    "smoke_fx_gain.py",
    "smoke_arbmag.py",
    "smoke_string_readback.py",
    "smoke_gate_deesser.py",
    "smoke_dyneq.py",
    "smoke_mp3.py",
        "smoke_vm_detect.py",
        "smoke_vm_pump.py",
        "smoke_vm_bridge.py",
        # Z12 超预算自动保护门禁（2026-10-23）：注入观测值 → 收窄到热组 →
        # 回落自动恢复；手动改掩码立即取消；关保护不进入。App 占槽时让路。
        "smoke_vm_protect.py",
        # Z17 组间并行处理门禁（2026-10-24）：串/并行双路位级对账 + 语义断言
        # + 遥测相等 + 墙钟（8 组 × 250µs 假插件：并行 <60% 串行）。不依赖 VM 在线。
        "smoke_vm_parallel.py",
    "smoke_apo_inspect.py",
    "smoke_apo_register.py",
    "smoke_apo_selftest.py",
    # ASIO 宿主（Phase 1）：枚举对账注册表 + 双驱动发声；无 ASIO 驱动时自动 SKIP
    "smoke_asio_probe.py",
    "smoke_asio_tone.py",
    # ASIO 自研驱动（Driver 线 Phase 1）：COM In-Proc Server 握手 + 能力协商 + MMCSS 双缓冲泵
    "smoke_asio_driver.py",
    # ASIO 常驻桥（Phase 2）：VM 虚拟 ASIO 上 10s，bypass 开/关峰值差 +
    # vizGrp/peak 断言 + slot 被占优雅让路（-3 语义同 05）
    "smoke_asio_bridge.py",
    # ASIO 多声道传输（B2c）：asio_start_ex(Nch) + 引擎 channels.count 对齐 +
    # 6ch 文件注入/bypass + 驱动能力降级；无 in/out>=6 驱动时自动 SKIP
    "smoke_asio_multichannel.py",
    # AuraVAIO 虚拟声卡桥（Mode 1）：探测端点与无驱动防御 / 有驱动回环断言
    "smoke_vaio_bridge.py",
    "smoke_crossfeed.py",
    "smoke_basspsycho.py",
    "smoke_filter.py",
    "smoke_loudness.py",
    "smoke_tube.py",
    "smoke_stereo.py",
    "smoke_shelf.py",
    "smoke_input.py",
    "smoke_bass.py",
    "smoke_comp.py",
    # Z13 compander 控制线程/RT 竞争门禁（2026-10-23）：双 UI 线程高频拖
    # comp.gain*/结构参数 + RT 连续 process。修复前实测访问违例（生产崩溃
    # 同根：FFTCompanderInit 重置 count/指针表与 RT 消耗循环无互斥）。
    "smoke_comp_race.py",
    # Z14 DDC 控制线程/RT 竞争门禁（2026-10-23）：高频 ddc.enable +
    # 交替 ddc.load 两份大 VDC + RT 连续 process。修复前 enable 落入
    # DDCStringParser 解析瞬窗即误拒；修复后控制侧同锁零误拒。
    "smoke_ddc_race.py",
    # B1 liveprog 影子 VM 编译门禁（2026-10-24）：RT 连续 process 逐块
    # 计时 + UI 线程高频加载重脚本（~26ms 编译）/坏脚本/变增益脚本。
    # 修复前（持 jdsp_lock 原地编译）RT 每窗口被挡 ~26ms、总产出仅 ~400
    # 块、最大块 ~50ms；修复后产出 ~74k 块、最大块 <1ms、编译窗口内
    # 每窗口 ~300 块，且停流连发加载经 eelInFlight==0 守卫全部成功。
    "smoke_liveprog_race.py",
    "smoke_limiter.py",
    "smoke_lookahead_limiter.py",
    "smoke_dynamic_gr_and_gate.py",
    "smoke_multichannel_discrete.py",
    # B 轮补充：全参数扫描（159 有界参数 roundtrip/clamp/NaN/默认回读）+ 多声道掩码
    # （8 按声道效果器 mask=0 不变式 + arbmag/comp/eq 立体声实现语义登记）
    "smoke_effects_allparams.py",
    "smoke_oversample_aliasing.py",
    "smoke_reverb.py",
    "smoke_graph_order.py",
    "smoke_ddc.py",
        "test_editor_topology.py",
        "probe_component.py",
        "test_cross_system_verify.py",
        # C2：扫描基准（无插件环境自动 SKIP，故可值守）
        "bench_scan_c2.py",
        # C3：异步挂载/卸载（无插件环境自动 SKIP，故可值守）
        "bench_load_async_c3.py",
        # C4：编辑器容器与子窗口尺寸一致 + 拉伸跟随（无插件环境自动 SKIP）
        "test_editor_size_c4.py",
    ]
    all_pass = True
    for sf in smoke_files:
        path = os.path.join(SMOKE_DIR, sf)
        if not os.path.exists(path):
            print(f"[WARN] File not found: {sf}")
            continue
        print(f"\n---> Running {sf}...")
        res = subprocess.run([sys.executable, path], cwd=ROOT_DIR, check=False)
        if res.returncode != 0:
            print(f"[FAIL] {sf} returned code {res.returncode}")
            all_pass = False
        else:
            print(f"[PASS] {sf}")
    print("\n========================================")
    if all_pass:
        print("  ALL SMOKE TESTS PASSED [100%]        ")
    else:
        print("  SOME SMOKE TESTS FAILED!             ")
    print("========================================")
    return 0 if all_pass else 1


def run_ui_tests(target=None):
    print("========================================")
    print("  Running AuraDSP UI Automation Tests  ")
    print("========================================")
    if target:
        target_path = os.path.join(UI_DIR, target if target.endswith(".py") else f"{target}.py")
        if not os.path.exists(target_path):
            print(f"[ERROR] UI test not found: {target_path}")
            return 1
        targets = [target_path]
    else:
        targets = [
            os.path.join(UI_DIR, "ui_verify_slider_reset.py"),
            os.path.join(UI_DIR, "ui_verify_chain_meter.py"),
            os.path.join(UI_DIR, "ui_verify_effects_3d.py"),
            os.path.join(UI_DIR, "ui_verify_preset_and_memory.py"),
            os.path.join(UI_DIR, "ui_verify_plugins.py"),
            os.path.join(UI_DIR, "ui_verify_vst_and_eel.py"),
            os.path.join(UI_DIR, "ui_verify_advanced_sections.py"),
        ]
    all_pass = True
    for tp in targets:
        name = os.path.basename(tp)
        # 每个用例前统一保证 APP 在运行。各测试文件对生命周期的管理并不一致：
        # 有的用 AuraAppSession（__enter__ 杀+重启、__exit__ 关闭），
        # 有的用裸 Win32 并在收尾自行 kill，而 ui_verify_effects_3d 这类
        # 只做 find_auradsp()、**要求 APP 已在运行**，否则直接 FATAL。
        # 于是「前一个用例收尾把 APP 杀掉」会让后一个用例莫名失败。
        if sys.path and UI_DIR not in sys.path:
            sys.path.insert(0, UI_DIR)
        try:
            import ui_test_kit
            if ui_test_kit.ensure_running() is None:
                print(f"[FAIL] {name} 无法启动 APP，前置条件不满足")
                all_pass = False
                continue
        except Exception as e:  # noqa: BLE001
            print(f"[FAIL] {name} 前置检查异常: {e}")
            all_pass = False
            continue
        print(f"\n---> Running UI verification: {name} (Top-most & Activated)...")
        res = subprocess.run([sys.executable, tp], cwd=ROOT_DIR, check=False)
        if res.returncode != 0:
            print(f"[FAIL] {name} failed with code {res.returncode}")
            all_pass = False
        else:
            print(f"[PASS] {name}")
    return 0 if all_pass else 1


def main():
    parser = argparse.ArgumentParser(description="AuraDSP Test Runner")
    parser.add_argument("--smoke", action="store_true", help="Run C++ engine smoke tests")
    parser.add_argument("--ui", nargs="?", const="all", help="Run UI automation tests (or specify test name)")
    args = parser.parse_args()

    if args.ui:
        target = None if args.ui == "all" else args.ui
        return run_ui_tests(target)
    else:
        return run_smoke_tests()


if __name__ == "__main__":
    sys.exit(main())
