// 一次性出厂预设生成器（zz_ 前缀，非门禁）
// 用法：flutter test test/zz_gen_factory_presets.dart
// 产物：
//   assets/presets/defaults.json        —— 全新 AppModel 的 23 节全量基线
//   assets/presets/factory/<name>.json   —— 基线深合并各出厂预设原文（preset 键优先）
// 生成后本文件即完成使命（保留作溯源证据，不进 *_test.dart 门禁）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/state.dart';

Map<String, dynamic> _deepMerge(Map<dynamic, dynamic> base, Map<dynamic, dynamic> over) {
  final out = Map<String, dynamic>.from(base);
  over.forEach((k, v) {
    if (v is Map && out[k] is Map) {
      out[k] = _deepMerge(out[k] as Map<dynamic, dynamic>, v);
    } else {
      out[k] = v;
    }
  });
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生成 defaults.json 与 6 个出厂预设 JSON', () {
    // 1. 基线：全新 model 快照
    final fresh = AppModel(testing: true);
    final baseSnap = PresetLibrary.snapshot(fresh, name: '__defaults__');
    final base = baseSnap.params;

    // 2. 出厂预设原文（ensureInitialized 从内存表落盘后读回）
    PresetLibrary.ensureInitialized();
    final factories =
        PresetLibrary.listAll().where((p) => p.isFactory).toList();
    expect(factories.length, 6);

    const outDir = 'assets/presets';
    Directory('$outDir/factory').createSync(recursive: true);

    final enc = JsonEncoder.withIndent('  ');
    File('$outDir/defaults.json').writeAsStringSync(enc.convert({
      '_comment': 'AuraDSP 出厂默认基线（ParamDefaults 的全量展开）。'
          '由 test/zz_gen_factory_presets.dart 生成，勿手改。',
      'schemaVersion': 1,
      'params': base,
    }));

    for (final p in factories) {
      final merged = _deepMerge(base, Map<dynamic, dynamic>.of(p.params));
      File('$outDir/factory/${p.name}.json').writeAsStringSync(enc.convert({
        'name': p.name,
        'schemaVersion': 1,
        'isFactory': true,
        'category': p.category,
        'description': p.description,
        'params': merged,
      }));
      debugPrintS('gen ${p.name}: sections=${merged.length} '
          'leaves=${_countLeaves(merged)}');
    }
    debugPrintS('DONE');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

int _countLeaves(dynamic n) {
  if (n is Map) return n.values.fold(0, (a, v) => a + _countLeaves(v));
  if (n is List) return n.fold(0, (a, v) => a + _countLeaves(v));
  return 1;
}

// 一次性生成工具，允许直接 print 输出进度。
// ignore: avoid_print
void debugPrintS(String s) => print(s);
