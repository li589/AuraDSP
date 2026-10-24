# -*- coding: utf-8 -*-
"""smoke_d6_patch_ids.py — D6 门禁：补丁编号单点化。

缺陷（审查 D6 / §7-4）：
    代码里 77 处 `PATCHED-AuraDSP` 标记，45 处不含 `P-NNN` 编号，只写工程专项
    代号；而 `engine/legacy/PATCHES.md` 号称是补丁唯一真相源，实际九套编号并存：

        P-001..P-015（vendor 补丁序列）   B1 / B1-b / B1-c / B1-d / B4 / B5
        D7（审查专项）                    Z13 / Z14（历史行内标注）
        M3.5-c（UI 重排序）               P2.4（旧方案编号）
        以及直接拿日期当编号的 `2026-10-17`

    后果不是"不好看"，而是**查不到**：拿代码里的 `B5` 去登记表查，查不到（B5 从未
    在 PATCHES.md 出现过）；`P2.4` 全仓只命中一处 PDF 二进制——等于没有登记。

两种漏网形态（本测试各留一条断言，它们都是真实存在过的）：
    ① `[PATCHED-AuraDSP 2026-10-09] …（P-002，见 PATCHES.md）`
       编号写在说明文字里 → 按行 grep 看着"有编号"，标记位其实是空的
    ② `[PATCHED-AuraDSP 2026-10-13 P-011]`
       日期在编号前 → `grep 'PATCHED-AuraDSP P-'` 搜不到

修法：`P-NNN` 单调递增、永不复用，是唯一权威标识；工程专项代号降级为别名写在
编号之后（`P-018 B1-c`），只用于和审查报告章节对照。

本测试五层：
  [A] 规则引擎单元：G1/G2 判红、两种漏网形态必须被拒、别名解析
  [B] 全仓门禁：0 违规 + 规模非空转 + CLI 口径一致
  [C] 覆盖证据：13 个专项映射精确、别名集合精确、全局 grep 口径可捞全
  [D] 反向判红：去掉编号 / 换成未登记号 / 别名冲突
  [E] 登记表结构：P-001..P-026 连续无缺无重复、新条目字段齐全
"""
import io
import json
import os
import re
import subprocess
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
BIN = os.path.join(ROOT, "tools", "bin")
PATCHES = os.path.join(ROOT, "engine", "legacy", "PATCHES.md")

sys.path.insert(0, BIN)
import patch_id_scan as P  # noqa: E402

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


REG = {"P-002": "", "P-013": "", "P-018": "", "P-019": ""}

# ---------------------------------------------------------------- [A] 规则单元
print("== [A] 规则引擎单元 ==")

A_CASES = [
    # (名称, 方括号内文本, 期望：'' = 合规，否则违规码前缀)
    ("G1 只写专项代号", " B5", "G1"),
    ("G1 空标记", "", "G1"),
    ("G2 编号未登记", " P-999 B5", "G2"),
    ("G1 编号写在说明文字里（漏网形态①）",
     " 2026-10-09 分带展宽（P-002，见 PATCHES.md）", "G1"),
    ("G1 日期在编号前（漏网形态②）", " 2026-10-13 P-002", "G1"),
    ("合规：编号+别名", " P-018 B1-c", ""),
    ("合规：只有编号", " P-002", ""),
    ("合规：编号+日期", " P-002 2026-10-09", ""),
]
for name, tail, want in A_CASES:
    num, alias, viol = P.evaluate(tail, REG)
    if want == "":
        check(name, not viol, f"viol={viol}")
    else:
        hit = [v for v in viol if v.startswith(want)]
        check(name, bool(hit), hit[0] if hit else f"未命中 {want}，实际={viol}")

ALIAS_CASES = [
    (" P-018 B1-c", "B1-c"),
    (" P-002", ""),
    (" P-002 2026-10-09", ""),
    (" P-023 M3.5-c", "M3.5-c"),
    (" P-019 B1-d", "B1-d"),
    (" P-013 上层 id 列表", ""),      # 中文说明不是别名
]
for tail, want in ALIAS_CASES:
    got = P.alias_of(tail)
    check("alias_of(%r) == %r" % (tail.strip()[:24], want), got == want, f"实际 {got!r}")

# ---------------------------------------------------------------- [B] 全仓门禁
print("\n== [B] 全仓门禁 ==")

sites, registry, dup = P.scan(ROOT)
bad = [s for s in sites if s["violations"]]
check("代码标记无违规", not bad and not dup,
      ", ".join("%s:%d" % (s["file"], s["line"]) for s in bad[:6]) or str(dup))
check("标记规模非空转（>= 70 处）", len(sites) >= 70, f"实际 {len(sites)}")
check("登记表规模（>= 25 条）", len(registry) >= 25, f"实际 {len(registry)}")

proc = subprocess.run([sys.executable, os.path.join(BIN, "patch_id_scan.py")],
                      capture_output=True, text=True, encoding="utf-8",
                      errors="replace")
check("CLI 门禁退出码 0", proc.returncode == 0, f"rc={proc.returncode}")
check("CLI 输出含『全部通过』", "全部通过" in (proc.stdout or ""),
      (proc.stdout or "")[-100:].replace("\n", " "))

# ---------------------------------------------------------------- [C] 覆盖证据
print("\n== [C] 覆盖证据 ==")

per_id = {}
for s in sites:
    per_id[s["id"]] = per_id.get(s["id"], 0) + 1

# 本次新分配/承接的 12 个专项，出现次数必须与代码实际一致
EXPECT = {
    "P-013": 1,   # 上层 id 列表 → vendor stage id（原先无编号）
    "P-015": 1,   # stereoEnhancement 平滑等功率（原先拿日期当编号）
    "P-016": 5,   # B1
    "P-017": 9,   # B1-b
    "P-018": 7,   # B1-c
    "P-019": 1,   # B1-d
    "P-020": 7,   # B4
    "P-021": 2,   # B5
    "P-022": 3,   # D7
    "P-023": 3,   # M3.5-c
    "P-024": 2,   # Z13
    "P-025": 2,   # P2.4
    "P-026": 1,   # E4（stage16 跨模式采样点）
}
wrong = {k: (per_id.get(k, 0), v) for k, v in EXPECT.items() if per_id.get(k, 0) != v}
check("13 个专项的标记数精确匹配", not wrong,
      "编号(实际,期望): " + json.dumps(wrong, ensure_ascii=False) if wrong else "")

aliases = {s["alias"] for s in sites if s["alias"]}
WANT_ALIAS = {"B1", "B1-b", "B1-c", "B1-d", "B4", "B5", "D7", "M3.5-c", "Z13", "P2.4",
              "E4"}
check("别名集合精确（多余或缺失都不行）", aliases == WANT_ALIAS,
      f"缺={sorted(WANT_ALIAS - aliases)} 多={sorted(aliases - WANT_ALIAS)}")

# 全局 grep 口径：§7-4 要求 `grep PATCHED-AuraDSP` 必须匹配 P-\d{3}
grep_bad = 0
for s in sites:
    if not re.match(r"P-\d{3}", s["id"] or ""):
        grep_bad += 1
check("§7-4 口径：每处标记都能被 'PATCHED-AuraDSP P-' 捞到", grep_bad == 0,
      f"捞不到 {grep_bad} 处")

# 日期一律后置（否则 `grep 'PATCHED-AuraDSP P-'` 会漏）
date_first = 0
for p in P.iter_code(ROOT):
    if re.search(r"\[PATCHED-AuraDSP \d{4}-\d{2}-\d{2}\s+P-\d{3}\]", read(p)):
        date_first += 1
check("无『日期在编号前』的旧写法", date_first == 0, f"{date_first} 个文件仍有")

# ---------------------------------------------------------------- [D] 反向判红
print("\n== [D] 反向判红 ==")

_, _, v1 = P.evaluate(" B1-c", REG)
check("去掉编号 → G1 判红", any(x.startswith("G1") for x in v1), str(v1))

_, _, v2 = P.evaluate(" P-099 B1-c", REG)
check("换成未登记编号 → G2 判红", any(x.startswith("G2") for x in v2), str(v2))

# 别名冲突：同一别名映射到两个编号（scan 级别的交叉检查）
alias_map, conflicts = {}, []
for tail, expect_id in [(" P-018 B1-c", "P-018"), (" P-020 B1-c", "P-020")]:
    num, alias, _ = P.evaluate(tail, REG)
    prev = alias_map.get(alias)
    if prev and prev != num:
        conflicts.append((alias, prev, num))
    alias_map[alias] = num
check("同一别名两个编号 → G3 判红", len(conflicts) == 1,
      f"conflicts={conflicts}")

# 真实文件反向验证：把一处已修的标记改回裸代号，evaluate 必须判红
CTRL = os.path.join(ROOT, "engine", "legacy", "jdsp", "jdspController.c")
ctrl = read(CTRL)
m = re.search(r"\[PATCHED-AuraDSP (P-\d{3}) (B5)\]", ctrl)
check("反向验证锚点存在（B5 标记）", m is not None)
if m:
    broken = ctrl.replace(m.group(0), "[PATCHED-AuraDSP B5]", 1)
    tail = re.search(r"\[PATCHED-AuraDSP([^\]]*)\]", broken[broken.index("[PATCHED-AuraDSP B5]"):]).group(1)
    _, _, v3 = P.evaluate(tail, registry)
    check("真实源码退回裸代号后判红", any(x.startswith("G1") for x in v3), str(v3))

# ---------------------------------------------------------------- [E] 登记表结构
print("\n== [E] 登记表结构 ==")

text = read(PATCHES)
heads = re.findall(r"^##\s+(P-\d{3})\b", text, re.M)
check("登记表无重复编号", len(heads) == len(set(heads)),
      f"{len(heads)} 条 / 去重 {len(set(heads))}")
nums = sorted(int(h[2:]) for h in heads)
check("编号连续无缺（P-001..P-025）",
      nums == list(range(1, len(nums) + 1)),
      f"实际 {nums[:3]}..{nums[-3:]}" if nums else "空")

# 新条目必须有「位置」与「上游同步冲突风险」——这是 vendor 补丁登记的两项硬要求
# （在哪、上游合并有多疼）。**不要求统一字段集**：25 个历史条目的字段名本就各异
# （P-006 用「症状/根因/改动」、P-010 用「功能/RT 安全/验收」），强行归一化是比
# 编号治理更大的破坏，也超出 D6 的范围。
blocks = re.split(r"^##\s+", text, flags=re.M)
new_blocks = [b for b in blocks if re.match(r"P-0(1[6-9]|2[0-6])\b", b)]
check("P-016..P-026 共 11 节齐全", len(new_blocks) == 11, f"实际 {len(new_blocks)}")

missing = []
for b in new_blocks:
    head = b.split("\n", 1)[0][:14]
    for field in ("**位置**", "**上游同步冲突风险**"):
        if field not in b:
            missing.append("%s 缺 %s" % (head, field))
check("10 个条目都有「位置」与「上游同步冲突风险」", not missing, "; ".join(missing[:4]))

# 本次新撰写的 6 节（P-019 及 P-021..P-025）另需「动机」与「内容」，否则登记等于
# 只说了"改了哪里"，没说明"为什么改、改了什么"。
authored = [b for b in blocks if re.match(r"P-0(19|2[1-5])\b", b)]
check("本次新撰写 6 节齐全", len(authored) == 6, f"实际 {len(authored)}")
missing2 = []
for b in authored:
    head = b.split("\n", 1)[0][:14]
    for field in ("**动机**", "**内容**"):
        if field not in b:
            missing2.append("%s 缺 %s" % (head, field))
check("新撰写 6 节都有「动机」与「内容」", not missing2, "; ".join(missing2[:4]))

check("文件头声明编号唯一性规则",
      "编号是唯一真相源" in text and "永不复用" in text)
check("文件头说明别名降级", "降级为别名" in text)

print()
if fails:
    print(f"D6 FAILURES ({len(fails)}): {fails}")
    sys.exit(1)
print(f"D6 ALL PASSED ({passes} checks)")
