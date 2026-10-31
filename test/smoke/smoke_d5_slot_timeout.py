# -*- coding: utf-8 -*-
"""smoke_d5_slot_timeout.py — D5 门禁：插件槽异步任务等待上界 150s → 5s。

审查 D5：`audio_slots.dart` 的 `_submitAndWait` 原本 `for (i < 30000) { await 5ms }`
= **150s**，而同一段注释自承实测 p50 18.2ms / max 231.3ms——正常路径连千分之一
都用不到。真挂死时用户对着转圈的 spinner 等 2.5 分钟，且没有任何提示。

这类"上界数值"改动很难做端到端行为测试（要复现"插件挂死"得先有一个会挂死的
插件），故本门禁守在**契约层**：数值上界 + 收口方式 + 报错链路 + 兜底存在性，
任一项回退即判红。

[A] 上界是常量且 ≤10s（不得再出现 30000 轮 / 150s 这种量级）
[B] 按墙钟（Stopwatch）收口，不是"轮数 × 名义间隔"
    ——同一坑在 C++ 侧踩过（D2：Sleep(1) 实际 5-15ms，3000 次名义 3s 实测 45s）
[C] 超时后必须兜底收口（异步 unload 会被 taskState==1 拒，只能同步 unload）
[D] `timedOut` 必须随终态事件上报（否则 UI 无法区分"插件报错"与"没回来"）
[E] 两个调用点都必须接住 (rc, timedOut) 二元组
"""
import os
import re
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
SRC = os.path.join(ROOT, "app", "auradsp_app", "lib", "engine", "audio_slots.dart")

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


if not os.path.exists(SRC):
    print(f"SKIP（{SRC} 不存在）")
    sys.exit(0)

src = open(SRC, "r", encoding="utf-8").read()
# 去注释后再做"不得出现"类断言（注释里会解释旧值，不能误伤）
code_lines = []
in_block = False
for line in src.splitlines():
    s = line.strip()
    if in_block:
        if "*/" in s:
            in_block = False
        continue
    if s.startswith("/*"):
        if "*/" not in s:
            in_block = True
        continue
    if s.startswith("//"):
        continue
    code_lines.append(re.sub(r"//.*$", "", line))
code = "\n".join(code_lines)

print("=== [A] 上界数值 ===")
m = re.search(r"kSlotTaskMaxWaitMs\s*=\s*(\d+)", code)
check("kSlotTaskMaxWaitMs declared", m is not None)
if m:
    val = int(m.group(1))
    check("upper bound <= 10s", val <= 10000, f"{val}ms")
    check("upper bound == 5000ms (as designed)", val == 5000, f"{val}ms")

# 旧上界必须消失（代码里不得再有 30000 轮循环）
check("old 30000-iteration loop removed", "30000" not in code,
      "found 30000" if "30000" in code else "")

print("\n=== [B] 按墙钟收口，而非轮数 × 名义间隔 ===")
check("uses Stopwatch for the deadline", "Stopwatch()" in code)
check("loop condition is wall-clock", re.search(r"elapsedMilliseconds\s*<", code) is not None)
check("no `for (int i = 0; i < <count>` polling", re.search(r"for\s*\(\s*int\s+i\s*=\s*0", code) is None)

print("\n=== [C] 超时兜底收口 ===")
check("timeout path calls synchronous unload",
      "pluginSlotUnloadWrap" in code and "_forceUnloadStuckSlot" in code)
# 兜底必须用 try/catch 包住（兜底自己失败不能把异常抛给调用方）
fb = re.search(r"void _forceUnloadStuckSlot[\s\S]{0,600}", code)
check("fallback is guarded by try/catch",
      fb is not None and "try {" in fb.group(0) and "catch" in fb.group(0))

print("\n=== [D] timedOut 随终态事件上报 ===")
check("pluginSlotLoaded event carries timedOut", "if (timedOut) 'timedOut': true," in code or
      "'timedOut': true" in code)
# 两个事件都要带
check("both events carry timedOut",
      code.count("'timedOut': true") >= 2, f"count={code.count(chr(39)+'timedOut'+chr(39)+': true')}")

print("\n=== [E] 调用点接住三元组（rc, timedOut, accepted） ===")
tuples = len(re.findall(r"final\s+\(rc,\s*timedOut,\s*accepted\)\s*=\s*await\s+_submitAndWait", code))
check("both call sites destructure (rc, timedOut, accepted)", tuples == 2, f"found {tuples}")
check("_submitAndWait returns (int, bool, bool)",
      re.search(r"Future<\(int,\s*bool,\s*bool\)>\s+_submitAndWait", code) is not None)
# 被拒（该槽已有任务在跑）不得再发终态事件（否则 UI 误报失败并清镜像）
check("rejected path skips terminal event", code.count("if (!accepted) return 0;") >= 2,
      f"count={code.count('if (!accepted) return 0;')}")

print("\n=== [F] 超时仍归属失败语义（rc=0） ===")
check("timeout returns rc=0 + timedOut=true + accepted=true", "return (0, true, true);" in code)

print()
if fails:
    print(f"D5 FAILURES: {fails}")
    sys.exit(1)
print(f"D5 ALL PASSED ({passes} checks)")
