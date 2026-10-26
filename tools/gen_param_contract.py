#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_param_contract.py — 从引擎 C++ 源码生成 Dart 侧参数契约 fixture。

三层事实源对账的"引擎侧快照"生成器：
  engine/engine_param_table.h — 引擎权威参数表（id ↔ struct member）
  engine/engine_internal.h    — Params struct 默认（引擎默认的第一来源）
  engine/auradsp_engine.cpp   — create 内的覆盖初始化（第二来源：
                                input_ch_gain=1.0 / comp_freq / comp_gain）

产出（供 app/test/param_contract_test.dart 消费）：
  app/auradsp_app/test/fixtures/param_defaults_contract.g.dart
    - kParamDefaultRows:      (engineId, member, cppDefault) 可默认校验的参数
    - kEngineCustomOnlyIds:   表内无 struct member 的 custom 参数
    - kEngineDynamicParamIds: set 分支动态展开 id（stereo.bandN/input.balance.N/liveprog.paramN）
    - kEngineRangeRows:       (engineId, min, max) FLOAT/INT 表内范围（Part F 消费）
    - kContractLineCounts:    两个 header + create 的行数哨兵；
                              header/create 变更而未重生 fixture → 测试红

规则：引擎侧参数集合的任何变化都必须重新生成本文件；fixture 与源码
不一致时 param_contract_test.dart 的行数哨兵断言直接失败。
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE_DIR = os.path.join(ROOT, 'engine')
PARAM_TABLE = os.path.join(ENGINE_DIR, 'engine_param_table.h')
INTERNAL = os.path.join(ENGINE_DIR, 'engine_internal.h')
CREATE_CPP = os.path.join(ENGINE_DIR, 'auradsp_engine.cpp')
OUT = os.path.join(ROOT, 'app', 'auradsp_app', 'test', 'fixtures',
                   'param_defaults_contract.g.dart')

# set 分支动态展开 id（不在静态 kEngineParamTable，由 strncmp 分支处理）。
DYNAMIC_IDS = (
    [f'stereo.band{i}' for i in range(1, 6)]
    + [f'input.balance.{i}' for i in range(1, 9)]
    + [f'liveprog.param{i}' for i in range(1, 9)]
)


def sha16(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()[:16]


def parse_param_table():
    """→ [(id, kind, member_or_None, explicit_array_idx_or_None, min_or_None, max_or_None)]
    （kEngineParamTable 数组内）。显式下标用于 post.gain.c0 → post_gain_ch[0]
    这类 0 基 id；未写显式下标时沿用 id 尾部数字 = 下标+1 的历史约定。"""
    src = open(PARAM_TABLE, encoding='utf-8').read()
    start = src.index('static const EngineParamDesc kEngineParamTable[]')
    end = src.index('\n};', start)
    body = src[start:end]
    pat = re.compile(
        r'PARAM_(FLOAT|INT|BOOL|CUSTOM_SET_STANDARD_GET|CUSTOM|CUSTOM_SET_ONLY|CUSTOM_GET_ONLY)'
        r'\(\s*"([^"]+)"\s*(?:,\s*([A-Za-z0-9_]+)(?:\[(\d+)\])?)?'
        r'(?:\s*,\s*(-?[\d.]+f?))?(?:\s*,\s*(-?[\d.]+f?))?')
    rows = []
    member_kinds = {'FLOAT', 'INT', 'BOOL', 'CUSTOM_SET_STANDARD_GET'}
    for m in pat.finditer(body):
        kind, pid, arg2, arr_idx, lo, hi = m.groups()
        member = arg2 if kind in member_kinds else None
        rng = None
        if kind in ('FLOAT', 'INT') and lo is not None and hi is not None:
            rng = (float(lo.rstrip('f')), float(hi.rstrip('f')))
        rows.append((pid, kind, member, int(arr_idx) if arr_idx is not None else None, rng))
    return rows


def parse_struct_defaults():
    """→ {member: (cpp_type, default_literal)}；数组按名记 None（create 覆盖处理）。"""
    src = open(INTERNAL, encoding='utf-8').read()
    start = src.index('struct Params {')
    end = src.index('\n};', start)
    body = src[start:end]
    out = {}
    for m in re.finditer(
            r'std::atomic<(float|int32_t)>\s+([A-Za-z0-9_]+)'
            r'(?:\[(\d+)\])?\s*(?:\{([^}]*)\})?\s*;', body):
        cpp_type, member, arr, init = m.groups()
        out[member] = (cpp_type, None if arr else (init or '0').strip())
    return out


def parse_create_overrides():
    """→ {array_member: [逐元素默认]}（create 中的 default_xxx[M] 数组或
    循环内标量 store；按所属 for 的迭代次数展开）。"""
    src = open(CREATE_CPP, encoding='utf-8').read()
    start = src.index('auradsp_handle auradsp_create')
    end = src.index('\n}', start)
    body = src[start:end]

    consts = {}   # name -> [elements]
    for m in re.finditer(
            r'const\s+(?:float|int)\s+(\w+)\[(\d+)\]\s*=\s*\{([^}]*)\}', body):
        consts[m.group(1)] = [v.strip() for v in m.group(3).split(',')]

    out = {}
    loop_n = None
    for line in body.split('\n'):
        fm = re.search(r'for\s*\(.*;\s*\w+\s*<\s*(\d+)\s*;', line)
        if fm:
            loop_n = int(fm.group(1))
        sm = re.search(r'h->p\.([A-Za-z0-9_]+)\[i\]\.store\(([^)]+)\)', line)
        if sm:
            member, expr = sm.group(1), sm.group(2).strip()
            am = re.fullmatch(r'([A-Za-z0-9_]+)\[i\]', expr)
            if am and am.group(1) in consts:
                out[member] = list(consts[am.group(1)])
            else:
                # 循环内标量：按循环次数展开
                n = loop_n if loop_n else 1
                out[member] = [expr] * n
    return out


def parse_create_scalar_overrides():
    """→ {member: value}（create 中标量 store，如 input_ch_gain=1.0 —— 但它是
    数组，逐元素同值，在 array 逻辑中已含；这里仅兜底未来的标量覆盖）。"""
    return {}


def fmt_cpp_default(cpp_type, lit):
    lit = lit.strip()
    if 'kChMaskAll' in lit:
        lit = '0xFF'
    elif 'kChMaskNoLfe' in lit:
        lit = '0xF7'
    lit = lit.replace('(int32_t)', '').strip()
    if cpp_type == 'int32_t':
        if lit.lower().startswith('0x'):
            return str(int(lit, 16))
        return str(int(float(lit)))
    f = float(lit.rstrip('f'))
    return repr(f)


def main():
    rows = parse_param_table()
    struct = parse_struct_defaults()
    overrides = parse_create_overrides()
    fingerprint = ':'.join(sha16(p) for p in (PARAM_TABLE, INTERNAL, CREATE_CPP))

    # 数组 member（如 comp_freq[7]）逐元素默认：create 覆盖优先，否则 0
    array_defaults = {}
    for member, (cpp_type, _d) in struct.items():
        pass  # struct 里数组成员 default=None，由 override 提供

    problems = []
    default_rows = []     # (id, member, cppDefault_str)
    custom_only = []      # 无 member 的 id
    range_rows = []       # (id, min, max)（FLOAT/INT 的表内范围）
    # id -> 该 id 使用的数组下标（comp.freq1 → comp_freq[0]）
    array_index_by_id = {}
    seen_ids = set()
    for pid, kind, member, explicit_idx, rng in rows:
        if pid in seen_ids:
            problems.append(f'重复 id: {pid}')
        seen_ids.add(pid)
        if rng is not None:
            range_rows.append((pid, rng[0], rng[1]))
        if member is None:
            custom_only.append(pid)
            continue
        if member not in struct:
            problems.append(f'{pid}: member {member} 不在 struct Params')
            continue
        cpp_type, sdef = struct[member]
        if sdef is not None:
            default_rows.append((pid, member, fmt_cpp_default(cpp_type, sdef)))
        else:
            # 数组 member：显式下标优先（post.gain.c0 → [0]）；否则约定
            # id 尾部数字 = 下标+1（comp.freq1 → [0]）。
            if explicit_idx is not None:
                idx = explicit_idx
            else:
                m = re.search(r'(\d+)$', pid)
                if not m:
                    problems.append(f'{pid}: 数组 member {member} 无下标约定，需显式登记')
                    continue
                idx = int(m.group(1)) - 1
            if member not in overrides:
                problems.append(f'{pid}: 数组 {member} 在 create 无默认覆盖且 struct 无初值')
                continue
            ov = overrides[member]
            if idx >= len(ov):
                problems.append(f'{pid}: 数组 {member}[{idx}] 超出覆盖长度 {len(ov)}')
                continue
            default_rows.append((pid, member, fmt_cpp_default(cpp_type, ov[idx])))
            array_index_by_id[pid] = idx

    if problems:
        print('=== 契约解析失败（需人工处理）===')
        for p in problems:
            print(' ', p)
        sys.exit(1)

    lines = [
        '// GENERATED FILE — DO NOT EDIT.',
        '// 由 tools/gen_param_contract.py 从引擎 C++ 源码生成（引擎侧默认快照）。',
        '// 消费方：app/test/param_contract_test.dart（默认值一致性 + 权威对账）。',
        f'// 覆盖引擎参数 {len(seen_ids)} 个（含 {len(DYNAMIC_IDS)} 个 set 分支动态 id）。',
        '',
        'class ParamDefaultRow {',
        '  final String engineId;',
        '  final String cppMember;',
        '  final Object cppDefault;',
        '  const ParamDefaultRow(this.engineId, this.cppMember, this.cppDefault);',
        '}',
        '',
        'const List<ParamDefaultRow> kParamDefaultRows = [',
    ]
    for pid, member, dflt in default_rows:
        lines.append("  ParamDefaultRow('%s', '%s', %s)," % (pid, member, dflt))
    lines.append('];')
    lines.append('')
    lines.append('/// 表内无 struct member 的 custom 参数 id（无默认可校验）。')
    lines.append('const List<String> kEngineCustomOnlyParamIds = [')
    for pid in custom_only:
        lines.append("  '%s'," % pid)
    lines.append('];')
    lines.append('')
    lines.append('/// set 分支动态展开的 id（stereo.bandN / input.balance.N / liveprog.paramN）。')
    lines.append('const List<String> kEngineDynamicParamIds = [')
    for pid in DYNAMIC_IDS:
        lines.append("  '%s'," % pid)
    lines.append('];')
    lines.append('')
    lines.append('/// 引擎数值参数范围（FLOAT/INT 表内 min/max；BOOL 无范围）。')
    lines.append('/// 消费方：param_contract_test.dart Part F（spec 范围一致性）。')
    lines.append('class ParamRangeRow {')
    lines.append('  final String engineId;')
    lines.append('  final double min;')
    lines.append('  final double max;')
    lines.append('  const ParamRangeRow(this.engineId, this.min, this.max);')
    lines.append('}')
    lines.append('const List<ParamRangeRow> kEngineRangeRows = [')
    for pid, lo, hi in range_rows:
        lines.append("  ParamRangeRow('%s', %s, %s)," % (pid, repr(lo), repr(hi)))
    lines.append('];')
    lines.append('')
    lines.append('/// 引擎源码行数哨兵（param_table / internal / create 的行数）。')
    lines.append('/// header/create 变更而未重生 fixture → param_contract_test 行数断言失败。')
    line_sentinel = ';'.join(
        '%s:%d' % (k, sum(1 for _ in open(p, encoding='utf-8')))
        for k, p in (('param_table', PARAM_TABLE), ('internal', INTERNAL),
                     ('create', CREATE_CPP)))
    lines.append("const String kContractLineCounts = '%s';" % line_sentinel)
    lines.append('')

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'OK: {len(default_rows)} default rows + {len(custom_only)} custom-only '
          f'+ {len(DYNAMIC_IDS)} dynamic = {len(default_rows)+len(custom_only)} table ids '
          f'(unique {len(seen_ids)}); {len(range_rows)} range rows')
    print(f'fingerprint: {fingerprint}')
    print(f'wrote {os.path.relpath(OUT, ROOT)}')


if __name__ == '__main__':
    main()
