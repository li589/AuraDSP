import 'dart:convert';
import 'dart:io';

import 'package:auradsp_app/core/debug/debug_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('--debug-log 生成 JSONL，ui/param/engine 事件同流', () {
    final dir = Directory.systemTemp.createTempSync('aura_dbg_test_');
    final path = '${dir.path}/trace.jsonl';
    final t = DebugTrace.instance;
    t.resetForTesting();
    t.initFromArgs(['--debug', '--debug-log=$path']);
    expect(t.enabled, isTrue);
    t.uiControl('eq.enable', true, widget: 'switch', section: 'eq');
    t.paramSent('eq.enable', 1, kind: 'int');
    t.paramAck('eq.enable', 0, 12);
    t.flush();
    final lines = File(path).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
    expect(lines, isNotEmpty);
    final rows = lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
    expect(rows.any((r) => r['cat'] == 'ui' && r['action'] == 'control'), isTrue);
    expect(rows.any((r) => r['cat'] == 'param' && r['action'] == 'send'), isTrue);
    expect(rows.any((r) => r['cat'] == 'engine' && r['action'] == 'ack'), isTrue);
    expect(t.controlCount, greaterThanOrEqualTo(1));
    expect(t.ackCount, greaterThanOrEqualTo(1));
    t.resetForTesting();
    dir.deleteSync(recursive: true);
  });

  test('未传 --debug 时零文件、零事件', () {
    final t = DebugTrace.instance;
    t.resetForTesting();
    t.initFromArgs(const []);
    expect(t.enabled, isFalse);
    t.uiControl('eq.enable', true);
    t.flush();
    expect(t.lastEvents, isEmpty);
  });

  test('长字符串事件被截断，避免把脚本源码写满日志', () {
    final dir = Directory.systemTemp.createTempSync('aura_dbg_trunc_');
    final path = '${dir.path}/trace.jsonl';
    final t = DebugTrace.instance;
    t.resetForTesting();
    t.initFromArgs(['--debug', '--debug-log=$path']);
    t.paramSent('liveprog.code', 'x' * 5000, kind: 'string');
    t.flush();
    final rows = File(path).readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
    final send = rows.firstWhere((r) => r['action'] == 'send' && r['cat'] == 'param');
    final value = (send['data'] as Map)['value'] as String;
    expect(value.length, lessThan(300), reason: '长文本必须截断');
    t.resetForTesting();
    dir.deleteSync(recursive: true);
  });
}
