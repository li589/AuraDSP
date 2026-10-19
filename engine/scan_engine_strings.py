#!/usr/bin/env python3
"""AuraDSP 引擎内置字符串 + 预设性质数值 扫描器。
输出：扫描统计 + 结构化数据，供汇报文档使用。"""
import os, re, json, sys

ENGINE = r"D:/temp_desktop/Proj/JamesDSP/engine"

# ---------------------------------------------------------------------------
# 1. 解析参数表 kEngineParamTable（id / type / member / min / max）
# ---------------------------------------------------------------------------
def parse_param_table(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    # 截到表结束（}; 之后是 find_param_desc）
    m = re.search(r"static const EngineParamDesc kEngineParamTable\[\] = \{(.*?)\n\};", txt, re.S)
    body = m.group(1) if m else ""
    rows = []
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("PARAM_"):
            continue
        mm = re.match(r"(PARAM_\w+)\(\s*\"([^\"]+)\"", line)
        if not mm:
            continue
        macro, idv = mm.group(1), mm.group(2)
        nums = re.findall(r"(-?\d+\.?\d*[f]?)", line)
        if macro in ("PARAM_FLOAT", "PARAM_INT"):
            # id, member, min, max, hook
            minv, maxv = nums[0], nums[1]
        elif macro == "PARAM_BOOL":
            minv, maxv = "0", "1"
        else:  # CUSTOM 系列：无范围
            minv, maxv = "0", "0"
        rows.append({"id": idv, "macro": macro, "min": minv, "max": maxv})
    return rows

# ---------------------------------------------------------------------------
# 2. 解析 Params 结构体默认值 + 行内范围注释
# ---------------------------------------------------------------------------
def parse_params_struct(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"struct Params \{(.*?)\n\};", txt, re.S)
    body = m.group(1) if m else ""
    defaults = {}
    for line in body.splitlines():
        # std::atomic<float>    bass_gain{0.0f};      /* dB [0,15] */
        mm = re.search(r"std::atomic<(\w+)>\s+(\w+)\{([^}]*)\}", line)
        if not mm:
            continue
        typ, member, val = mm.group(1), mm.group(2), mm.group(3).strip()
        rng = ""
        cm = re.search(r"\[([^\]]+)\]", line)
        if cm:
            rng = cm.group(1)
        # 处理数组 lp_param[8]（无默认值，跳过）
        if "[" in member:
            continue
        defaults[member] = {"type": typ, "default": val, "range": rng}
    return defaults

# ---------------------------------------------------------------------------
# 3. 混响预设矩阵
# ---------------------------------------------------------------------------
def parse_reverb(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"ps\[\] =\s*\{(.*?)\n\s*\};", txt, re.S)
    if not m:
        return []
    block = m.group(1)
    rows = []
    for line in block.splitlines():
        nums = re.findall(r"-?\d+\.?\d*f?", line)
        if len(nums) >= 17:
            rows.append([n.replace("f","") for n in nums[:17]])
    return rows

# ---------------------------------------------------------------------------
# 4. kLat 延迟常数
# ---------------------------------------------------------------------------
def parse_klat(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    out = []
    for line in txt.splitlines():
        m = re.search(r"(kLat\w+)\s*\{\s*(\d+),\s*([\d.]+)f?\s*\}", line)
        if m:
            out.append((m.group(1), m.group(2), m.group(3)))
    return out

# ---------------------------------------------------------------------------
# 5. 全部字符串字面量 + 分类
# ---------------------------------------------------------------------------
STRING_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
ERROR_RE = re.compile(r'(set_error|return AURADSP_E_\w+|error:|Error|invalid|must|failed|too |closed|null|not found|out of|overflow)', re.I)

def scan_strings():
    buckets = {}      # 顶层目录 -> 计数
    by_ext = {}
    error_strings = []  # (file, text)
    version_strings = []
    all_count = 0
    for root, _, files in os.walk(ENGINE):
        for f in files:
            if f.endswith((".c",".cpp",".h",".hpp",".cc")):
                fp = os.path.join(root, f)
                top = os.path.relpath(root, ENGINE).split(os.sep)[0] or "."
                try:
                    data = open(fp, encoding="utf-8", errors="replace").read()
                except:
                    continue
                strs = STRING_RE.findall(data)
                n = len(strs)
                all_count += n
                buckets[top] = buckets.get(top, 0) + n
                for s in strs:
                    low = s.lower()
                    if ERROR_RE.search(s) and len(s) < 160:
                        error_strings.append((fp, s))
                    if re.search(r'\bv?\d+\.\d+\.\d+\b', s) or 'version' in low or 'build' in low:
                        if len(version_strings) < 40:
                            version_strings.append((fp, s))
    return buckets, error_strings, version_strings, all_count

# ---------------------------------------------------------------------------
if __name__ == "__main__":
    table = parse_param_table(os.path.join(ENGINE, "engine_param_table.h"))
    defaults = parse_params_struct(os.path.join(ENGINE, "engine_internal.h"))
    reverb = parse_reverb(os.path.join(ENGINE, "legacy/jdsp/Effects/reverb.c"))
    klat = parse_klat(os.path.join(ENGINE, "engine_internal.h"))
    buckets, errors, versions, total = scan_strings()

    # 统计：id 重复 member 映射（channels vs channel_mask）
    member_to_ids = {}
    for r in table:
        member_to_ids.setdefault(r["macro"] and r["id"], r)
    id_to_member = {}
    dup_ids = {}
    for r in table:
        pass
    # 真正重复：相同 member 被多个 id 引用
    mem_map = {}
    for r in table:
        mem = re.search(r'"[^"]+",\s*(\w+)', "")  # placeholder
    # 从原行无法得 member 这里直接重解析：
    txt = open(os.path.join(ENGINE,"engine_param_table.h"), encoding="utf-8", errors="replace").read()
    mblock = re.search(r"kEngineParamTable\[\] = \{(.*?)\n\};", txt, re.S).group(1)
    mem_seen = {}
    for line in mblock.splitlines():
        mm = re.match(r"\s*(PARAM_\w+)\(\s*\"([^\"]+)\"\s*,\s*(\w+)", line)
        if mm:
            macro, idv, member = mm.group(1), mm.group(2), mm.group(3)
            mem_seen.setdefault(member, []).append(idv)

    dup_members = {k:v for k,v in mem_seen.items() if len(v) > 1}

    print("===== 参数表 =====")
    print(f"参数表条目总数: {len(table)}")
    from collections import Counter
    macro_cnt = Counter(r["macro"] for r in table)
    print("按宏类型:", dict(macro_cnt))
    print("\n===== 重复 member（多个 id 映射到同一底层字段） =====")
    for k,v in dup_members.items():
        print(f"  {k}: {v}")

    print("\n===== Params 默认值 =====")
    print(f"成员默认值条目: {len(defaults)}")

    print("\n===== 混响预设 =====")
    print(f"预设套数: {len(reverb)}  每套维度: {len(reverb[0]) if reverb else 0}")

    print("\n===== kLat 延迟常数 =====")
    for k in klat:
        print(f"  {k[0]}: stages={k[1]} ms={k[2]}")

    print("\n===== 字符串字面量分布 =====")
    print(f"总字面量: {total}")
    for k,v in sorted(buckets.items(), key=lambda x:-x[1]):
        print(f"  {k}: {v}")
    print(f"\n疑似错误/状态字符串: {len(errors)}")
    for fp,s in errors[:60]:
        print(f"  [{os.path.relpath(fp, ENGINE)}] {s}")

    print("\n===== 版本/构建相关字符串（样本） =====")
    for fp,s in versions[:20]:
        print(f"  [{os.path.relpath(fp, ENGINE)}] {s}")

    # 写出 JSON 供后续
    out = {"table": table, "defaults": defaults, "reverb": reverb,
           "klat": klat, "buckets": buckets, "total": total,
           "dup_members": dup_members, "errors": errors, "versions": versions}
    json.dump(out, open(os.path.join(ENGINE, "_scan_cache.json"), "w"), ensure_ascii=False, indent=1)
    print("\n[cache] 已写入 _scan_cache.json")
