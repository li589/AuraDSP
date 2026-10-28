/*
 * preset_files_test.dart — 预设文件层行为（2026-10-28）
 *
 * 覆盖三处此前只会静默出错的地方：
 *   1. `_safeFileName` 归一化碰撞：`My Song` 与 `My_Song` 曾落到同一个文件；
 *   2. `importFromFile` 无版本闸门 / 同名静默覆盖；
 *   3. `deletePreset` 依赖「名字 → 归一化文件名」的直接推导（换成哈希名即失效）。
 *
 * 测试进程内 ConfigManager.baseDir 自动指向临时目录（见 config.dart），
 * 不会触碰真实 %APPDATA%。
 */
import 'dart:convert';
import 'dart:io';

import 'package:auradsp_app/core/presets.dart';
import 'package:flutter_test/flutter_test.dart';

AuraPreset _p(String name, {double gate = 0.2}) => AuraPreset(
      name: name,
      createdAt: DateTime.now().toIso8601String(),
      params: {
        'gate': {'threshold': gate},
      },
    );

List<AuraPreset> _userPresets() =>
    PresetLibrary.listAll().where((e) => !e.isFactory).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await PresetLibrary.preloadFactoryAssets();
    // 清空用户预设目录，保证每个用例从零开始（同一进程共享 baseDir）。
    final dir = Directory(PresetLibrary.userDir);
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path.toLowerCase().endsWith('.json')) f.deleteSync();
      }
    }
  });

  group('文件名归一化碰撞', () {
    test('My Song 与 My_Song 共存，各自独立落盘', () {
      final a = _p('My Song', gate: 0.11);
      final b = _p('My_Song', gate: 0.22);
      expect(PresetLibrary.saveUserPreset(a), isTrue);
      expect(PresetLibrary.saveUserPreset(b), isTrue);

      final names = _userPresets().map((e) => e.name).toList()..sort();
      expect(names, ['My Song', 'My_Song'],
          reason: '归一化后同名（my_song）必须靠内容对账/哈希后缀区分');

      final files = Directory(PresetLibrary.userDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .toList();
      expect(files.length, 2, reason: '两个预设不得写进同一个文件');

      // 各自内容未被对方覆盖
      final gateOf = {
        for (final p in _userPresets())
          p.name: (p.params['gate'] as Map)['threshold'],
      };
      expect(gateOf['My Song'], closeTo(0.11, 1e-9));
      expect(gateOf['My_Song'], closeTo(0.22, 1e-9));
    });

    test('同名保存覆盖原文件，不产生第二份', () {
      expect(PresetLibrary.saveUserPreset(_p('Same Name', gate: 0.3)), isTrue);
      expect(PresetLibrary.saveUserPreset(_p('Same Name', gate: 0.9)), isTrue);

      final mine = _userPresets();
      expect(mine.length, 1, reason: '同名保存是覆盖语义，不是新增');
      expect((mine.first.params['gate'] as Map)['threshold'],
          closeTo(0.9, 1e-9));
    });

    test('deletePreset 按名称对账定位文件（含哈希后缀形态）', () {
      expect(PresetLibrary.saveUserPreset(_p('Take Me')), isTrue);
      expect(PresetLibrary.saveUserPreset(_p('Take_Me')), isTrue);
      expect(_userPresets().length, 2);

      final target =
          _userPresets().firstWhere((e) => e.name == 'Take_Me');
      expect(PresetLibrary.deletePreset(target), isTrue,
          reason: '文件名可能是 take_me_<hash>.json，删除不能靠猜');

      final left = _userPresets();
      expect(left.length, 1);
      expect(left.first.name, 'Take Me', reason: '不得误删同归一化名的另一个预设');

      // 重复删除应返回 false（文件已不存在）
      expect(PresetLibrary.deletePreset(target), isFalse);
    });
  });

  group('导入闸门', () {
    String writeTemp(Map<String, dynamic> json) {
      final f = File('${Directory.systemTemp.path}'
          '${Platform.pathSeparator}aura_import_'
          '${DateTime.now().microsecondsSinceEpoch}.json');
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
      return f.path;
    }

    test('版本高于当前 schema 的文件被拒绝（不当成空预设导入）', () {
      final path = writeTemp({
        'schemaVersion': PresetLibrary.schemaVersionCurrent + 1,
        'name': 'From The Future',
        'parameters': {
          'gate': {'threshold': 0.4},
        },
      });
      expect(PresetLibrary.importFromFile(path), isNull);
      expect(_userPresets().any((e) => e.name == 'From The Future'), isFalse,
          reason: '读不懂的节不能静默落成空预设');
      File(path).deleteSync();

      // 当前版本可正常导入
      final ok = writeTemp({
        'schemaVersion': PresetLibrary.schemaVersionCurrent,
        'name': 'From Today',
        'parameters': {
          'gate': {'threshold': 0.4},
        },
      });
      final imported = PresetLibrary.importFromFile(ok);
      expect(imported, isNotNull);
      expect(imported!.name, 'From Today');
      File(ok).deleteSync();
    });

    test('同名导入改名而非覆盖', () {
      expect(PresetLibrary.saveUserPreset(_p('Dup', gate: 0.1)), isTrue);
      final path = writeTemp({
        'schemaVersion': PresetLibrary.schemaVersionCurrent,
        'name': 'Dup',
        'parameters': {
          'gate': {'threshold': 0.8},
        },
      });
      final imported = PresetLibrary.importFromFile(path);
      expect(imported, isNotNull);
      expect(imported!.name, 'Dup (2)');
      File(path).deleteSync();

      final all = _userPresets();
      expect(all.map((e) => e.name).toSet(), {'Dup', 'Dup (2)'});
      final original = all.firstWhere((e) => e.name == 'Dup');
      expect((original.params['gate'] as Map)['threshold'],
          closeTo(0.1, 1e-9), reason: '用户原有的 Dup 不得被导入件覆盖');
    });
  });
}
