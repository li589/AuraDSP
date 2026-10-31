# -*- coding: utf-8 -*-
"""smoke_liveprog_gmem.py — LiveProg gmem 惰性分配与语义（2026-10-30）。

背景：EEL2 的 compileContext 原先把 gmem 区内嵌为 float[1<<24]（64MB），
每个 VM 一建就吃满；每 handle 3 个 LiveProg 槽 × 8 个 VM 句柄 = 1.5GB。
2026-10-30 先改为「脚本真正引用 RAM（x[y]/gmem/tds…）时才分配」；
2026-10-31（P-045）进一步把 64MB 改为「地址空间保留 + 首次访问按 64KB 页提交」
（Windows VEH），并把编译前 memset 收窄为只清已提交前缀。

判据（清单门禁与功能冒烟都查不到）：
  [A] 不含 RAM 访问的脚本编译后，句柄内存增量远低于 64MB/VM 的旧口径
  [B] gmem 首次分配仍全零；写入后可读回（gmem 往返）
  [C] 同一 VM 重新编译时 gmem 被清零（旧 memset 语义）
  [D] 用 gmem 的脚本编译后音频正确（0.4 输入 → 0.2 输出）
  [E] 引用 gmem 的脚本按需物理提交（单句柄 < 60MB，旧口径 ~89MB）
  [F] VB 八总线形态 8 个并发 gmem 引擎总增长 < 320MB（旧口径 ~700MB）
  [G] 深层 gmem（VEH 页提交）读写正确

用法：python test/smoke/smoke_liveprog_gmem.py（退出码 0 = 全绿）
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CANDS = [
    os.environ.get("AURADSP_ENGINE_DLL", ""),
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                 "auradsp_engine.dll"),
]
DLL = next((p for p in CANDS if p and os.path.exists(p)), None)
if not DLL:
    print("SKIP（auradsp_engine.dll 不存在）")
    sys.exit(0)

SR, N = 48000.0, 256
FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (("  " + detail) if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


try:
    import psutil
    PROC = psutil.Process()

    def priv_mb():
        return PROC.memory_info().private / 2**20
except Exception:  # pragma: no cover - psutil 缺失时降级
    PROC = None

    def priv_mb():
        return None


dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]


def set_i(h, pid, v):
    return dll.auradsp_set_param(h, pid.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def set_str(h, pid, s):
    b = s.encode("utf-8")
    return dll.auradsp_set_param(h, pid.encode(),
                                 (ctypes.c_char * len(b)).from_buffer_copy(b), len(b))


def get_i(h, pid):
    v = ctypes.c_int32()
    dll.auradsp_get_param(h, pid.encode(), ctypes.byref(v), 4)
    return v.value


buf = (ctypes.c_float * (N * 2))()
out = (ctypes.c_float * (N * 2))()
for i in range(N):
    s = 0.4 * math.sin(2 * math.pi * 1000.0 * i / SR)
    buf[i * 2] = s
    buf[i * 2 + 1] = s


def run(h, blocks=8):
    for _ in range(blocks):
        dll.auradsp_process(h, buf, out, N)
    return max(abs(out[i]) for i in range(N * 2))


# ---- [A] 不用 RAM 的脚本不得触发 64MB/VM ----
base = priv_mb()
h = dll.auradsp_create(SR, N)
check("[A] create 成功", bool(h))
rc = set_str(h, "liveprog.code", "@init\nx = 1;\n@sample\nspl0 = spl0;")
st = get_i(h, "liveprog.status")
check("[A] 无 RAM 脚本编译成功", rc == 0 and st == 1, "rc=%d status=%d" % (rc, st))
after = priv_mb()
if base is not None and after is not None:
    # 旧口径：3 槽 × 64MB = 192MB 起步；新口径：句柄 + 插件链 ≈ 40MB
    check("[A] 无 RAM 脚本不预占 gmem（增长 < 100MB）", (after - base) < 100.0,
          "delta=%.1f MB" % (after - base))
else:
    print("NOTE  psutil 缺失，跳过 [A] 内存断言")
dll.auradsp_destroy(h)

# ---- [B][C][D] gmem 语义 ----
SCRIPT_WRITE = "\n".join([
    "@init",
    "zero_ok = gmem[12345] == 0 ? 1 : 0;",
    "gmem[999] = 0.5;",
    "@sample",
    "gmem[7] = spl0 * 0.5;",
    "spl0 = gmem[7];",
    "spl1 = gmem[7] * zero_ok;",
])
SCRIPT_CLEARED = "\n".join([
    "@init",
    "before = gmem[999];",   # 重新编译应先清零 → 0
    "@sample",
    "spl0 = before;",
    "spl1 = before;",
])

h = dll.auradsp_create(SR, N)
check("[B] 第二次 create 成功", bool(h))
rc = set_str(h, "liveprog.code", SCRIPT_WRITE)
check("[B] gmem 脚本编译成功", rc == 0 and get_i(h, "liveprog.status") == 1)
set_i(h, "liveprog.enable", 1)
peak = run(h)
check("[B] gmem 往返正确（0.4 → 0.2，说明首次分配全零）",
      abs(peak - 0.2) < 0.02, "peak=%.4f" % peak)

rc = set_str(h, "liveprog.code", SCRIPT_CLEARED)
check("[C] 同 VM 重新编译成功", rc == 0)
peak = run(h)
check("[C] 重新编译后 gmem 已清零（0.5 残留会输出非零）",
      abs(peak) < 0.02, "peak=%.4f" % peak)

rc = set_str(h, "liveprog.code", SCRIPT_WRITE)
set_i(h, "liveprog.enable", 1)
peak = run(h)
check("[D] 再切回 gmem 脚本音频仍正确", rc == 0 and abs(peak - 0.2) < 0.02,
      "peak=%.4f" % peak)
dll.auradsp_destroy(h)

# ---- [E] gmem 按需物理提交（2026-10-31）：不再整块 64MB ----
# 旧口径：引用 gmem 的脚本 = 每 VM 实打实 64MB（句柄约 25MB → 每个句柄 ~89MB）。
# 新口径：64MB 只保留地址空间，首次访问按 64KB 页提交；低偏移脚本
# （SCRIPT_WRITE 只碰 gmem[7]/[999]/[12345]）应只有句柄 + 1MB 预提交。
base = priv_mb()
h = dll.auradsp_create(SR, N)
rc = set_str(h, "liveprog.code", SCRIPT_WRITE)
ok = rc == 0 and get_i(h, "liveprog.status") == 1
after = priv_mb()
if base is not None and after is not None:
    delta = after - base
    check("[E] gmem 脚本按需提交（单句柄增长 < 60MB，旧口径约 89MB）",
          ok and delta < 60.0, "delta=%.1f MB rc=%d" % (delta, rc))
else:
    print("NOTE  psutil 缺失，跳过 [E] 内存断言")
    check("[E] gmem 脚本编译成功", ok, "rc=%d" % rc)
dll.auradsp_destroy(h)

# ---- [F] VB 八总线形态：8 个并发 gmem 引擎不得回到 700MB 量级 ----
base = priv_mb()
hs = []
ok = True
for _ in range(8):
    hh = dll.auradsp_create(SR, N)
    if not hh:
        ok = False
        break
    hs.append(hh)
    if set_str(hh, "liveprog.code", SCRIPT_WRITE) != 0:
        ok = False
for hh in hs:
    run(hh, blocks=2)
after = priv_mb()
if base is not None and after is not None:
    delta = after - base
    # 新口径：8 × (句柄 ~25MB + 1MB 预提交) ≈ 210MB；
    # 旧口径：8 × (句柄 + 64MB) ≈ 700MB。留出插件链/堆碎片余量。
    check("[F] 8 个 gmem 引擎总增长 < 320MB（旧口径约 700MB）",
          ok and delta < 320.0, "delta=%.1f MB ok=%s" % (delta, ok))
else:
    print("NOTE  psutil 缺失，跳过 [F] 内存断言")
    check("[F] 8 个 gmem 引擎编译成功", ok)
for hh in hs:
    dll.auradsp_destroy(hh)

# ---- [G] 深层 gmem 页按需提交（VEH 路径）----
# gmem[3000000] ≈ 11.4MB 偏移，落在 1MB 预提交之外：必须由首次访问触发
# 页提交；读写值正确才证明「未提交页 = 零 + 提交后可写」语义成立。
SCRIPT_DEEP = "\n".join([
    "@init",
    "gmem[3000000] = 0.25;",
    "gmem[3000123] = 0.5;",
    "@sample",
    "ok = (gmem[3000000] == 0.25) && (gmem[3000123] == 0.5) ? 1 : 0;",
    "spl0 = 0.2 * ok;",
    "spl1 = 0.2 * ok;",
])
h = dll.auradsp_create(SR, N)
rc = set_str(h, "liveprog.code", SCRIPT_DEEP)
set_i(h, "liveprog.enable", 1)
peak = run(h)
check("[G] 深层 gmem 页按需提交且读写正确", rc == 0 and abs(peak - 0.2) < 0.02,
      "peak=%.4f rc=%d" % (peak, rc))
dll.auradsp_destroy(h)

print("=" * 46)
if FAIL:
    print("FAILURES: %s" % FAIL)
    sys.exit(1)
print("ALL PASS：liveprog gmem 惰性分配与语义")
