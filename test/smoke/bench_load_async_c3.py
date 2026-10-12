#!/usr/bin/env python3
"""C3 异步挂载/卸载基准探针（已挂 test/runner.py，无插件自动 SKIP）。

验证两件事：
  1. 异步 API 语义正确：load_async 立即返回（受理/拒绝）、轮询 task_state
     直到终态（2=成功 / 3=失败）、unload_async 同理。
  2. **提交本身不阻塞**：`auradsp_plugin_slot_load_async` 的 wall time 应远小于
     同步 `auradsp_plugin_slot_load`（提交是微秒级的入队，重活在控制线程）。
"""
import ctypes, json, os, sys, time

lib = ctypes.CDLL(os.path.abspath("auradsp_engine.dll"))
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_plugin_scan.restype = ctypes.c_int32
lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32]
lib.auradsp_plugin_get_count.restype = ctypes.c_int32
lib.auradsp_plugin_get_count.argtypes = [ctypes.c_void_p]
lib.auradsp_plugin_get_item.restype = ctypes.c_int32
lib.auradsp_plugin_get_item.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_int32]

lib.auradsp_plugin_slot_load.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_char_p]
lib.auradsp_plugin_slot_unload.restype = ctypes.c_int32
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int32]

lib.auradsp_plugin_slot_load_async.restype = ctypes.c_int32
lib.auradsp_plugin_slot_load_async.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p, ctypes.c_char_p]
lib.auradsp_plugin_slot_unload_async.restype = ctypes.c_int32
lib.auradsp_plugin_slot_unload_async.argtypes = [ctypes.c_void_p, ctypes.c_int32]
lib.auradsp_plugin_slot_task_state.restype = ctypes.c_int32
lib.auradsp_plugin_slot_task_state.argtypes = [ctypes.c_void_p, ctypes.c_int32]

h = lib.auradsp_create(48000.0, 1024)
if not h:
    print("FAIL: auradsp_create returned null"); sys.exit(1)
n = lib.auradsp_plugin_scan(h, b"", 0)
buf = ctypes.create_string_buffer(8192)
items = []
for i in range(n):
    lib.auradsp_plugin_get_item(h, i, buf, 8192)
    try: items.append(json.loads(buf.value.decode("utf-8", "replace")))
    except Exception: pass

if not items:
    print("SKIP: 本机无插件可扫"); lib.auradsp_destroy(ctypes.c_void_p(h)); sys.exit(0)

def pathsize(p):
    try:
        if os.path.isdir(p):
            return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs)
        return os.path.getsize(p)
    except Exception: return 0

items.sort(key=lambda d: pathsize(d.get("path", "")), reverse=True)
picks = [items[0], items[2]] if len(items) > 2 else items

ok = True
print(f"{'plugin':40s} {'sync_ms':>9s} {'async_submit_ms':>16s} {'async_total_ms':>15s}")
for d in picks:
    p, i = d.get("path",""), d.get("id","")
    name = (d.get("name") or "")[:38]

    # 同步基线（第二次起命中 DLL 缓存，但 LoadLibrary 同模块引用计数不减）
    t0 = time.perf_counter(); rs = lib.auradsp_plugin_slot_load(h, 0, p.encode(), i.encode()); sync_ms = (time.perf_counter()-t0)*1000
    t0 = time.perf_counter(); lib.auradsp_plugin_slot_unload(h, 0); lib.auradsp_plugin_slot_unload(h, 0)

    # 异步：提交 → 轮询
    t0 = time.perf_counter(); sub = lib.auradsp_plugin_slot_load_async(h, 0, p.encode(), i.encode()); sub_ms = (time.perf_counter()-t0)*1000
    t_async_start = time.perf_counter()
    spins, st = 0, lib.auradsp_plugin_slot_task_state(h, 0)
    while st == 1 and spins < 12000:   # 12000 * 1ms = 12s 上限
        time.sleep(0.001); st = lib.auradsp_plugin_slot_task_state(h, 0); spins += 1
    async_total_ms = (time.perf_counter() - t_async_start) * 1000
    lib.auradsp_plugin_slot_unload_async(h, 0)
    spins = 0
    while lib.auradsp_plugin_slot_task_state(h, 0) == 1 and spins < 12000:
        time.sleep(0.001); spins += 1
    lib.auradsp_plugin_slot_unload(h, 0)   # 兜底排空

    print(f"{name:40s} {sync_ms:9.1f} {sub_ms:16.3f} {async_total_ms:15.1f}  state={st}")

    if sub != 1:
        print("FAIL: load_async 未被受理"); ok = False
    if st != 2:
        print(f"FAIL: 异步挂载未成功（state={st}）"); ok = False
    if sub_ms > 20.0:
        print(f"FAIL: 异步提交耗时 {sub_ms:.1f}ms，应为微秒级（重活应移出调用方线程）"); ok = False

print("\nRESULT:", "PASS" if ok else "FAIL")
lib.auradsp_destroy(ctypes.c_void_p(h))
sys.exit(0 if ok else 1)
