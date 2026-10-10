import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/session_memory.dart';
import 'package:auradsp_app/core/state.dart';
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

  // ---------------------------------------------------------------------
  // 回归测试：以下三条对应已修复的高危缺陷，删除任一会让缺陷复活。
  // ---------------------------------------------------------------------
  group('Regressions: stereo band mirror / preset apply symmetry / EQ curve push', () {
    test('stereo.bandN 镜像生效（正则必须以裸美元符收尾，不能写成反斜杠转义）', () {
      final m = AppModel();
      // 修复前：RegExp(r'^stereo\.band([1-5])\$') 匹配的是字面美元符，
      // 于是 stereoBands 永不更新、stereoBandUsed 永远 false。
      expect(m.stereoBandUsed, isFalse);
      m.setFloat('stereo.band1', 0.8);
      expect(m.stereoBands[0], closeTo(0.8, 1e-9));
      expect(m.stereoBandUsed, isTrue);
      m.setFloat('stereo.band5', 0.25);
      expect(m.stereoBands[4], closeTo(0.25, 1e-9));

      // 不应误伤其它同族 id
      m.setFloat('post.gain', 1.5);
      expect(m.postGain, closeTo(1.5, 1e-9));
    });

    test('apply() 读回 snapshot 写出的全部区块（shelf/convolver/ddc/crossfeed）', () {
      final m = AppModel();
      // 先把四个效果全部打开，模拟"用户当前开着这些效果"
      m.setInt('shelf.enable', 1);
      m.setInt('convolver.enable', 1);
      m.setInt('ddc.enable', 1);
      m.setInt('crossfeed.enable', 1);
      m.setFloat('shelf.freq', 80.0);
      m.setFloat('shelf.gain', 6.0);
      expect(m.shelfOn, isTrue);

      final preset = AuraPreset(
        name: '__regress_flat__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'shelf': {'enable': false, 'freq': 120.0, 'gain': 0.0},
          'convolver': {'enable': false, 'mix': 0.4},
          'ddc': {'enable': false},
          'crossfeed': {'enable': false},
        },
      );
      PresetLibrary.apply(m, preset);

      // 修复前 apply() 完全不读这四节 → 上面打开的效果全部保持开启，
      // "平直监听"预设关不掉搁架。
      expect(m.shelfOn, isFalse);
      expect(m.shelfFreq, closeTo(120.0, 1e-9));
      expect(m.shelfGain, closeTo(0.0, 1e-9));
      expect(m.convEnabled, isFalse);
      expect(m.convMix, closeTo(0.4, 1e-9));
      expect(m.ddcOn, isFalse);
      expect(m.xfeedOn, isFalse);
    });

    test('apply() 后 eqGains 真正落到 model（裸字段赋值不再吞掉增益）', () {
      final m = AppModel();
      final gains = List<double>.filled(15, 0.0);
      gains[0] = -6.0;
      gains[7] = 9.0;
      gains[14] = 3.0;
      final preset = AuraPreset(
        name: '__regress_eq__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'eq': {'bandsCount': 15, 'q': 1.414, 'gains': gains, 'enable': true},
        },
      );
      PresetLibrary.apply(m, preset);
      expect(m.eqGains[0], closeTo(-6.0, 1e-9));
      expect(m.eqGains[7], closeTo(9.0, 1e-9));
      expect(m.eqGains[14], closeTo(3.0, 1e-9));
    });
  });
}
