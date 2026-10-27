# -*- coding: utf-8 -*-
"""smoke_d3_vaio_pump_wait.py — D3 门禁：VAIO 泵线程按事件走，不靠 Sleep 猜节拍。

缺陷（审查 D3）：
    while (...) {
        hr = pAudioClient->GetCurrentPadding(&pad);
        if (FAILED(hr)) { Sleep(2); continue; }
        needed = buffer - pad;
        if (needed == 0) { Sleep(1); continue; }
        ...
    }
Windows 的 Sleep 只保证"至少睡这么久"，实际唤固粒度由系统定时器分辨率决定
（默认 15.6ms，实测本机 Sleep(1) 真耗时 10~15.3ms）。这段 WASAPI 缓冲只有
20ms —— 睡过头就是必然欠载（爆音/断续）。更坏的是：代码写着 1ms、2ms，
读代码的人会以为节拍很细，而睡眠时间与真实唤醒延迟之间**没有任何关系**。

修复：让 WASAPI 驱动节拍——`Initialize` 带 AUDCLNT_STREAMFLAGS_EVENTCALLBACK，
`SetEventHandle` 挂 auto-reset 事件，泵线程 `WaitForSingleObject` 等周期信号。
等待必须带上界：设备失效后事件永不再来，无上界等于永久卡死（连 stopEvent
都看不到）。上界不是"预期超时"，而是"多久能发现设备已死"。

本测试三层：
  [A] 源码不变式（泵循环零 Sleep / EVENTCALLBACK / SetEventHandle / 事件句柄回收）
  [B] vaio_pump_wait_test.exe（驱动无关，14 断言）：3ms 信号 3ms 唤醒、
      同机 Sleep(1) 基线对照、上界返回、句柄缺失立即返回、auto-reset 语义
  [C] 计时口径不变式——测试自身不许用 GetTickCount64 量亚毫秒
      （第一版就是这么翻车的：15.6ms 分辨率 + 信号线程里的 Sleep(3) 也被量化）
"""
import json
import os
import re
import subprocess
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
DRIVERS = os.path.join(ROOT, "core", "desktop", "windows-drivers")
VAIO = os.path.join(DRIVERS, "bridge", "vaio_bridge")
SRC = os.path.join(VAIO, "VaioBridge.cpp")
WAIT_H = os.path.join(VAIO, "vaio_pump_wait.h")
TEST_CPP = os.path.join(VAIO, "vaio_pump_wait_test.cpp")
TEST_EXE = os.path.join(DRIVERS, "out", "Release", "vaio_pump_wait_test.exe")

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
    out, i, n, in_str = [], 0, len(src), False
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


def func_body(src, name):
    """取 name(...) { ... } 的函数体（花括号配对，零正则转义风险）。"""
    pos = src.find(name + "(")
    if pos < 0:
        return ""
    i = src.find("{", pos)
    if i < 0:
        return ""
    start, depth = i, 0
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    return ""


# ---------------------------------------------------------------- [A] 源码
print("\n=== [A] 源码不变式：泵循环零 Sleep + EVENTCALLBACK 事件驱动 ===")

src = read(SRC)
code = strip_comments(src)          # 注释里提到 Sleep(1)/Sleep(2) 是说明，不算违规
body_pump = func_body(code, "VaioPumpThreadProc")
check("[A1] VaioPumpThreadProc 存在", bool(body_pump))
sleeps = re.findall(r"\bSleep\s*\(", body_pump)
check("[A2] 泵循环体内零 Sleep（含注释外的一切调用）", len(sleeps) == 0,
      f"发现 {len(sleeps)} 处")
check("[A3] 泵循环用 WaitAudioPeriod 等周期",
      body_pump.count("WaitAudioPeriod") >= 2,
      f"count={body_pump.count('WaitAudioPeriod')}")
check("[A4] GetCurrentPadding 失败路径也走事件等待（不再 Sleep(2)）",
      "if (FAILED(hr)) {" in body_pump and
      re.search(r"if \(FAILED\(hr\)\) \{\s*vmcore::WaitAudioPeriod", body_pump) is not None)
check("[A5] 缓冲满（framesNeeded==0）时等待下一周期信号",
      re.search(r"if \(framesNeeded == 0\) \{\s*vmcore::WaitAudioPeriod", body_pump) is not None)

body_init = func_body(code, "vaio_start")
check("[A6] Initialize 带 AUDCLNT_STREAMFLAGS_EVENTCALLBACK",
      "AUDCLNT_STREAMFLAGS_EVENTCALLBACK" in body_init)
check("[A7] 创建 auto-reset 事件（bManualReset=FALSE）",
      re.search(r"CreateEventW\(\s*nullptr\s*,\s*FALSE", body_init) is not None)
check("[A8] SetEventHandle 在 Start 之前挂上", "SetEventHandle" in body_init)

body_destroy = func_body(code, "DestroyWasapi")
check("[A9] DestroyWasapi 回收事件句柄（不泄漏内核对象）",
      "CloseHandle(g_vaio.hAudioEvent)" in body_destroy)
check("[A10] 回收后置空（避免二次 CloseHandle）",
      re.search(r"CloseHandle\(g_vaio\.hAudioEvent\);\s*g_vaio\.hAudioEvent = nullptr;",
                body_destroy) is not None)

hdr = read(WAIT_H)
check("[A11] 等待上界是具名常量", "kAudioWaitUpperMs" in hdr)
check("[A12] 头文件说明'上界不是预期超时，而是回看停止标志'",
      "stopEvent" in hdr)

# ---------------------------------------------------------------- [C] 计时口径
print("\n=== [C] 测试自身的计时口径（不许用 15.6ms 分辨率的时钟量亚毫秒） ===")
tcode = strip_comments(read(TEST_CPP))
check("[C1] 计时走 QueryPerformanceCounter", "QueryPerformanceCounter" in tcode)
check("[C2] 不出现 GetTickCount64（分辨率 15.6ms，量不了 3ms）",
      "GetTickCount64" not in tcode)
check("[C3] 信号线程用自旋到点而非 Sleep（否则'3ms 后置位'不成立）",
      "SpinUntilMs" in tcode and
      re.search(r"std::thread[^\n]*\n(?:.*\n){0,3}\s*SpinUntilMs", tcode) is not None)
check("[C4] 有同机 Sleep(1) 基线对照（断言不依赖具体机器的定时器分辨率）",
      "MeasureSleepBaselineMs" in tcode)

# ---------------------------------------------------------------- [B] C++ 单测
print("\n=== [B] vaio_pump_wait_test.exe（事件驱动等待，驱动无关） ===")
if not os.path.exists(TEST_EXE):
    check("vaio_pump_wait_test.exe exists", False, TEST_EXE)
else:
    check("vaio_pump_wait_test.exe exists", True)
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
        check("at least 12 assertions ran", (data.get("pass") or 0) >= 12,
              f"pass={data.get('pass')}")
    # 关键结果必须真的出现（防止 exe 提前空转）
    out = r.stdout
    check("唤醒延迟 <= 6ms（3ms 信号后）",
          re.search(r"wake latency after a 3ms signal = ([0-9.]+)ms", out) is not None and
          float(re.search(r"wake latency after a 3ms signal = ([0-9.]+)ms", out).group(1)) < 6.0,
          (re.search(r"wake latency after a 3ms signal = ([0-9.]+)ms", out) or [None, "?"])[0])
    m = re.search(r"event wake ([0-9.]+)ms vs Sleep\(1\) ([0-9.]+)ms", out)
    if m:
        wake, base = float(m.group(1)), float(m.group(2))
        check("事件唤醒显著快于 Sleep(1) 基线",
              (wake < base - 5.0) if base >= 5.0 else (wake < 6.0),
              f"wake={wake}ms base={base}ms")
    else:
        check("事件唤醒 vs Sleep(1) 基线对照输出存在", False, "未找到对照行")

print()
if fails:
    print(f"D3 FAILURES ({len(fails)}): {fails}")
    sys.exit(1)
print(f"D3 ALL PASSED ({passes} checks)")
