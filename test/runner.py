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
        "smoke_block1056.py",
        "smoke_plugin_host.py",
        "smoke_multislot_and_stages.py",
        "test_cross_system_verify.py",
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
        ]
    all_pass = True
    for tp in targets:
        name = os.path.basename(tp)
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
