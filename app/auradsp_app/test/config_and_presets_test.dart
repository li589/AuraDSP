import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/session_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig & ConfigManager Tests', () {
    test('Default AppConfig matches specification', () {
      final cfg = AppConfig();
      expect(cfg.sampleRate, 48000);
      expect(cfg.maxBlockFrames, 1024);
      expect(cfg.stereoWidenMax, 0.75);
      expect(cfg.vizFps, 30);
      expect(cfg.autoRestoreSession, isTrue);
      expect(cfg.defaultLatencyMode, 2);
    });

    test('AppConfig JSON round-trip preserves all values', () {
      final original = AppConfig(
        sampleRate: 96000,
        maxBlockFrames: 2048,
        stereoWidenMax: 0.85,
        vizFps: 60,
        vizFftSize: 8192,
        defaultLatencyMode: 1,
        locale: 'en',
        themeId: 'aurora',
        autoRestoreSession: false,
        autoSaveDebounceMs: 300,
        maxIrDurationSeconds: 45.0,
        maxFileSizeMb: 128.0,
      );

      final json = original.toJson();
      final restored = AppConfig.fromJson(json);

      expect(restored.sampleRate, 96000);
      expect(restored.maxBlockFrames, 2048);
      expect(restored.stereoWidenMax, 0.85);
      expect(restored.vizFps, 60);
      expect(restored.vizFftSize, 8192);
      expect(restored.defaultLatencyMode, 1);
      expect(restored.locale, 'en');
      expect(restored.themeId, 'aurora');
      expect(restored.autoRestoreSession, isFalse);
      expect(restored.autoSaveDebounceMs, 300);
      expect(restored.maxIrDurationSeconds, 45.0);
      expect(restored.maxFileSizeMb, 128.0);
    });

    test('ConfigManager file persistence works', () {
      final cfg = ConfigManager.load();
      expect(cfg, isNotNull);
      cfg.stereoWidenMax = 0.80;
      final saved = ConfigManager.save(cfg);
      expect(saved, isTrue);

      final reloaded = ConfigManager.load();
      expect(reloaded.stereoWidenMax, 0.80);

      // 恢复默认
      final reset = ConfigManager.resetToDefaults();
      expect(reset.stereoWidenMax, 0.75);
    });
  });

  group('PresetLibrary v2 & Factory Presets Tests', () {
    test('Factory presets are auto-initialized and available', () {
      final presets = PresetLibrary.listAll();
      final factoryPresets = presets.where((p) => p.isFactory).toList();

      expect(factoryPresets.length, greaterThanOrEqualTo(6));
      final names = factoryPresets.map((p) => p.name).toList();
      expect(names, contains('Pop Vocal Clarity'));
      expect(names, contains('Rock Bass Impact'));
      expect(names, contains('Symphonic Concert Hall'));
      expect(names, contains('Vintage Vinyl Tube'));
      expect(names, contains('V-Shape Smile Hi-Fi'));
      expect(names, contains('Studio Flat Monitor'));
    });

    test('Factory presets cannot be deleted', () {
      final factoryPresets =
          PresetLibrary.listAll().where((p) => p.isFactory).toList();
      expect(factoryPresets.isNotEmpty, isTrue);

      final target = factoryPresets.first;
      final result = PresetLibrary.deletePreset(target);
      expect(result, isFalse); // 出厂预设只读受保护
    });

    test('User preset save, list, export, import, and delete cycle', () {
      final userPreset = AuraPreset(
        schemaVersion: 2,
        name: 'Unit_Test_Preset_Alpha',
        category: 'Test',
        description: 'Automated test preset',
        author: 'Tester',
        createdAt: DateTime.now().toIso8601String(),
        isFactory: false,
        params: {
          'bass': {'enable': true, 'intensity': 0.75},
          'tube': {'enable': true, 'gain': 5.0},
          'eq': {'bandsCount': 10, 'presetName': 'rock'},
        },
      );

      // 1. 保存用户预设
      final saved = PresetLibrary.saveUserPreset(userPreset);
      expect(saved, isTrue);

      // 2. 列出并确认存在
      final all = PresetLibrary.listAll();
      final found = all.where((p) => p.name == 'Unit_Test_Preset_Alpha').toList();
      expect(found.isNotEmpty, isTrue);
      expect(found.first.isFactory, isFalse);

      // 3. 导出到临时文件
      final tmpExport = '${Directory.systemTemp.path}${Platform.pathSeparator}alpha_export.json';
      final exported = PresetLibrary.exportToFile(found.first, tmpExport);
      expect(exported, isTrue);
      expect(File(tmpExport).existsSync(), isTrue);

      // 4. 从临时文件导入
      final imported = PresetLibrary.importFromFile(tmpExport);
      expect(imported, isNotNull);
      expect(imported!.name, 'Unit_Test_Preset_Alpha');

      // 5. 删除用户预设
      final deleted = PresetLibrary.deletePreset(found.first);
      expect(deleted, isTrue);

      // 清理临时文件
      try {
        File(tmpExport).deleteSync();
      } catch (_) {}
    });
  });

  group('SessionMemory Tests', () {
    test('SessionMemory file path is well-formed', () {
      expect(SessionMemory.sessionPath, contains('session_state.json'));
    });
  });
}
