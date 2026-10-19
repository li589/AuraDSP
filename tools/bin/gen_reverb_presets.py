#!/usr/bin/env python3
"""gen_reverb_presets.py — 混响预设矩阵 JSON 生成器（B-4 / 计划 §5.3 混响项）。

从 engine/legacy/jdsp/Effects/reverb.c 的 sf_presetreverb ps[] 与 CASE 枚举提取，
产出 test/data/reverb_presets.json（19 预设 × 17 维，含预设名），供
param_contract_test.dart Part L 三方契约（引擎源码 ↔ JSON ↔ UI 索引域）消费。

用法：python tools/bin/gen_reverb_presets.py
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REVERB_C = os.path.join(ROOT, 'engine', 'legacy', 'jdsp', 'Effects', 'reverb.c')
OUT = os.path.join(ROOT, 'test', 'data', 'reverb_presets.json')

COLS = ['osf', 'ERtoLt', 'ERWet', 'Dry', 'ERFac', 'ERWdth', 'Wdth', 'Wet',
        'Wander', 'BassB', 'Spin', 'InpLP', 'BasLP', 'DmpLP', 'OutLP',
        'RT60', 'Delay']

NUMBER = re.compile(r'-?\d+(?:\.\d+)?f?')


def parse_rows(src):
    """ps[] 块 → 每行 17 个数值。"""
    m = re.search(r'\}\s*ps\s*\[\]\s*=\s*\{(.*?)\n\s*\};', src, re.S)
    rows = []
    for line in m.group(1).splitlines():
        s = line.strip()
        if not s.startswith('{'):
            continue
        nums = NUMBER.findall(s)
        if len(nums) != 17:
            sys.exit(f'ps[] 行数值数异常: {len(nums)} ({line.strip()[:60]})')
        rows.append([float(n[:-1]) if n.endswith('f') else float(n) for n in nums])
    return rows


def parse_names(src):
    """CASE(SF_REVERB_PRESET_X, i) → {index: short_name}。"""
    names = {}
    for line in src.splitlines():
        m = re.search(r'CASE\(SF_REVERB_PRESET_(\w+),\s*(\d+)\)', line)
        if m:
            names[int(m.group(2))] = m.group(1)
    return names


def main():
    src = open(REVERB_C, encoding='utf-8').read()
    rows = parse_rows(src)
    names = parse_names(src)
    if len(rows) != 19:
        sys.exit(f'ps[] 预设数异常: {len(rows)} != 19')
    presets = []
    for i, row in enumerate(rows):
        presets.append({
            'index': i,
            'name': names.get(i, f'PRESET{i}'),
            'values': {COLS[j]: row[j] for j in range(len(COLS))},
        })
    doc = {
        'source': 'engine/legacy/jdsp/Effects/reverb.c',
        'columns': COLS,
        'presets': presets,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
    print(f'写出 {OUT}: {len(presets)} 预设 × {len(COLS)} 维')
    print('预设名:', ' / '.join(f"{p['index']}:{p['name']}" for p in presets))
    sys.exit(0)


if __name__ == '__main__':
    main()
