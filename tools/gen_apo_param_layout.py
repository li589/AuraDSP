#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_apo_param_layout.py — System APO 共享参数块的索引布局生成器。

事实源：engine/engine_param_table.h（引擎权威参数表）。
APO 参数块（设计：docs/10-架构/SystemAPO引擎嵌入设计-2026-11-10.md
D4）以「序号槽」承载数值参数：块内第 i 个 u32 槽恒对应第 i 个参数
id，C 侧（AuraApo worker）与 Dart 侧（isolate publisher）必须共用
同一序号表——本脚本从引擎表机械生成两份产物，杜绝手写漂移：

  core/desktop/windows-drivers/03_system_apo/ApoParamIndex.h
    kApoNumParamIds[] / kApoNumParamTypes[]（0=float,1=int,2=bool）
  app/auradsp_app/lib/engine/apo_param_index.dart
    kApoNumParamIndex（id→序号）/ kApoNumParamTypes / 块布局常量

收录规则（与设计 D4 对齐）：
  - 静态数值项：表内 PARAM_FLOAT / PARAM_INT / PARAM_BOOL 宏条目
    （custom_set 为空、值走 Params 原子字段的标准路径），按表序；
  - 动态展开项（引擎以 strncmp 分支处理、不在静态表）：stereo.band1..5、
    input.balance.1..8、liveprog.param1..64、liveprogmc.param1..64，
    均为 float，追加在静态项之后（顺序与 gen_param_contract 的
    DYNAMIC_IDS 口径一致并扩到 64）；
  - 自定义 setter 数值项（全面复审 S3 / APO-1，块版本 2 起）：
    PARAM_CUSTOM_SET_STANDARD_GET（类型取声明 ParamType）与
    PARAM_CUSTOM 白名单（值类型经 setter 代码核对），**追加**在
    上述全部序号之后——存量序号永不移位；豁免清单 EXEMPT 与
    分类完备性断言见 parse_numeric_params。
字符串槽（定长，id 与容量在本脚本内登记，属布局契约的一部分）：
  eq.curve 4K / arbmag.string 4K / liveprog.code 16K / graph.order 1K。
  convolver.ir.path、ddc.load、liveprogmc.code 不入块（设计 §1 非目标）。

块布局（u32 对齐，两侧共用，改布局必须同步 ApoShared.h 并由
smoke_apo_param_layout 交叉断言）：
  header 64B（magic/version/writeSeq/bypass/numCount/strUsed[4]+预留）
  valid 区：64B 有效位图——bit i 对应数值槽 i，字符串槽 s 的位
    在数值槽总数之后；只有置位的槽会被 APO worker 应用（未置
    位 = 该参数从未被 App 写过，引擎保持其默认值，严禁以块内
    零值覆盖——首帧全量应用若不设此门会把未触碰参数清零）
  values 区：数值槽总数 * 4B（v1=325 槽，v2=339 槽）
  strings 区：各槽按上表顺序紧密排列
  映射大小：32768B（向上取整）。

用法：python3 tools/gen_apo_param_layout.py [--check]
  --check 只比对不写文件，不一致退出码 1（供 smoke 门调用）。
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARAM_TABLE = os.path.join(ROOT, 'engine', 'engine_param_table.h')
OUT_C = os.path.join(ROOT, 'core', 'desktop', 'windows-drivers',
                     '03_system_apo', 'ApoParamIndex.h')
OUT_DART = os.path.join(ROOT, 'app', 'auradsp_app', 'lib', 'engine',
                        'apo_param_index.dart')

TYPE_CODE = {'FLOAT': 0, 'INT': 1, 'BOOL': 2}

DYNAMIC_FLOAT_IDS = (
    [f'stereo.band{i}' for i in range(1, 6)]
    + [f'input.balance.{i}' for i in range(1, 9)]
    + [f'liveprog.param{i}' for i in range(1, 65)]
    + [f'liveprogmc.param{i}' for i in range(1, 65)]
)

# (id, cap bytes) —— 顺序即块内排列顺序，属布局契约。
STRING_SLOTS = (
    ('eq.curve', 4096),
    ('arbmag.string', 4096),
    ('liveprog.code', 16384),
    ('graph.order', 1024),
)

HEADER_BYTES = 64
MASK_BYTES = 64
MAPPING_BYTES = 32768


def sha16(path):
    # 摘要必须与检出行尾无关（第六轮 CI 实证）：Windows 检出
    # （autocrlf）把 LF 变 CRLF 时原始字节摘要随之而变，生成
    # 物在 Win 生成、CI（LF）核验必漂移。先归一化 CRLF→LF
    # 再摘要，任何检出口径下摘要恒定。
    data = open(path, 'rb').read().replace(b'\r\n', b'\n')
    return hashlib.sha256(data).hexdigest()[:16]


# 全面复审 S3（APO-1）：此前生成器只收 PARAM_FLOAT/INT/BOOL，
# 自定义 setter 家族（PARAM_CUSTOM_SET_STANDARD_GET 等）的数值参数
# 全部不在块内——APO 模式下改这些参数只动影子引擎（如 comp.mode、
# channels.mode、reverb.preset、bassmono.*、convolver.mix 等 14 项）。
# 收录规则：标准宏 ∪ CSSG（类型取声明 ParamType）∪ PARAM_CUSTOM
# 白名单（值类型经引擎 setter 代码核对）；新收录 id 一律**追加**在
# 既有布局之后（存量序号 0..324 永不移位），块版本升至 2——消费端
# 版本全等校验使旧 DLL 对新块整体拒绝（安全降级，绝不误用错位）。
PARAMS_VERSION = 2

CSSG_TYPE = {'kFloat': 0, 'kInt32': 1, 'kBool': 2}

# PARAM_CUSTOM 全自定义行中值类型已核对、可入数值块的白名单。
CUSTOM_NUMERIC = {
    'bass.intensity': 0,     # set_bass_intensity: float
    'gate.maxIrSeconds': 0,  # set_gate_float_param: float
    'gate.maxFileMb': 0,     # set_gate_float_param: float
    'viz.fftSize': 1,        # set_viz_fft_size: int32
}

# 明确豁免（不入块）及理由——分类完备性断言要求表中每个 id 必须
# 恰好落入「入块 / 豁免 / 只读 / 字符串槽」之一，新增参数不分类即
# 生成失败，杜绝下一批静默缺席。
EXEMPT = {
    'convolver.enable': '模式策略：文件型效果开关，由 ModeCaps.fileEffects 门控',
    'ddc.enable': '模式策略：同 convolver.enable',
    'reverb.engine': '只读派生（getter 由 reverb.preset 计算，setter 占位）',
    'mode.latency': 'ADR-006 墓碑：setter 恒返回 E_PARAM',
    'channels.count': '几何由音频流格式唯一决定，APO 消费端显式跳过',
    'liveprogmc.code': '字符串通道；多声道脚本由 ModeCaps.mcScript 门控，不入块',
    'convolver.ir.path': '文件路径字符串通道，不入数值块',
    'ddc.load': '文件路径字符串通道（载入命令型），不入数值块',
    'convolver.clear': '命令型 set-only，无值语义',
    'liveprog.unload': '命令型 set-only，无值语义',
    'liveprogmc.unload': '命令型 set-only，无值语义',
}


def parse_numeric_params():
    src = open(PARAM_TABLE, encoding='utf-8').read()
    i = src.find('kEngineParamTable[]')
    assert i > 0, 'kEngineParamTable not found'
    body = src[i:]
    out = [(m.group(2), TYPE_CODE[m.group(1)])
           for m in re.finditer(r'PARAM_(FLOAT|INT|BOOL)\(\s*"([^"]+)"', body)]
    ids = [x[0] for x in out]
    assert len(ids) == len(set(ids)), 'duplicate numeric param id'
    for dyn in DYNAMIC_FLOAT_IDS:
        assert dyn not in ids, f'dynamic id collides with static: {dyn}'
        out.append((dyn, 0))
    # —— S3 追加段（存量序号之后，按表中出现顺序）——
    have = set(ids) | set(DYNAMIC_FLOAT_IDS)
    extra = []
    for m in re.finditer(
            'PARAM_CUSTOM_SET_STANDARD_GET\\(\\s*"([^"]+)",\\s*\\w+,\\s*'
            'ParamType::(kFloat|kInt32|kBool)|PARAM_CUSTOM\\(\\s*"([^"]+)"',
            body):
        pid = m.group(1) or m.group(3)
        if pid in EXEMPT or pid in have:
            continue
        if m.group(2):
            extra.append((pid, CSSG_TYPE[m.group(2)]))
        elif pid in CUSTOM_NUMERIC:
            extra.append((pid, CUSTOM_NUMERIC[pid]))
        have.add(pid)
    out.extend(extra)
    # —— 分类完备性断言 ——
    all_ids = {m.group(1) for m in
               re.finditer(r'PARAM_\w+\(\s*"([^"]+)"', body)}
    get_only = {m.group(1) for m in re.finditer(
        r'PARAM_CUSTOM_GET_ONLY\(\s*"([^"]+)"', body)}
    str_ids = {sid for sid, _ in STRING_SLOTS}
    covered = {pid for pid, _ in out} | set(EXEMPT) | get_only | str_ids
    unclassified = all_ids - covered
    assert not unclassified, \
        f'未分类参数 id（须入块或登记 EXEMPT）: {sorted(unclassified)}'
    stale = set(EXEMPT) - all_ids
    assert not stale, f'EXEMPT 登记了表中不存在的 id: {sorted(stale)}'
    return out


def layout(params):
    values_off = HEADER_BYTES + MASK_BYTES
    strings_off = values_off + 4 * len(params)
    slot_offs = []
    p = strings_off
    for _sid, cap in STRING_SLOTS:
        slot_offs.append(p)
        p += cap
    total = p
    assert total <= MAPPING_BYTES, f'block {total} exceeds mapping {MAPPING_BYTES}'
    return values_off, strings_off, slot_offs, total


def gen_c(params, values_off, strings_off, slot_offs, total, digest):
    ids = ',\n    '.join(f'"{pid}"' for pid, _ in params)
    types = ', '.join(str(t) for _, t in params)
    str_ids = ',\n    '.join(f'"{sid}"' for sid, _ in STRING_SLOTS)
    str_caps = ', '.join(str(c) for _, c in STRING_SLOTS)
    str_offs = ', '.join(str(o) for o in slot_offs)
    return f"""// GENERATED by tools/gen_apo_param_layout.py — do not edit by hand.
// Source: engine/engine_param_table.h sha256[:16]={digest}
// Regenerate: python3 tools/gen_apo_param_layout.py
#pragma once

// APO 参数块序号表（设计 D4）：块内第 i 个 u32 数值槽恒对应
// kApoNumParamIds[i]；类型 0=float 1=int32 2=bool（值均占 4B）。
#define APO_NUM_PARAM_COUNT {len(params)}
static const char* const kApoNumParamIds[APO_NUM_PARAM_COUNT] = {{
    {ids}
}};
static const unsigned char kApoNumParamTypes[APO_NUM_PARAM_COUNT] = {{
    {types}
}};

// 字符串定长槽（顺序即块内排列）。
#define APO_STR_SLOT_COUNT {len(STRING_SLOTS)}
static const char* const kApoStrSlotIds[APO_STR_SLOT_COUNT] = {{
    {str_ids}
}};
static const unsigned int kApoStrSlotCaps[APO_STR_SLOT_COUNT] = {{ {str_caps} }};
static const unsigned int kApoStrSlotOffsets[APO_STR_SLOT_COUNT] = {{ {str_offs} }};

// 参数块版本（须与 ApoShared.h 的 APO_PARAMS_VERSION 全等；
// 消费端以版本全等为门，版本不符即整块拒绝——布局演进的安全阀）。
#define APO_PARAM_BLOCK_VERSION {PARAMS_VERSION}

// 块布局常量（与 ApoShared.h / Dart apo_param_index.dart 三方一致，
// smoke_apo_param_layout 交叉断言）。
#define APO_BLOCK_HEADER_BYTES {HEADER_BYTES}
#define APO_BLOCK_MASK_OFFSET {HEADER_BYTES}
#define APO_BLOCK_VALUES_OFFSET {values_off}
#define APO_BLOCK_STRINGS_OFFSET {strings_off}
#define APO_BLOCK_USED_BYTES {total}
#define APO_BLOCK_MAPPING_BYTES {MAPPING_BYTES}
"""


def gen_dart(params, values_off, strings_off, slot_offs, total, digest):
    entries = ',\n  '.join(f"'{pid}': {i}" for i, (pid, _) in enumerate(params))
    types = ', '.join(str(t) for _, t in params)
    str_entries = ',\n  '.join(
        f"'{sid}': {i}" for i, (sid, _) in enumerate(STRING_SLOTS))
    str_caps = ', '.join(str(c) for _, c in STRING_SLOTS)
    str_offs = ', '.join(str(o) for o in slot_offs)
    return f"""// GENERATED by tools/gen_apo_param_layout.py — do not edit by hand.
// Source: engine/engine_param_table.h sha256[:16]={digest}
// Regenerate: python3 tools/gen_apo_param_layout.py

/// APO 参数块序号表（设计 D4）：块内第 i 个 u32 数值槽恒对应
/// kApoNumParamIds 第 i 项（C 侧同名表）；本表为 id→序号。
const int kApoNumParamCount = {len(params)};
const Map<String, int> kApoNumParamIndex = {{
  {entries}
}};

/// 类型码 0=float 1=int32 2=bool（与 C 侧 kApoNumParamTypes 同序）。
const List<int> kApoNumParamTypes = [{types}];

/// 字符串定长槽：id→槽序号（顺序即块内排列）。
const Map<String, int> kApoStrSlotIndex = {{
  {str_entries}
}};
const List<int> kApoStrSlotCaps = [{str_caps}];
const List<int> kApoStrSlotOffsets = [{str_offs}];

/// 参数块版本（须与 ApoShared.h 的 APO_PARAMS_VERSION 全等）。
const int kApoParamBlockVersion = {PARAMS_VERSION};

/// 块布局常量（与 ApoShared.h / ApoParamIndex.h 三方一致，
/// smoke_apo_param_layout 交叉断言）。
const int kApoBlockHeaderBytes = {HEADER_BYTES};
const int kApoBlockMaskOffset = {HEADER_BYTES};
const int kApoBlockValuesOffset = {values_off};
const int kApoBlockStringsOffset = {strings_off};
const int kApoBlockUsedBytes = {total};
const int kApoBlockMappingBytes = {MAPPING_BYTES};
"""


def main():
    check = '--check' in sys.argv
    params = parse_numeric_params()
    values_off, strings_off, slot_offs, total = layout(params)
    digest = sha16(PARAM_TABLE)
    outs = [
        (OUT_C, gen_c(params, values_off, strings_off, slot_offs, total, digest)),
        (OUT_DART, gen_dart(params, values_off, strings_off, slot_offs, total, digest)),
    ]
    rc = 0
    for path, content in outs:
        if check:
            cur = open(path, encoding='utf-8').read() if os.path.exists(path) else None
            if cur != content:
                print(f'DRIFT: {os.path.relpath(path, ROOT)} 与引擎表不一致，请重跑生成器')
                rc = 1
            else:
                print(f'OK: {os.path.relpath(path, ROOT)}')
        else:
            with open(path, 'w', encoding='utf-8', newline='\n') as f:
                f.write(content)
            print(f'WROTE: {os.path.relpath(path, ROOT)}')
    print(f'numeric params: {len(params)} '
          f'(static 184 + dynamic {len(DYNAMIC_FLOAT_IDS)}), '
          f'block used {total} / {MAPPING_BYTES} bytes')
    return rc


if __name__ == '__main__':
    sys.exit(main())
