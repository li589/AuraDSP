# -*- coding: utf-8 -*-
"""summarize_trace.py — 汇总 DebugTrace JSONL，核对 UI→DSP 链路。

用法：
  python tools/debug/summarize_trace.py [trace.jsonl]

输出：
  · 各类事件计数
  · 出现过的参数控件数
  · 有 ui/param 但无 engine.ack 的 id（说明回执缺失）
  · 有 engine.ack 但无 ui.control 的 id（可能是预设/会话恢复下发，非用户操作）
"""
import json
import os
import sys
from collections import Counter

DEFAULT = os.path.join(os.environ.get('TEMP', os.path.expanduser('~')),
                       'auradsp_debug_trace.jsonl')


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.isfile(path):
        print('未找到调试日志: %s' % path)
        return 2

    rows = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    cats = Counter(r.get('cat') for r in rows)
    ui_ids = set()
    param_ids = set()
    ack_ids = set()
    rejected = []
    for r in rows:
        data = r.get('data') or {}
        rid = data.get('id')
        if not isinstance(rid, str):
            continue
        if r.get('cat') == 'ui' and r.get('action') == 'control':
            ui_ids.add(rid)
        elif r.get('cat') == 'param' and r.get('action') == 'send':
            param_ids.add(rid)
        elif r.get('cat') == 'engine' and r.get('action') == 'ack':
            if data.get('rc') == 0:
                ack_ids.add(rid)
            else:
                rejected.append((rid, data.get('rc'), data.get('msg')))
    missing_ack = sorted((ui_ids | param_ids) - ack_ids)
    ack_without_ui = sorted(ack_ids - ui_ids - param_ids)

    print('trace: %s' % path)
    print('events: %d  session: %s' % (len(rows), rows[0].get('session') if rows else '-'))
    print('cats: %s' % dict(cats))
    print('ui controls: %d  param ids: %d  acked: %d' %
          (len(ui_ids), len(param_ids), len(ack_ids)))
    if rejected:
        print('\nengine rejections:')
        for rid, rc, msg in rejected[:20]:
            print('  %-32s rc=%s %s' % (rid, rc, msg or ''))
    if missing_ack:
        print('\nMISSING engine.ack (%d):' % len(missing_ack))
        for rid in missing_ack[:30]:
            print('  ' + rid)
    if ack_without_ui:
        print('\nACK without ui.control (%d, preset/session writes):' % len(ack_without_ui))
        for rid in ack_without_ui[:20]:
            print('  ' + rid)
    print('\nRESULT: %s' % ('PASS (every ui/param id has an ack)' if not missing_ack else 'FAIL'))
    return 0 if not missing_ack else 1


if __name__ == '__main__':
    sys.exit(main())
