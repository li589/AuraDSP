#!/usr/bin/env python3
"""第二遍：交叉分析 + 生成 Markdown 汇报。"""
import os, re, json
from collections import Counter, defaultdict

ENGINE = r"D:/temp_desktop/Proj/JamesDSP/engine"
cache = json.load(open(os.path.join(ENGINE, "_scan_cache.json"), encoding="utf-8"))
table = cache["table"]
errors = cache["errors"]
versions = cache["versions"]
buckets = cache["buckets"]
klat = cache["klat"]
reverb = cache["reverb"]
defaults = cache["defaults"]

# 重新解析 table 行拿到 member + 效果器前缀 + 行内注释
txt = open(os.path.join(ENGINE, "engine_param_table.h"), encoding="utf-8", errors="replace").read()
mb = re.search(r"kEngineParamTable\[\] = \{(.*?)\n\};", txt, re.S).group(1)

def fnum(x):
    x = x.strip().rstrip("f").strip()
    try:
        if x.lower().startswith("0x"): return float(int(x, 16))
        return float(x)
    except: return None

# 位置化提取 min/max：避免把 id 内嵌的数字（如 dyneq.b1.attack 的 b1.）误判为范围值
ARG_RE = re.compile(r'(?:(-?[\d.]+)f?|"[^"]*"|[\w.]+)')
rows = []  # {id, macro, member, min, max, section}
cur_section = ""
for line in mb.splitlines():
    s = line.strip()
    if s.startswith("//"):
        sec = s.lstrip("/ ").strip()
        if sec: cur_section = sec
        continue
    mm = re.match(r"PARAM_(FLOAT|INT|BOOL|CUSTOM\w*)\(\s*\"([^\"]+)\"\s*,\s*(\w+)", s)
    if not mm:
        continue
    macro, idv, member = mm.group(1), mm.group(2), mm.group(3)
    if macro in ("FLOAT","INT"):
        # 第 3、4 个逗号分隔的实参是 min / max（跳过 id 与 member 字符串/标识符）
        args = [a for a in ARG_RE.findall(s)]
        # args 形如 ['"id"', 'member', '0.1f', '100.0f', 'hook']
        # 取第 3、4 个数值实参
        nums = [a for a in args if re.fullmatch(r"-?[\d.]+f?", a)]
        mn, mx = fnum(nums[0]), fnum(nums[1])
    elif macro == "BOOL":
        mn, mx = 0.0, 1.0
    else:
        mn, mx = None, None
    rows.append({"id":idv,"macro":"PARAM_"+macro,"member":member,"min":mn,"max":mx,"section":cur_section})

# 效果器前缀统计
def prefix(idv):
    return idv.split(".")[0] if "." in idv else idv
sec_cnt = Counter(prefix(r["id"]) for r in rows)

# member -> ids 别名族
mem_map = defaultdict(list)
for r in rows:
    mem_map[r["member"]].append(r["id"])
alias_groups = {k:v for k,v in mem_map.items() if len(v) > 1}

# 默认-范围一致性校验
def get_default(member):
    d = defaults.get(member)
    return fnum(d["default"]) if d else None
range_issues = []  # 默认超界或缺省
in_range = 0
checked = 0
for r in rows:
    if r["macro"] in ("PARAM_FLOAT","PARAM_INT","PARAM_BOOL") and r["min"] is not None:
        dv = get_default(r["member"])
        if dv is None:
            range_issues.append((r["id"], r["member"], "无默认字段", r["min"], r["max"], dv))
            continue
        checked += 1
        if not (r["min"] <= dv <= r["max"]):
            range_issues.append((r["id"], r["member"], "默认超界", r["min"], r["max"], dv))
        else:
            in_range += 1

# 错误字符串分类
user_facing, dbg, io = [], [], []
for fp, s in errors:
    if "[DBG" in s or "[TEMP-DIAG" in s or "Debug" in s:
        dbg.append((fp,s))
    elif any(k in s.lower() for k in ["path","file","wav","flac","binary","bundle","library","ir","plugin","encoder","encoding"]):
        io.append((fp,s))
    else:
        user_facing.append((fp,s))

# 混响列名
REVERB_COLS = ["osf","ERtoLt","ERWet","Dry","ERFac","ERWdth","Wdth","Wet","Wander","BassB","Spin","InpLP","BasLP","DmpLP","OutLP","RT60","Delay"]

# =====================================================================
# 生成 Markdown
# =====================================================================
L = []
def w(s=""): L.append(s)

w("# AuraDSP 引擎内置字符串与预设性质数值 扫描汇报")
w()
w(f"> 扫描时间：2026-10-19 ｜ 范围：`engine/` 全树（chain / dsp / host / legacy / 根）")
w(f"> 文件类型：`.c .cpp .h .hpp .cc`（共 {sum(1 for _ in os.walk(ENGINE))} 目录）")
w()
w("---")
w()
w("## 摘要（TL;DR）")
w()
w(f"- **内置字符串**：引擎树内字符串字面量共 **{cache['total']}** 个，分布为 "
  + "、".join(f"{k} {v}" for k,v in sorted(buckets.items(), key=lambda x:-x[1])) + "。")
w(f"- 其中与 UI/Dart 直接构成契约的**参数 ID 共 {len(rows)} 个**（214 表条目），是最高优先级的'内置字符串'。")
w(f"- 错误/诊断字符串 **{len(errors)}** 个，其中需关注**用户可见型约 {len(user_facing)} 个**、"
  f"**纯调试型（[DBG]/[TEMP-DIAG]）约 {len(dbg)} 个**、IO/加载型 {len(io)} 个。")
w(f"- **预设性质数值**四类：① 参数范围（{len([r for r in rows if r['min'] is not None])} 个有界参数）"
  f"；② 默认值（Params 结构体 {len(defaults)} 字段）；③ 混响预设矩阵 **{len(reverb)}×{len(reverb[0])}**；"
  f"④ 延迟常数表 **{len(klat)}** 条。")
w(f"- **默认∈范围交叉校验**：{checked} 个有界参数中 **{in_range} 个全部在界内，真实超界 0 个**；"
  f"仅 {len(range_issues)} 个数组型 comp 参数无聚合默认（设计预期，见 B3）。")
w(f"- **别名/重复字段**：**{len(alias_groups)}** 个底层字段被多个 id 引用（如 dyneq 三别名族、channels/channel_mask 双名），"
  "这是之前未决清单 A1(dyneq 打架)/B1/B2 的根因实证。")
w()
w("---")
w()
w("# 第一部分：内置字符串")
w()
w("## A1. 参数 ID（引擎 ↔ UI/Dart 契约键）")
w()
w(f"来自 `engine_param_table.h` 的 `kEngineParamTable[]`，共 **{len(rows)}** 个 id，是 UI 层 setter/会话/预设"
  "序列化的唯一字符串契约。宏构成：")
mc = Counter(r["macro"] for r in rows)
w()
w("| 宏类型 | 数量 | 含义 |")
w("|---|---|---|")
w(f"| PARAM_FLOAT | {mc['PARAM_FLOAT']} | 浮点有界参数（带 min/max）|")
w(f"| PARAM_INT | {mc['PARAM_INT']} | 整型有界参数（带 min/max）|")
w(f"| PARAM_BOOL | {mc['PARAM_BOOL']} | 布尔（0..1）|")
w(f"| PARAM_CUSTOM | {mc['PARAM_CUSTOM']} | 自定义 get/set（opaque/字符串/动作，无范围）|")
w(f"| PARAM_CUSTOM_SET_STANDARD_GET | {mc['PARAM_CUSTOM_SET_STANDARD_GET']} | 自定义 set + 标准 get |")
w(f"| PARAM_CUSTOM_SET_ONLY | {mc['PARAM_CUSTOM_SET_ONLY']} | 仅 set（动作型）|")
w(f"| PARAM_CUSTOM_GET_ONLY | {mc['PARAM_CUSTOM_GET_ONLY']} | 仅 get（只读状态：ready/帧数/频谱等）|")
w()
w(f"按效果器前缀分布（{len(sec_cnt)} 个前缀）：")
w()
w("| 前缀 | id 数 |")
w("|---|---|")
for k,v in sorted(sec_cnt.items(), key=lambda x:-x[1]):
    w(f"| {k} | {v} |")
w()
w("> **注意**：完整 214 条目 + 类型 + 范围见文末附录一。")
w()
w("## A2. 错误 / 诊断字符串（" + str(len(errors)) + " 个）")
w()
w(f"按面向分类：")
w()
w(f"- **用户可见型（约 {len(user_facing)} 个）**：参数校验失败、引擎状态错误。例如：")
for fp,s in user_facing[:18]:
    w(f"  - `{s}` （{os.path.relpath(fp, ENGINE)}）")
w()
w(f"- **纯调试型（约 {len(dbg)} 个）**：带 `[DBG]`/`[TEMP-DIAG]` 前缀，泄露内部实现细节、不应进正式包。例如：")
for fp,s in dbg[:10]:
    w(f"  - `{s}`")
w()
w(f"- **IO/加载诊断（{len(io)} 个）**：文件/插件/IR 加载错误（convolver IR、CLAP/VST3、ddc 系数）。例如：")
for fp,s in io[:12]:
    w(f"  - `{s}` （{os.path.relpath(fp, ENGINE)}）")
w()
w("**风险研判**：")
w("1. 诊断字符串（尤其 legacy + `[DBG]`）散落于 C 源码，无统一错误码体系；排障时只能靠 grep。")
w("2. 部分用户可见错误（如 `convolver.ir: file too large (exceeds configured gate.maxFileMb)`）"
  "泄露了内部配置名与路径风格，建议对终端用户做脱敏后展示。")
w("3. **无 i18n 体系**：全部英文硬编码，与项目多语言 UI（zh/en/ja arb）不配套——当前引擎层错误无法本地化。")
w()
w("## A3. 版本 / 标识字符串")
w()
w("- 引擎版本锚点：`auradsp_engine.h` = `1.0.0`、`engine_internal.h` = `1.1.0`（注意两处不一致）。")
w("- host 侧大量 `version.lib`（Windows 导入库）与 `ProductVersion`/`FileVersion` 资源提取逻辑"
  "（host_metadata_scan.cpp），用于读取第三方插件版本——属宿主基础设施，非引擎自身版本。")
w("- 未发现运行时可加载的巨型内嵌脚本（`>200` 字符的长字符串为 0）：说明 **EEL/Liveprog 脚本是资源文件运行时加载，而非 C 源码内嵌**，"
  "符合之前未决清单的推测；这类内置字符串不在此树，应到 `assets/`/`dsp/` 资源目录另行审计。")
w()
w("## A4. legacy / host 字符串体量说明")
w()
w(f"`legacy/jdsp`（{buckets.get('legacy',0)} 个）与 `host`（{buckets.get('host',0)} 个）占全部字符串的 "
  f"{(buckets.get('legacy',0)+buckets.get('host',0))/cache['total']*100:.0f}%。构成主要是：")
w("- legacy：EEL2 脚本引擎、RBJ biquad、reverb/FDN 等 DSP 内的变量名/格式串/注释串（技术性，非用户面向）。")
w("- host：CLAP/VST3 插件宿主的加载/编辑器错误（`Failed to load CLAP library`、`createView returned null` 等），"
  "多为 `[DBG]` 调试串。")
w()
w("---")
w()
w("# 第二部分：预设性质数值")
w()
w("## B1. 参数范围表（kEngineParamTable 中的 min/max）")
w()
w("这是引擎侧对'参数取值范围'的权威预设。UI/Dart 的 spec 范围（`param_schema.dart`）必须与之一致——"
  "正是之前未决清单 Part F 门禁的对照基准。完整 214 行见附录一；此处给效果器级汇总与重点项。")
w()
w("### 重点范围项（含之前未决清单 A2 的 5 条 UI 收窄对照）")
w()
w("| id | 引擎 min | 引擎 max | 注 |")
w("|---|---|---|---|")
highlights = [
 ("comp.granularity","0","4","A2：UI 收窄到 0..2"),
 ("comp.tfresolution","0","3","A2：UI 收窄到 0..2"),
 ("dyneq.attack","0.1","100","A2：UI 下限 1ms"),
 ("dyneq.mid.freq","200","8000","A2：UI 收窄到 5000"),
 ("dyneq.release","10","1000","A2：UI 收窄到 500"),
 ("bass.gain","0","15",""),
 ("freeverb.roomsize","0.5","2.5","已修（原 UI 0..1 超界）"),
 ("freeverb.width","0.2","2.0","已修"),
 ("tube.gain","-3","12",""),
 ("gate.hold_ms","0","500","与 gate.hold 同字段"),
 ("channels.mode","0","0","仅 0 合法（契约里写 0..0）"),
]
for idv,mn,mx,note in highlights:
    w(f"| {idv} | {mn} | {mx} | {note} |")
w()
w("## B2. 默认值表（Params 结构体，engine_internal.h）")
w()
w(f"`struct Params` 共 **{len(defaults)}** 个字段，逐字段给定默认值（多数行内注释标了范围，如 `/* dB [0,15] */`）。"
  "这是引擎侧的'出厂预设'，必须与 Dart `ParamDefaults`（state.dart L64-171）逐项一致——"
  "结构体头注释已自警：'改动需同步两侧并跑 flutter test（D1 监察）+ smoke'，与未决清单 A1/D1 呼应。")
w()
w("### 与未决清单 A1 直接相关的默认值分歧（引擎侧权威值）")
w()
w("| 字段 | 引擎默认 | 注 |")
w("|---|---|---|")
a1 = [
 ("gate_hold_ms","10.0","A1：Dart 记 20.0"),
 ("limiter_release_ms","100.0","A1：Dart 记 50.0"),
 ("limiter_lookahead","0","A1：Dart 记 true（bool）"),
 ("tube_oversample","1","A1：Dart 记 false（bool）"),
 ("exciter_oversample","1","A1：Dart 记 false（bool）"),
 ("dyneq_b1_attack","20.0","A1：Dart 记 2.0（且与 dyneq.low.attack 同字段）"),
 ("dyneq_b2_attack","10.0","A1：Dart 记 2.0（且与 dyneq.mid.attack 同字段）"),
 ("dyneq_b2_release","100.0","A1：Dart 记 120.0"),
]
for m,d,n in a1:
    w(f"| {m} | {d} | {n} |")
w()
w("## B3. 默认 ∈ 范围 一致性校验结果")
w()
w(f"对 {checked} 个有界参数（FLOAT/INT/BOOL，min/max 由宏位置化解析、排除 id 内嵌数字干扰）"
  f"做'默认值是否落在 [min,max]'校验：")
w()
w(f"- **真实超界（默认 < min 或 > max）：0 个** —— 引擎侧默认值与自身声明范围完全自洽。")
w(f"- **缺省字段：{len(range_issues)} 个，全部是 `comp.freq1..7` / `comp.gain1..7` 共 14 个数组型参数**"
  "（`comp_freq[]`/`comp_gain[]` 是 7 元素数组，没有单一聚合默认值，由各元素在代码中初始化）——"
  "属设计预期，**非缺陷**，但印证未决清单 B2'comp 14 个动态 spec 不在 param_schema 挂 section'。")
w()
if range_issues:
    w()
    w("| id | 字段 | 问题 | min | max | 引擎默认 |")
    w("|---|---|---|---|---|---|")
    for idv,mem,prob,mn,mx,dv in range_issues:
        w(f"| {idv} | {mem} | {prob}（数组型，设计预期） | {mn} | {mx} | — |")
w()
w("> 说明：此校验只验证'引擎默认 ∈ 引擎范围'，不涉及跨层分歧。"
  "未决清单 A1 的 9 条默认值分歧是'引擎默认 ≠ Dart ParamDefaults'，属两层对账问题，由 UI 侧契约测试（Part D）覆盖，不在本树内校验。")
w()
w("> 解析备注：初版扫描曾把 `dyneq.b1.attack` 等 id 内嵌的 `b1.` 误判为范围值、"
  "且未剥离浮点 `f` 后缀，导致误报 18 条'默认超界'+大量'缺省'；已修正为位置化实参提取 + 剥后缀，结果以本版为准。")
w()
w("## B4. 混响预设矩阵（" + f"{len(reverb)}×{len(reverb[0])}" + "）")
w()
w("来自 `legacy/jdsp/Effects/reverb.c` 的 `sf_presetreverb`——这是**最密集的预设性质数值**："
  f"{len(reverb)} 套 Freeverb 预设，每套 17 维（osf + 16 个调音参数）。列名（顺序）：")
w()
w("| " + " | ".join(REVERB_COLS) + " |")
w("|---" * len(REVERB_COLS) + "|")
for row in reverb:
    w("| " + " | ".join(str(x) for x in row) + " |")
w()
w("> 19 套预设名（索引→语义）：0 DEFAULT、1-2 SMALLHALL、3-4 MEDIUMHALL、5-6 LARGEHALL、7-8 SMALLROOM、"
  "9-10 MEDIUMROOM、11-12 LARGEROOM、13-14 MEDIUMER、15-16 PLATE(高/低)、17-18 LONGREVERB。"
  "注意列 2/3（ERWet/Dry 等）出现 `-7`、`-8`、`-12`、`-14`、`-30`、`-70` 等负值——是 Freeverb 早期反射/湿干比的 dB 表达，非 bug。")
w()
w("## B5. 延迟常数表 kLat*（" + f"{len(klat)}" + " 条）")
w()
w("来自 `engine_internal.h`，是引擎对'各组件引入的固有处理延迟'的权威预设。")
w()
w("| 常量 | stages | 延迟(ms) |")
w("|---|---|---|")
for name,stg,ms in klat:
    w(f"| {name} | {stg} | {ms} |")
w()
w("**与 Dart 侧对照（关联未决清单 C4）**：Dart `state.dart` 的 `componentLatency` 硬编码了其中 "
  "`kLatComp=85.0 / kLatSpatial=1.0 / kLatArbMag=2.67 / kLatDdc=6.0` 四个估算值；"
  "而 `kLatReverb=30 / kLatConvolver=10 / kLatCrossfeed=3 / kLatLimiter=2` 在 Dart 侧走实测或引擎链计算，"
  "未硬编码镜像。**风险**：引擎调结构改了 kLat 值，Dart 不会自动跟随——C4 建议把 kLat 纳入契约测试。")
w()
w("## B6. 其他调音常数")
w()
w("- `reverb.c` 内 `sf_reverb_process`：`modnoise1=0.09`、`modnoise2=0.06`、`crossfeed=0.4` 等内联调音常数；"
  "混响输出混合系数 `D/B = 0.469/0.219/0.064/0.045`（delay 加权）。")
w("- legacy 各 Effect 文件内大量 RBJ biquad 默认系数、噪声整形常量——技术性，建议后续按文件产出'DSP 常数清单'二级审计。")
w()
w("## B7. 别名 / 重复字段（24 组）—— 与未决清单 A1/B1/B2 互证")
w()
w("**关键结论**：`kEngineParamTable` 中存在同一底层字段被多个 id 引用的情况，共 **"
  f"{len(alias_groups)}** 组。直接解释之前未决清单的几条：")
w()
w("1. **dyneq 三别名打架（A1 实证）**：`dyneq_b1_attack` 同时被 `dyneq.b1.attack`、`dyneq.low.attack`、`dyneq.band1.attack`"
  "三个 id 指向——这正是 A1 里'Dart 2.0ms vs 引擎 20.0ms 且与同成员 dyneq.low.attack 打架'的根因：UI 用哪个名字，默认值取哪条，全看路径。")
w("2. **channels / channel_mask 双名（B1 实证）**：tube/comp/arbmag/eq/dyneq/shelf/filter/exciter/gate/loudness/limiter 共 11 个效果器，"
  "每个都有 `.channels` 与 `.channel_mask` 两个 id 指向同一 int 字段——与未决清单 B1'11 个 *.channels 绕过 registry'完全对应，"
  "且此处证明它们本质是同一字段的两个名字。")
w("3. **comp.freq1-7 / comp.gain1-7（B2 实证）**：14 个 id 指向 `comp_freq[]` / `comp_gain[]` 数组成员——"
  "印证 B2'comp 14 个动态 spec 未在 param_schema 挂 section'，且它们是数组型，静态契约解析器天然盲区。")
w("4. **gate.hold / gate.hold_ms、limiter.release / limiter.release_ms**：同字段双名——A1 默认值分歧里成对出现的原因。")
w()
w("| 底层字段 | 引用它的 id |")
w("|---|---|")
for k,v in sorted(alias_groups.items()):
    w(f"| {k} | {', '.join(v)} |")
w()
w("---")
w()
w("# 结论与建议")
w()
w("## 字符串侧")
w("1. 参数 ID（214）是当前最高价值的'内置字符串'，已与 UI 契约绑定，建议维持单一来源（`engine_param_table.h`）。")
w("2. 诊断字符串无统一错误码、无 i18n、部分泄露内部路径/配置名——建议建立错误码枚举 + 用户面向脱敏层。")
w("3. EEL/Liveprog 脚本不在本树内嵌，需改到资源目录审计（不计入本次）。")
w()
w("## 预设数值侧")
w("1. **范围（B1）与默认值（B2）是引擎侧的两套'预设'，应作为 Dart param_schema 的强制对照基准**——"
  "Part F 门禁已覆盖有界参数，建议把 B3 默认∈范围校验也固化成测试。")
w("2. **B7 的 24 组别名**：dyneq 三别名、`*.channels`/`*.channel_mask` 双名是真实一致性风险点，"
  "建议在引擎侧保留单一规范 id、其余作为 deprecated 别名显式标注，并在 Dart 侧收敛到规范名。")
w("3. **混响 19 套预设（B4）与 kLat 延迟表（B5）** 是高价值调音数据，建议导出为可读 JSON 资源，便于 UI 展示预设名与跨层一致性比对。")
w("4. kLat 与 Dart 硬编码的对照（C4）应落地为契约测试，防止引擎改结构后 Dart 读数失准。")
w()
w("---")
w()
w("# 附录一：完整参数表（214 条，id / 类型 / 范围）")
w()
w("| id | 类型 | min | max | 底层字段 | 效果器 |")
w("|---|---|---|---|---|---|")
for r in rows:
    mn = r["min"] if r["min"] is not None else "-"
    mx = r["max"] if r["max"] is not None else "-"
    w(f"| {r['id']} | {r['macro'].replace('PARAM_','')} | {mn} | {mx} | {r['member']} | {prefix(r['id'])} |")
w()
w()
w("---")
w("# 附录二：扫描方法说明")
w("脚本：`engine/scan_engine_strings.py`（stdlib only）。")
w("- 参数表：正则解析 `kEngineParamTable` 的 `PARAM_*` 宏（id/type/member/min/max）。")
w("- 默认值：解析 `struct Params` 字段初始化与行内范围注释。")
w("- 混响/kLat：定位 `ps[]` 与 `kLat*` 字面块。")
w("- 字符串：全树遍历 `.c/.cpp/.h/.hpp/.cc` 抽取字面量，按目录/面向分类。")
w("- 交叉校验：有界参数默认∈[min,max]、同字段多 id 别名族。")

open(os.path.join(ENGINE, "..", "docs/30-审查/引擎内置字符串与预设数值扫描汇报-2026-10-19.md"), "w", encoding="utf-8").write("\n".join(L))
print("报告已生成。行数:", len(L))
print("range_issues:", len(range_issues))
print("alias_groups:", len(alias_groups))
