"""probe_component.py — 组件延迟实测的回归验证（D11）

验证 auradsp_probe_component 的契约：
  - 未知组件返回 -1（不编造数字）
  - 需要外部资源的组件返回 -1（convolver/ddc/liveprog）
  - 可测组件返回 0，且 bass 能测出**非零**延迟（证明确实在测，不是恒返回 0）
  - 探针不影响调用方正在使用的 handle
  - 探测耗时在可接受范围（用户显式点击才触发，不能是秒级）
"""
import ctypes
import math
import os
import statistics
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                   "auradsp_engine.dll")
lib = ctypes.CDLL(DLL)

lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_probe_component.restype = ctypes.c_int32
lib.auradsp_probe_component.argtypes = [ctypes.c_char_p, ctypes.c_double,
                                       ctypes.POINTER(ctypes.c_uint32)]

RATE = 48000.0
FAILURES = []


def check(cond, label):
    print(("  PASS  " if cond else "  FAIL  ") + label)
    if not cond:
        FAILURES.append(label)


def probe(comp):
    out = ctypes.c_uint32(0)
    t0 = time.perf_counter()
    rc = lib.auradsp_probe_component(comp.encode(), RATE, ctypes.byref(out))
    return rc, out.value, (time.perf_counter() - t0) * 1000.0


print("=== [1] 契约：未知/需外部资源的组件不得编造数字 ===")
for comp in ("bogus_component", "convolver", "ddc", "liveprog", ""):
    rc, samples, dt = probe(comp)
    check(rc == -1, f"{comp!r} 返回 -1 不支持 (rc={rc})")

print("\n=== [2] 可测组件返回有效延迟，且 bass 非零 ===")
rc, samples, dt = probe("bass")
check(rc == 0, f"bass 探测成功 (rc={rc})")
check(samples > 0, f"bass 测出**非零**延迟 {samples} 样本 "
                  f"({samples/RATE*1000:.2f} ms) —— 证明是真测而非恒 0")
check(0.1 < samples / RATE * 1000.0 < 50.0, "bass 延迟在工程合理区间 (<50ms)")

for comp in ("reverb", "eq", "tube", "crossfeed", "limiter", "post", "shelf"):
    rc, samples, dt = probe(comp)
    check(rc in (0, -3), f"{comp} 返回可解释的状态 (rc={rc}, {samples} samples)")

print("\n=== [3] 探测不干扰调用方正在使用的 handle ===")
# 注意：这里**不能**断言两次 process() 输出逐样本相同——bass 效果是有状态的，
# 两次调用之间它的内部状态本来就会推进，比对必然不等。真正要验证的不变量是
# 「探测没有污染/破坏调用方的 handle」。
live = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(RATE), 2048))
v = ctypes.c_int32(2)
lib.auradsp_set_param(live, b"mode.latency", ctypes.byref(v), 4)
one = ctypes.c_int32(1)
lib.auradsp_set_param(live, b"bass.enable", ctypes.byref(one), 4)
gain = ctypes.c_float(9.0)
lib.auradsp_set_param(live, b"bass.gain", ctypes.byref(gain), 4)

N = 256
buf = (ctypes.c_float * (N * 2))()
out = (ctypes.c_float * (N * 2))()
sp = ctypes.cast(buf, ctypes.POINTER(ctypes.c_float))
dp = ctypes.cast(out, ctypes.POINTER(ctypes.c_float))


def feed_and_run():
    # 用 80Hz：低音搁架在 440/660Hz 上几乎不起作用，bass 开关会测不出差异。
    for i in range(N):
        buf[i * 2] = 0.4 * math.sin(2 * math.pi * 80.0 * i / RATE)
        buf[i * 2 + 1] = 0.4 * math.sin(2 * math.pi * 80.0 * i / RATE)
    lib.auradsp_process(live, sp, dp, N)
    return [out[i] for i in range(N * 2)]


before = feed_and_run()
probe("reverb")          # 探测期间 live handle 仍在使用
probe("limiter")
after = feed_and_run()

finite = all(x == x and abs(x) < 1e6 for x in after)
check(finite, "探测后 live handle 输出仍然有限（无 NaN/Inf 污染）")
rms = math.sqrt(sum(x * x for x in after) / len(after))
check(0.05 < rms < 2.0, f"探测后 live handle 输出量级正常 (rms={rms:.4f})")

# 探测后 live handle 仍能正常处理（不 NaN、量级正常）——已由上面两条覆盖。
# 再验证「探测不在进程里留下全局残留」：探测前后新建的两个 handle，
# 对同一输入必须给出相同输出。
def render_fresh():
    hh = ctypes.c_void_p(lib.auradsp_create(ctypes.c_float(RATE), 2048))
    lv = ctypes.c_int32(2)
    lib.auradsp_set_param(hh, b"mode.latency", ctypes.byref(lv), 4)
    bb = (ctypes.c_float * (N * 2))()
    oo = (ctypes.c_float * (N * 2))()
    bp = ctypes.cast(bb, ctypes.POINTER(ctypes.c_float))
    op = ctypes.cast(oo, ctypes.POINTER(ctypes.c_float))
    for i in range(N):
        bb[i * 2] = 0.3 * math.sin(2 * math.pi * 1000.0 * i / RATE)
        bb[i * 2 + 1] = 0.3 * math.sin(2 * math.pi * 1000.0 * i / RATE)
    lib.auradsp_process(hh, bp, op, N)
    res = [oo[i] for i in range(N * 2)]
    lib.auradsp_destroy(hh)
    return res


fresh_before = render_fresh()
probe("reverb")
probe("limiter")
probe("bass")
fresh_after = render_fresh()
identical = all(abs(a - b) < 1e-6 for a, b in zip(fresh_before, fresh_after))
check(identical, "探测未在进程里留下全局残留（探测前后新建 handle 输出一致）")
lib.auradsp_destroy(live)

print("\n=== [4] 探测耗时可接受（用户显式点击才触发）===")
times = [probe("bass")[2] for _ in range(5)]
median_ms = statistics.median(times)
print(f"  5 次探测耗时: {[f'{t:.0f}ms' for t in times]}  中位数 {median_ms:.0f}ms")
check(median_ms < 400.0, f"单次探测中位数 {median_ms:.0f}ms < 400ms（不是秒级）")

print()
if FAILURES:
    print(f"FAILED ({len(FAILURES)}):")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1)
print("ALL TESTS PASSED: component latency impulse-response probe 100% OK!")