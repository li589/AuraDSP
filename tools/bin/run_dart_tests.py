#!/usr/bin/env python3
"""run_dart_tests.py — T-03 Dart 测试门禁：按文件串行 + 失败单文件重试两次。

背景（全量审查 T-03）：`flutter test` 默认把 59 个 `*_test.dart` 并发跑在
同一进程池里，实测 37 个用例 `did not complete`、`-j 1` 仍有 18 个；失败
集合每次不同，而任一单文件复跑全部通过——这是测试基建的全局资源（计时器/
临时目录/字体加载/isolate）串扰，不是产品回归。全量并发把真实回归淹没在
噪声里，因此门禁改为：**一个文件一次 `flutter test` 进程**，失败文件单独
重试（本机 `did not complete` 可连挂两轮，故最多重试两次）；三次仍失败才
算红。真实回归是确定性的，不会被重试掩盖。

用法：
    python tools/bin/run_dart_tests.py              # 全部 59 个文件
    python tools/bin/run_dart_tests.py --filter lyrics
    python tools/bin/run_dart_tests.py --list
"""

import argparse
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "app", "auradsp_app")
TEST_DIR = os.path.join(APP, "test")
FLUTTER = shutil.which("flutter") or shutil.which("flutter.bat")

# S4（2026-11-01）：Windows 范式专属的 Dart 测试。它们渲染的是
# ASIO/VAIO 驱动范式与 Windows 插件宿主 UI（ADR-012：Linux 一期
# supportsBridges=false、范式集合不同），在非 Windows 主机上断言
# 必然落空 —— 与 Python 侧 test/runner.py 的 PLATFORM_WINDOWS 同
# 口径：显式标记 + 非 Windows 主机明示 SKIP（不静默、不算失败）。
# Linux 范式的对应测试随 S5a 三模式落地时补齐。
WINDOWS_ONLY = {
    "test/settings_asio_test.dart",
    "test/settings_vaio_test.dart",
    "test/settings_paradigms_test.dart",
    "test/plugins_page_layout_test.dart",
}


def discover():
    files = []
    for dirpath, _dirnames, names in os.walk(TEST_DIR):
        for n in names:
            if n.endswith("_test.dart"):
                rel = os.path.relpath(os.path.join(dirpath, n), APP)
                files.append(rel.replace("\\", "/"))
    return sorted(files)


def run_one(rel, timeout_s=90):
    cmd = [FLUTTER, "test", rel, "--concurrency=1",
           f"--timeout={timeout_s}s", "--reporter=compact"]
    t0 = time.perf_counter()
    res = subprocess.run(cmd, cwd=APP, check=False)
    return res.returncode, time.perf_counter() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--filter", default="",
                    help="只跑路径包含该子串的文件")
    ap.add_argument("--list", action="store_true", help="只列出文件")
    ap.add_argument("--timeout", type=int, default=90,
                    help="单用例超时秒数（flutter test --timeout，默认 90）")
    args = ap.parse_args()

    files = discover()
    if args.filter:
        files = [f for f in files if args.filter in f]
    if not files:
        print(f"[ERROR] 未找到匹配的 *_test.dart（目录 {TEST_DIR}）")
        return 2
    if args.list:
        print("\n".join(files))
        return 0
    if not FLUTTER:
        print("[ERROR] 找不到 flutter 可执行文件（检查 PATH）")
        return 2

    print("=" * 56)
    print(f"  AuraDSP Dart tests: {len(files)} files (serial, retry up to 2)")
    print("=" * 56)

    passed, retried, failed, skipped_platform = [], [], [], []
    if sys.platform != "win32":
        skipped_platform = [f for f in files if f in WINDOWS_ONLY]
        files = [f for f in files if f not in WINDOWS_ONLY]
        for f in skipped_platform:
            print(f"[SKIP-PLATFORM] {f}（Windows 范式专属，非 Windows 主机跳过）")

    t_start = time.perf_counter()
    for i, rel in enumerate(files, 1):
        print(f"\n---> [{i}/{len(files)}] {rel}")
        rc, dt = run_one(rel, args.timeout)
        if rc == 0:
            print(f"[PASS] {rel} ({dt:.1f}s)")
            passed.append(rel)
            continue
        for attempt in (1, 2):
            print(f"[RETRY {attempt}/2] {rel} 第 {attempt} 次首跑失败 "
                  f"(rc={rc}, {dt:.1f}s)")
            time.sleep(3)
            rc, dt = run_one(rel, args.timeout)
            if rc == 0:
                print(f"[PASS-RETRY] {rel} ({dt:.1f}s)")
                retried.append(rel)
                break
        else:
            print(f"[FAIL] {rel} 三次均失败 (rc={rc}, {dt:.1f}s)")
            failed.append(rel)

    total = time.perf_counter() - t_start
    print("\n" + "=" * 56)
    print(f"  PASS {len(passed)} | RETRY-PASS {len(retried)} | "
          f"FAIL {len(failed)} | SKIP-PLATFORM {len(skipped_platform)} | "
          f"{total:.0f}s")
    if retried:
        print("  首跑失败但单文件复跑通过（并发串扰，非回归）:")
        for f in retried:
            print(f"    - {f}")
    if failed:
        print("  真实失败:")
        for f in failed:
            print(f"    - {f}")
        print("=" * 56)
        return 1
    print("  ALL DART TESTS PASSED")
    print("=" * 56)
    return 0


if __name__ == "__main__":
    sys.exit(main())
