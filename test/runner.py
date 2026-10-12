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
        "smoke_plugin_metadata.py",
        "smoke_plugin_arch_detect.py",
        "smoke_multislot_and_stages.py",
        "smoke_config_and_matrix.py",
        "smoke_eq_response.py",
        "smoke_latency_real_resource.py",
        "smoke_abi_consistency.py",
    "smoke_ir_block_jitter.py",
    "smoke_eq_viz_tap.py",
        "test_editor_topology.py",
        "probe_component.py",
        "test_cross_system_verify.py",
        # C2：扫描基准（无插件环境自动 SKIP，故可值守）
        "bench_scan_c2.py",
        # C3：异步挂载/卸载（无插件环境自动 SKIP，故可值守）
        "bench_load_async_c3.py",
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
