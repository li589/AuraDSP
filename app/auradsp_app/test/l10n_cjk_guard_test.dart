/*
 * l10n_cjk_guard_test.dart — 硬编码中文棘轮（P2-2，2026-10-23）
 *
 * 语义：基线（test/l10n_cjk_baseline.txt）**只允许变小**。
 *   - 新增硬编码中文 → 本测试红（请改用 l10nOf(context) / arb 词条）；
 *   - 还清债务 → 跑 `python tools/l10n_cjk_scan.py --baseline` 降低基线并随提交更新。
 *
 * 扫描规则必须与 tools/l10n_cjk_scan.py 完全一致：
 *   1. 去掉块注释；2. 跳过 // 开头的整行；3. 统计字符串字面量内含 CJK 的次数。
 */
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _block = RegExp(r'/\*[\s\S]*?\*/', multiLine: true);
final _cjk = RegExp(
    r"'[^'\n]*[\u4e00-\u9fff][^'\n]*'|"
    r'"[^"\n]*[\u4e00-\u9fff][^"\n]*"');

int _count(String text) {
  final stripped = text.replaceAll(_block, '');
  var n = 0;
  for (final line in stripped.split('\n')) {
    if (line.trimLeft().startsWith('//')) continue;
    n += _cjk.allMatches(line).length;
  }
  return n;
}

Map<String, int> _baseline() {
  final f = File('test/l10n_cjk_baseline.txt');
  final out = <String, int>{};
  if (!f.existsSync()) return out;
  for (final line in f.readAsLinesSync()) {
    final s = line.trim();
    if (s.isEmpty || s.startsWith('#')) continue;
    final i = s.lastIndexOf(' ');
    if (i <= 0) continue;
    out[s.substring(0, i)] = int.tryParse(s.substring(i + 1)) ?? 0;
  }
  return out;
}

void main() {
  test('lib/features 硬编码中文不超过基线（棘轮只降不升）', () {
    final base = _baseline();
    expect(base, isNotEmpty, reason: '基线缺失：test/l10n_cjk_baseline.txt');
    final offenders = <String>[];
    final stale = <String>[];
    final dir = Directory('lib/features');
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final rel = e.path.replaceAll('\\', '/');
      final n = _count(e.readAsStringSync());
      final allow = base[rel] ?? 0;
      if (n > allow) {
        offenders.add('$rel: $n > 基线 $allow');
      } else if (n < allow) {
        stale.add('$rel: $n < 基线 $allow（可下调基线）');
      }
    }
    // 基线里有、磁盘上已不存在的条目也视为过期（提示，不判红）。
    for (final k in base.keys) {
      if (!File(k).existsSync()) stale.add('$k: 文件已不存在');
    }
    if (stale.isNotEmpty) {
      // ignore: avoid_print
      print('棘轮提示（非失败，可跑 --baseline 降基线）：\n  ${stale.join('\n  ')}');
    }
    expect(offenders, isEmpty,
        reason: '新增硬编码中文须改 l10n：\n  ${offenders.join('\n  ')}');
  });
}
