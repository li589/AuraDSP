#!/usr/bin/env python3
"""C2 扫描基准 + 缓存一致性回归（已挂 test/runner.py，无插件自动 SKIP）。

验证四件事：
  1. 快扫（一次性 vs 分块）结果一致且都在百毫秒级 —— 快扫从不 LoadLibrary；
  2. 重扫命中元数据缓存后接近瞬时（文件未变 → 零 PE 读取 / 零 LoadLibrary）；
  3. 深扫被切成小步后，单步耗时可被观察（Dart 侧据此让出事件循环）；
  4. **冷热条目数一致**（回归门禁）：一个二进制可含多个插件类（.vst3 bundle、
     CLAP bundle），深扫会枚举出 N 条同 path 的元数据。缓存若按单条存储，
     重扫命中缓存会把 N 折叠成 1，出现"深扫冷 79 / 热 76"条目凭空消失。
     故缓存值是列表，这里强制断言 deep_cold == deep_warm。

运行： python test/smoke/bench_scan_c2.py
"""
import ctypes
import os
import sys
import time

DLL_CANDIDATES = [
    os.path.abspath("auradsp_engine.dll"),
    os.path.abspath("core/desktop/windows/out/Release/auradsp_engine.dll"),
]


def load_engine():
    for p in DLL_CANDIDATES:
        if os.path.exists(p):
            return ctypes.CDLL(p), p
    print("SKIP: auradsp_engine.dll not found")
    sys.exit(0)


def main():
    lib, path = load_engine()
    print(f"engine: {path}")

    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    lib.auradsp_destroy.restype = None
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
    lib.auradsp_plugin_scan.restype = ctypes.c_int32
    lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]
    lib.auradsp_plugin_scan_begin.restype = ctypes.c_int32
    lib.auradsp_plugin_scan_begin.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]
    lib.auradsp_plugin_scan_step.restype = ctypes.c_int32
    lib.auradsp_plugin_scan_step.argtypes = [ctypes.c_void_p, ctypes.c_int32]
    lib.auradsp_plugin_scan_progress.restype = ctypes.c_int32
    lib.auradsp_plugin_scan_progress.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32)]
    lib.auradsp_plugin_scan_end.restype = ctypes.c_int32
    lib.auradsp_plugin_scan_end.argtypes = [ctypes.c_void_p]
    lib.auradsp_plugin_get_count.restype = ctypes.c_int32
    lib.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]

    h = lib.auradsp_create(48000.0, 1024)
    if not h:
        print("FAIL: auradsp_create returned null")
        sys.exit(1)
    try:
        # ---- 1. 一次性快扫（冷） ----
        t0 = time.perf_counter()
        n1 = lib.auradsp_plugin_scan(h, b"", 0)
        t_one_shot_quick_cold = (time.perf_counter() - t0) * 1000

        # ---- 2. 一次性快扫（热：应命中缓存） ----
        t0 = time.perf_counter()
        n2 = lib.auradsp_plugin_scan(h, b"", 0)
        t_one_shot_quick_warm = (time.perf_counter() - t0) * 1000

        # ---- 3. 分块快扫（冷：先做一次深扫污染缓存，再回到快扫） ----
        t0 = time.perf_counter()
        total = lib.auradsp_plugin_scan_begin(h, b"", 1)
        steps = []
        guard = 0
        while True:
            ts = time.perf_counter()
            stepped = lib.auradsp_plugin_scan_step(h, 1)
            if stepped <= 0:
                break
            steps.append((time.perf_counter() - ts) * 1000)
            guard += 1
            if guard > 5000:
                break
        n3 = lib.auradsp_plugin_scan_end(h)
        t_deep = (time.perf_counter() - t0) * 1000

        # ---- 4. 分块深扫（热：命中缓存 → 条目数必须与冷扫完全一致） ----
        t0 = time.perf_counter()
        lib.auradsp_plugin_scan_begin(h, b"", 1)
        guard = 0
        while True:
            if lib.auradsp_plugin_scan_step(h, 1) <= 0:
                break
            guard += 1
            if guard > 5000:
                break
        n_deep_warm = lib.auradsp_plugin_scan_end(h)
        t_deep_warm = (time.perf_counter() - t0) * 1000

        # ---- 5. 分块快扫（热：深扫结果可服务快扫 → 应全部命中缓存） ----
        t0 = time.perf_counter()
        total_q = lib.auradsp_plugin_scan_begin(h, b"", 0)
        guard = 0
        while True:
            if lib.auradsp_plugin_scan_step(h, 8) <= 0:
                break
            guard += 1
            if guard > 5000:
                break
        n4 = lib.auradsp_plugin_scan_end(h)
        t_quick_warm = (time.perf_counter() - t0) * 1000

        steps_sorted = sorted(steps) if steps else [0.0]
        print("\n--- 结果 ---")
        print(f"一次性快扫（冷）      : {n1:4d} 个  {t_one_shot_quick_cold:8.1f} ms")
        print(f"一次性快扫（热/缓存） : {n2:4d} 个  {t_one_shot_quick_warm:8.1f} ms")
        print(f"分块深扫（每步 1 个） : {n3:4d} 个  {t_deep:8.1f} ms  候选 {total}")
        print(f"  深扫单步 p50/max    : {steps_sorted[len(steps_sorted)//2]:6.1f} / "
              f"{steps_sorted[-1]:6.1f} ms（共 {len(steps)} 步）")
        print(f"分块深扫（热/缓存）   : {n_deep_warm:4d} 个  {t_deep_warm:8.1f} ms")
        print(f"分块快扫（热/深扫缓存）: {n4:4d} 个  {t_quick_warm:8.1f} ms  候选 {total_q}")

        if n1 <= 0:
            print("SKIP: 本机无插件可扫（快扫 0 个）——基准不适用")
            sys.exit(0)

        ok = True
        if n1 != n2:
            print("FAIL: 冷/热快扫数量不一致"); ok = False
        if n3 < 1 or n4 < 1:
            print("FAIL: 分块扫描未产出结果"); ok = False
        # 回归门禁：多插件 bundle 不得在命中缓存后被折叠（曾出现 79 → 76）
        if n_deep_warm != n3:
            print(f"FAIL: 深扫命中缓存后条目数变化（冷 {n3} → 热 {n_deep_warm}）——"
                  f"多插件 bundle 被折叠，缓存必须按路径存列表"); ok = False
        # 快扫可复用深扫结果，条目数只增不减
        if n4 < n1:
            print(f"FAIL: 快扫命中深扫缓存后条目反而变少（{n1} → {n4}）"); ok = False
        # 快扫冷启动本身就在 ~50ms 量级，缓存收益的绝对差很小，故用 1.15 倍
        # 容差，避免把噪声误报成回归；真正的缓存收益由分块深扫（秒级 → 毫秒级）体现。
        if t_one_shot_quick_warm > t_one_shot_quick_cold * 1.15 and n1 > 20:
            print("WARN: 热扫反而明显变慢，缓存可能未命中（检查文件指纹判定）")
        # 深扫单步 p50 应远小于整轮深扫（说明分块确实把长调用切开了）
        if steps and t_deep > 200 and steps_sorted[len(steps_sorted)//2] > t_deep * 0.5:
            print("WARN: 深扫单步耗时占比过高，分块粒度可能需要调小")
        print("\nRESULT:", "PASS" if ok else "FAIL")
        sys.exit(0 if ok else 1)
    finally:
        lib.auradsp_destroy(ctypes.c_void_p(h))


if __name__ == "__main__":
    main()
