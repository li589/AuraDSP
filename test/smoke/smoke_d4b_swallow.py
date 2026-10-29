# -*- coding: utf-8 -*-
"""smoke_d4b_swallow.py — D4-b 门禁：静默异常必须留痕或显式标记。

缺陷（审查 D4-b）：
    全仓 97 处 catch 既不留痕也不绑定异常。`catch (_) {}` 把异常对象和堆栈
    一起丢掉——它是「我拒绝观测」的语法。

    最要命的是隔离区泵循环的三个后端分支：

        if (asioActive && ab != null) {
          try { ...可视化/状态... } catch (_) {}
          continue;
        }

    整个迭代体包在 catch 里。一次类型错误（比如桥返回的 Map 少一个键）就能让
    可视化**永远**冻结：每 5ms 失败一次、静默吞掉、continue 继续。日志里一个
    字都没有，用户只看到「频谱不动了」。而这一层恰好是排障时唯一能用的信号。

    另一类危害较轻但同样致命的是「用户可感知的静默」：预设保存失败返回 false，
    调用方只看到 false，不知道为什么——是磁盘满、权限、还是 JSON 结构变了？

四类分治：
    C 类  循环体包壳           → 必须 swallowThrottled(（唯一会「永远静默」的形态）
    A 类  兜底退化             → swallow( 留痕
    B 类  清理忽略             → 允许 `// swallow: <理由>` 豁免
    D 类  test/                → 豁免

本测试五层：
  [A] 规则引擎单元：构造 8 段片段，逐条验证 R1/R2/R3/R4 判红、注释与字符串排除
  [B] 全仓门禁：0 违规，且规模非空转
  [C] 覆盖证据：代码级 `catch (_)` 仅剩 1 处（debug_log 自引用，带标记）；
      热路径 10 处全部是 swallowThrottled（P1 收敛：三桥 5×3→5、泵循环 3→1）；
      swallow 调用 ≥ 70
  [D] 反向验证：把真实源码里已修的一处改回 `catch (_) {}`，门禁必须判红
      （不做这层，就无法排除「扫描器什么都没扫到也算通过」的空转）
  [E] 接线完整性：每个调用 swallow 的文件（或其 part 所属 library）都 import 了
      error_sink.dart——这条抓的是 state.dart 漏 import 那类错误：part 文件
      共享 library 作用域，只改 part 是编译不过的
"""
import io
import os
import re
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
APP = os.path.join(ROOT, "app", "auradsp_app")
LIB = os.path.join(APP, "lib")
SINK = os.path.join(LIB, "core", "error_sink.dart")
TOOLS = os.path.join(ROOT, "tools", "bin")   # 门禁扫描器在 bin/（同 abi_consistency.py）

sys.path.insert(0, TOOLS)
import dart_swallow_scan as S  # noqa: E402

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
    with io.open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def iter_dart(base):
    for dirpath, _d, files in os.walk(base):
        for fn in files:
            if fn.endswith(".dart"):
                yield os.path.join(dirpath, fn)


# ---------------------------------------------------------------- [A] 规则引擎
print("== [A] 规则引擎单元 ==")

A_CASES = [
    # (名称, 片段, 期望违规规则前缀)
    ("R1+R3 catch(_) 空块", "void f(){ try { g(); } catch (_) {} }", "R1"),
    ("R3 只报匿名（非空块）", "void f(){ try { g(); } catch (_) { return 0; } }", "R3"),
    ("R1 空块但绑定了 e", "void f(){ try { g(); } catch (e) { } }", "R1"),
    ("R2 循环包壳用 swallow 不够",
     "void f(){ while(x){ try { g(); } catch (e, st) { swallow(e, st); } continue; } }", "R2"),
    ("R4 理由敷衍", "void f(){ try { g(); } catch (_) {\n  // swallow: ok\n} }", "R4"),
    ("合规：return 兜底", "bool f(){ try { g(); } catch (e) { return false; } return true; }", ""),
    ("合规：清理路径标记",
     "void f(){ try { g(); } catch (_) {\n  // swallow: 停不下来也不改变决定\n} }", ""),
    ("合规：循环包壳用 throttled",
     "void f(){ while(x){ try { g(); } catch (e, st) { swallowThrottled(e, st, 'p'); } continue; } }", ""),
    ("排除：注释里的 catch(_)", "// try { g(); } catch (_) {}\nvoid f(){ }", ""),
    ("排除：字符串里的 catch(_)", "var s = 'try { } catch (_) {}';\n", ""),
    ("排除：块注释里的 catch(_)", "/* try { } catch (_) {} */\nvoid f(){ }", ""),
]

for name, src, want in A_CASES:
    sites = S.analyze_source(src)
    viol = [v for s in sites for v in s["violations"]]
    if want == "":
        check(name, not viol, f"viol={viol}")
    else:
        hit = [v for v in viol if v.startswith(want)]
        check(name, bool(hit), hit[0] if hit else f"未命中 {want}，实际={viol}")

# 括号配对：嵌套 catch 不能漏
NESTED = """
void f() {
  try {
    try { g(); } catch (e) { swallow(e, StackTrace.current); }
  } catch (_) {}
}
"""
nested = S.analyze_source(NESTED)
check("嵌套 try/catch 各自独立判定",
      len(nested) == 2 and sum(1 for s in nested if s["violations"]) == 1,
      f"catches={len(nested)} viol={sum(1 for s in nested if s['violations'])}")

# ---------------------------------------------------------------- [B] 全仓门禁
print("\n== [B] 全仓门禁 ==")

all_sites = []
for p in iter_dart(LIB):
    rel = os.path.relpath(p, ROOT).replace("\\", "/")
    all_sites.extend(S.analyze_source(read(p), rel))

bad = [s for s in all_sites if s["violations"]]
check("lib/ 无违规 catch 块", not bad,
      "违规 %d 处：" % len(bad) + ", ".join("%s:%d" % (s["file"], s["line"]) for s in bad[:6]))
check("扫描规模非空转（>= 140 处 catch）", len(all_sites) >= 140, f"实际 {len(all_sites)}")

by_class = {}
for s in all_sites:
    by_class[s["class"]] = by_class.get(s["class"], 0) + 1
check("存在 C 类（循环包壳）且已全部转 throttled", by_class.get("C", 0) == 1,
      f"分类={by_class}")

# 子进程口径也必须一致（防止模块内与 CLI 判定漂移）
import subprocess  # noqa: E402
proc = subprocess.run([sys.executable, os.path.join(TOOLS, "dart_swallow_scan.py")],
                      capture_output=True, text=True, encoding="utf-8", errors="replace")
check("CLI 门禁退出码 0", proc.returncode == 0, f"rc={proc.returncode}")
check("CLI 输出含『全部通过』", "全部通过" in (proc.stdout or ""),
      (proc.stdout or "")[-120:].replace("\n", " "))

# ---------------------------------------------------------------- [C] 覆盖证据
print("\n== [C] 覆盖证据 ==")

under_code = 0
for p in iter_dart(LIB):
    mask = S.strip_comments_and_strings(read(p))
    under_code += len(re.findall(r"\bcatch\s*\(\s*_\s*\)", mask))
check("代码级 catch (_) 仅剩 1 处（debug_log 自引用）", under_code == 1,
      f"实际 {under_code} 处")

throttled = sum(1 for s in all_sites if "swallowThrottled(" in s["logged"])
# P1 收敛后：三桥公共面 5 处 × 3 份 → AudioBridgeCore 一份 5 处；
# 泵循环三个后端分支 3 处 → 单点 1 处。10 = 5 + 3(bridge-plugin-ffi) + 1(eq-probe) + 1(pump)。
check("热路径限流出口 10 处", throttled == 10, f"实际 {throttled}")

plain = sum(1 for s in all_sites if "swallow(" in s["logged"])
check("普通留痕出口 >= 70 处", plain >= 70, f"实际 {plain}")

# 三座桥 + 泵循环必须各自带 tag，而不是共用一个（共用会让「哪座桥坏了」不可辨）。
# P1 收敛后三桥公共面共用 AudioBridgeCore 的 catch（tag 取构造参数 logTag），
# 泵循环三份收敛为一份（tag 由后端派生）——静态字面量必须连构造点一起扫。
iso_src = read(os.path.join(LIB, "engine", "audio_isolate.dart"))
tags = set()
for p in iter_dart(LIB):
    src = read(p)
    tags.update(t for t in re.findall(
        r"swallowThrottled\(e, st, '([^']+)'\)", src) if '$' not in t)
    tags.update(re.findall(r"logTag:\s*'([^']+)'", src))
WANT_TAGS = {"vb-ffi", "ab-ffi", "vaio-ffi", "bridge-plugin-ffi", "eq-probe"}
check("限流 tag 覆盖各自独立来源（多余或缺失都不行）",
      tags == WANT_TAGS,
      f"缺={sorted(WANT_TAGS - tags)} 多={sorted(tags - WANT_TAGS)}")

# 泵循环单点 catch 的 tag 必须由实际后端派生（vm→vb，与 viz backend 同口径），
# 展开后逐字还原旧三份 pump-vb/pump-asio/pump-vaio——共用不可辨的常量才判红。
pump_tags = set()
m_pump = re.search(r"swallowThrottled\(e, st, 'pump-\$(\w+)'\)", iso_src)
if m_pump:
    var = m_pump.group(1)
    m_map = re.search(r"%s\s*=\s*(\w+)\s*==\s*'vm'\s*\?\s*'vb'\s*:\s*\1" % var, iso_src)
    if m_map:
        base = m_map.group(1)
        if re.search(r"%s\s*=\s*bridgeManager\.activeId" % base, iso_src):
            pump_tags = {'pump-' + ('vb' if b == 'vm' else b)
                         for b in ('vm', 'asio', 'vaio')}
check("泵循环 tag 由 activeId 派生且还原旧三个 tag",
      pump_tags == {"pump-vb", "pump-asio", "pump-vaio"},
      f"tags={sorted(pump_tags)}")

# ---------------------------------------------------------------- [D] 反向验证
print("\n== [D] 反向验证 ==")

PRESETS = os.path.join(LIB, "core", "presets.dart")
src = read(PRESETS)
needle = "} catch (e, st) { swallow(e, st); }"
check("反向验证锚点存在", src.count(needle) >= 1, f"命中 {src.count(needle)} 次")
if src.count(needle) >= 1:
    broken = src.replace(needle, "} catch (_) {}", 1)
    rv = [s for s in S.analyze_source(broken, "presets.dart") if s["violations"]]
    check("改回 catch (_) {} 后门禁判红", len(rv) >= 1,
          f"violations={[v for s in rv for v in s['violations']][:2]}")

# 循环体退回普通留痕也必须判红（R2 单独反向验证）
ISO = os.path.join(LIB, "engine", "audio_isolate.dart")
iso = iso_src
m = re.search(r"swallowThrottled\(e, st, 'pump-\$vizBackend'\)", iso)
check("反向验证锚点 2 存在（泵循环派生 tag）", m is not None)
if m:
    broken2 = iso.replace(
        "swallowThrottled(e, st, 'pump-$vizBackend')", "swallow(e, st)", 1)
    rv2 = [s for s in S.analyze_source(broken2, "audio_isolate.dart") if s["violations"]]
    check("泵循环退回 swallow 后 R2 判红",
          any(v.startswith("R2") for s in rv2 for v in s["violations"]),
          f"violations={[v for s in rv2 for v in s['violations']][:2]}")

# ---------------------------------------------------------------- [E] 接线完整性
print("\n== [E] 接线完整性 ==")


def imports_sink(path):
    src = read(path)
    if re.search(r"^import\s+['\"][^'\"]*error_sink\.dart['\"];", src, re.M):
        return True
    m = re.search(r"^part\s+of\s+['\"]([^'\"]+)['\"];", src, re.M)
    if m:
        lib = os.path.normpath(os.path.join(os.path.dirname(path), m.group(1)))
        if os.path.exists(lib) and lib != path:
            return imports_sink(lib)
    return False


users = []
for p in iter_dart(LIB):
    if os.path.normpath(p) == os.path.normpath(SINK):
        continue
    mask = S.strip_comments_and_strings(read(p))
    if "swallow(" in mask or "swallowThrottled(" in mask:
        users.append(p)

unwired = [p for p in users if not imports_sink(p)]
check("调用 swallow 的文件可达 error_sink 的 import",
      not unwired, "缺 import：" + ", ".join(os.path.basename(p) for p in unwired[:6]))
check("接线文件数 >= 15", len(users) >= 15, f"实际 {len(users)}")

sink_src = read(SINK)
check("swallowThrottled 先判后建（shouldLog 在 dbgLog 之前）",
      sink_src.find("if (!log.shouldLog) return;") < sink_src.find("dbgLog('[swallow/$tag"))
check("_site 跳过 error_sink 自身帧", "error_sink.dart" in sink_src and "_site(stack)" in sink_src)
check("提供限流重置入口（供测试）", "resetSwallowThrottlesForTest" in sink_src)

print()
if fails:
    print(f"D4-b FAILURES ({len(fails)}): {fails}")
    sys.exit(1)
print(f"D4-b ALL PASSED ({passes} checks)")
