# -*- coding: utf-8 -*-
"""smoke_d2_rt_drain.py — D2 门禁：RT 在途守卫 + 确定性排空（替代 Sleep(50) 猜测）。

审查 D2：ASIO/VAIO 释放测试缓冲前 `Sleep(50)`（注释自述「等在途回调退出，
~10ms 量级」——纯猜测），而同作者的 VmBridge 已改成 rtInBlock 轮询。
两个方向的错：
  · 重载/驱动线程被挂住时 50ms 不够 → free 掉 RT 仍在读的缓冲 = UAF；
  · 空闲时又白睡 50ms（每次 test_stop / stop 都付）。
本轮统一为 RtInBlockGuard（RAII 保证成对增减）+ WaitRtDrained（墙钟上界），
并把 VmBridge 的 `for (i<3000) Sleep(1)`（名义 3s、实际 15-45s）一并改用墙钟。

三层：
  [A] 源码不变式：三个桥不得再有固定 Sleep 等待；必须接上 guard + 排空 helper
  [B] rt_drain_test.exe：guard 成对/嵌套 + 排空三种结局 + 排空延迟（10 断言）
  [C] ASIO 实测（需真实驱动；无驱动则 SKIP）：test_stop 耗时必须显著低于
      原来的固定 50ms —— 这是「不再是固定睡眠」的行为证据
"""
import ctypes
import json
import os
import re
import statistics
import subprocess
import sys
import time

# S1（2026-11-01）：仓库根由 __file__ 推导，替代作者机硬编码
# 旧写法为作者机绝对路径（见 test/engine_artifact.py 说明）。
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGES = os.path.join(ROOT, "core", "desktop", "windows-drivers", "bridge")
OUT = os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release")

ASIO_SRC = os.path.join(BRIDGES, "asio_bridge", "AsioBridge.cpp")
VAIO_SRC = os.path.join(BRIDGES, "vaio_bridge", "VaioBridge.cpp")
VM_SRC = os.path.join(BRIDGES, "vm_bridge", "VmBridge.cpp")
TEST_EXE = os.path.join(OUT, "rt_drain_test.exe")

fails = []
passes = 0


def check(name, ok, note=""):
    global passes
    if ok:
        passes += 1
        print(f"PASS  {name}" + (f"  ({note})" if note else ""))
    else:
        fails.append(name)
        print(f"FAIL  {name}" + (f"  ({note})" if note else ""))


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comments(src):
    """去掉 // 与 /* */ 注释（保留字符串内的内容不动，够用即可）。"""
    out = []
    i, n = 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


print("=== [A] 源码不变式：释放路径不得有固定 Sleep，必须接 guard + 排空 helper ===")


def func_body(code, name):
    """取 `void <name>() { ... }` 的函数体（括号配平）。找不到返回 None。"""
    m = re.search(r"\bvoid\s+" + re.escape(name) + r"\s*\(\s*\)\s*\{", code)
    if not m:
        return None
    i = code.index("{", m.start())
    depth = 0
    for j in range(i, len(code)):
        if code[j] == "{":
            depth += 1
        elif code[j] == "}":
            depth -= 1
            if depth == 0:
                return code[i:j + 1]
    return None


for tag, path in (("AsioBridge", ASIO_SRC), ("VaioBridge", VAIO_SRC), ("VmBridge", VM_SRC)):
    if not os.path.exists(path):
        check(f"{tag}.cpp exists", False, path)
        continue
    code = strip_comments(read(path))
    # A1 释放路径（FreeTestFile）内不得残留固定睡眠——这正是 D2 的三处现场。
    # 注意 VmBridge 的 FreeTestFile 是报告漏点：报告称 VmBridge "已修对"，
    # 实际只改了 DestroyEngines，FreeTestFile 仍是 Sleep(50)。
    body = func_body(code, "FreeTestFile")
    if body is None:
        check(f"{tag}: FreeTestFile found", False)
    else:
        check(f"{tag}: FreeTestFile free of fixed Sleep", "Sleep(" not in body)
        check(f"{tag}: FreeTestFile waits deterministically", "WaitRtDrained" in body)
    # A2 必须有确定性排空 helper
    check(f"{tag}: calls WaitRtDrained", "WaitRtDrained" in code)
    # A3 rtInBlock 必须被轮询（而非只看 testKind）
    check(f"{tag}: polls rtInBlock", "rtInBlock" in code)

# A4 ASIO/VAIO 的 RT 侧必须用 RAII guard（漏增/漏减都会让排空失效）
for tag, path in (("AsioBridge", ASIO_SRC), ("VaioBridge", VAIO_SRC)):
    code = strip_comments(read(path))
    check(f"{tag}: RT path uses RtInBlockGuard", "RtInBlockGuard" in code)

# A5 VmBridge 旧的 3000 次计数循环（名义 3s、实际 15-45s）必须消失。
# 正则用 [^)]* 而非 [^;]*：`for (int i = 0; i < 3000; ++i)` 里就带分号，
# 用 [^;]* 会漏判（首版断言因此空转，反向验证时该条仍 PASS）。
vm_code = strip_comments(read(VM_SRC))
old_loop = re.search(r"for\s*\([^)]*<\s*3000\s*;", vm_code) is not None
check("VmBridge: old 3000-iteration spin loop removed", not old_loop)

# A6 VmBridge 只允许剩一处 Sleep(50)——MonitorProc 里的 start 重试退避
# （20 次 × 50ms 等 VM 状态机，不是"等 RT 退出"）；释放/重建路径必须清零。
vm_sleep50 = len(re.findall(r"Sleep\s*\(\s*50\s*\)", vm_code))
check("VmBridge: only the start-retry backoff keeps Sleep(50)", vm_sleep50 <= 1,
      f"count={vm_sleep50}")
for tag, path in (("AsioBridge", ASIO_SRC), ("VaioBridge", VAIO_SRC)):
    code = strip_comments(read(path))
    n50 = len(re.findall(r"Sleep\s*\(\s*50\s*\)", code))
    check(f"{tag}: zero Sleep(50) left", n50 == 0, f"count={n50}")

print("\n=== [B] rt_drain_test.exe（guard 成对/嵌套 + 排空三结局 + 排空延迟） ===")
if not os.path.exists(TEST_EXE):
    check("rt_drain_test.exe exists", False, TEST_EXE)
else:
    check("rt_drain_test.exe exists", True)
    r = subprocess.run([TEST_EXE], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=120)
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    check("exit code 0", r.returncode == 0, f"rc={r.returncode}")
    data = None
    for ln in reversed(lines):
        s = ln.strip()
        if s.startswith("{"):
            try:
                data = json.loads(s)
                break
            except Exception:
                pass
    check("valid JSON result", isinstance(data, dict), str(data))
    if isinstance(data, dict):
        check("all C++ assertions ok", data.get("ok") is True and data.get("fail") == 0,
              json.dumps(data, ensure_ascii=False))
        check("at least 10 assertions ran", (data.get("pass") or 0) >= 10,
              f"pass={data.get('pass')}")
    joined = r.stdout
    check("guard pairing covered", "early-return paths leave counter at zero" in joined)
    check("nested guard covered", "nested guards count 1-2-1-0" in joined)
    check("timeout path covered", "bounded by wall clock on stuck RT" in joined)
    m = re.search(r"drain latency after stop signal ([\d.]+)ms", joined)
    drain_ms = float(m.group(1)) if m else None
    # 关键：< 50ms —— 若实现回退成 Sleep(50)，这里必然 ≥50 而判红
    check("drain latency < 50ms (not a fixed sleep)", drain_ms is not None and drain_ms < 50.0,
          f"{drain_ms}ms")

print("\n=== [C] ASIO 实测：test_stop 不再是固定 50ms 睡眠 ===")
CANDS = [
    os.environ.get("AURADSP_ASIO_BRIDGE_DLL", ""),
    os.path.join(ROOT, "test", "auraasio_bridge.dll"),
    os.path.join(OUT, "auraasio_bridge.dll"),
]
CANDS = [p for p in CANDS if p]
dll = next((p for p in CANDS if os.path.exists(p)), None)
if not dll:
    print("SKIP（auraasio_bridge.dll 不存在）")
else:
    try:
        b = ctypes.CDLL(dll)
    except OSError as e:
        print(f"SKIP（DLL 加载失败：{e}）")
        b = None
    if b is not None:
        # 2026-10-30 过渡期清理：公共面只导出 ab_*，先做旧名别名再绑定签名。
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from bridge_compat import alias_common, start_asio  # noqa: E402

        alias_common(b, "asio")
        b.asio_start = start_asio(b)

        for fn, rt, at in (
            ("asio_detect", ctypes.c_int, [ctypes.c_char_p, ctypes.c_int]),
            ("asio_stop", ctypes.c_int, []),
            ("asio_test_start", ctypes.c_int,
             [ctypes.c_int, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]),
            ("asio_test_stop", ctypes.c_int, []),
            ("asio_status", ctypes.c_int, [ctypes.c_char_p, ctypes.c_int]),
        ):
            getattr(b, fn).restype = rt
            getattr(b, fn).argtypes = at

        buf = ctypes.create_string_buffer(65536)
        rc = b.asio_detect(buf, len(buf))
        det = json.loads(buf.value.decode("utf-8", "replace")) if rc >= 0 else {}
        drivers = det.get("drivers") or []
        if not drivers:
            print("SKIP（未检测到 ASIO 驱动）")
        else:
            eng = os.path.join(ROOT, "test", "auradsp_engine.dll")
            # 不是所有枚举到的驱动都能用：例如 "DSD 转码器" 报
            # buffers-failed: driver has 0 input channels (<2) → rc=-4。
            # 逐个试，取第一个能起来的（与 smoke_asio_bridge.py 的口径一致）。
            started_name = None
            last = ""
            for cand in drivers:
                nm = cand["name"] if isinstance(cand, dict) else str(cand)
                rc = b.asio_start(nm.encode("utf-8"), eng.encode("utf-8"), b"", 0, 0)
                if rc == 0:
                    started_name = nm
                    break
                last = f"{nm}: rc={rc}"
            if started_name is None:
                print(f"SKIP（所有 ASIO 驱动均 start 失败，末次 {last}）")
            else:
                print(f"INFO  using driver: {started_name}")
                try:
                    b.asio_test_start(1, None, 0, 0, 0)  # 正弦 440Hz
                    time.sleep(0.15)
                    costs = []
                    for _ in range(30):
                        t0 = time.perf_counter()
                        rc_stop = b.asio_test_stop()
                        dt = (time.perf_counter() - t0) * 1000.0
                        if rc_stop != 0:
                            break
                        costs.append(dt)
                        b.asio_test_start(1, None, 0, 0, 0)
                    check("30 test_stop cycles issued", len(costs) == 30, f"n={len(costs)}")
                    if costs:
                        med = statistics.median(costs)
                        mx = max(costs)
                        mn = min(costs)
                        # pre-fix = Sleep(50) ⟹ 中位数 ≥50ms；修复版 = 等当前块
                        check("test_stop median well below 50ms", med < 30.0,
                              f"median={med:.2f}ms min={mn:.2f} max={mx:.2f}")
                        check("test_stop never a fixed sleep (max < 50ms)", mx < 50.0,
                              f"max={mx:.2f}ms")
                    b.asio_test_stop()
                finally:
                    b.asio_stop()

print()
if fails:
    print(f"D2 FAILURES: {fails}")
    sys.exit(1)
print(f"D2 ALL PASSED ({passes} checks)")
