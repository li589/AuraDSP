/*
 * layering_guard_test.dart — 分层依赖方向守卫（P1-3，2026-10-23）
 *
 * 约定（docs/10-架构/UI-设计系统与目录约定.md §3）：
 *   engine/  传输层，不得依赖 UI
 *   core/    状态/主题，不得依赖 features
 *   ui/      设计系统，不得依赖 features（页面反向依赖设计系统才合法）
 *   features/ 页面，可依赖 ui/core/engine
 *
 * 另守 P1-2 迁移安全：features/chrome.dart 与 features/widgets.dart 必须是
 * 纯 export 薄壳（防止有人在旧路径继续写实现，造成两份真相）。
 */
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<File> _darts(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

List<String> _importLines(File f) => f
    .readAsLinesSync()
    .where((l) => l.trimLeft().startsWith('import ') ||
        l.trimLeft().startsWith('export '))
    .toList();

void main() {
  test('ui/ 不得反向依赖 features/', () {
    final bad = <String>[];
    for (final f in _darts('lib/ui')) {
      for (final l in _importLines(f)) {
        if (l.contains('features/')) bad.add('${f.path}: $l');
      }
    }
    expect(bad, isEmpty, reason: 'lib/ui 出现反向依赖：\n${bad.join('\n')}');
  });

  test('engine/ 不得依赖 UI 层', () {
    final bad = <String>[];
    for (final f in _darts('lib/engine')) {
      for (final l in _importLines(f)) {
        if (l.contains('features/') || l.contains("'../ui/")) {
          bad.add('${f.path}: $l');
        }
      }
    }
    expect(bad, isEmpty, reason: 'engine 出现 UI 依赖：\n${bad.join('\n')}');
  });

  test('core/ 不得依赖 features/ 与 ui/', () {
    final bad = <String>[];
    for (final f in _darts('lib/core')) {
      if (f.path.replaceAll('\\', '/').contains('/l10n/gen/')) continue;
      for (final l in _importLines(f)) {
        if (l.contains('features/')) bad.add('${f.path}: $l');
      }
    }
    expect(bad, isEmpty, reason: 'core 出现 features 依赖：\n${bad.join('\n')}');
  });

  test('features/chrome.dart 与 widgets.dart 必须是纯 export 薄壳', () {
    for (final path in [
      'lib/features/chrome.dart',
      'lib/features/widgets.dart',
    ]) {
      final lines = File(path)
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('//'))
          .toList();
      expect(lines.length, lessThanOrEqualTo(2),
          reason: '$path 只允许 export 语句（P1-2 后新实现请写 lib/ui/）');
      expect(lines.any((l) => l.startsWith('export ')), isTrue,
          reason: '$path 缺少 export');
    }
  });
}
