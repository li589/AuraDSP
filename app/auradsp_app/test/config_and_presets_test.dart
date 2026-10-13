import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/session_memory.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/features/liveprog_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig & ConfigManager Tests', () {
    test('Default AppConfig matches specification', () {
      final cfg = AppConfig();
      expect(cfg.sampleRate, 48000);
      expect(cfg.maxBlockFrames, 1024);
      expect(cfg.stereoWidenMax, 0.75);
      expect(cfg.vizFps, AppConfig.defaultVizFps);
      expect(cfg.autoRestoreSession, isTrue);
    });

    test('AppConfig JSON round-trip preserves all values', () {
      final original = AppConfig(
        sampleRate: 96000,
        maxBlockFrames: 2048,
        stereoWidenMax: 0.85,
        vizFps: 60,
        vizFftSize: 8192,
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

    test('flutter test runs sandboxed, never touches the real user dir', () {
      // 前提：flutter test 进程自带 FLUTTER_TEST=true（§13.4.26 根治）。
      // 若此断言失败，说明运行环境变了，沙箱承诺即失效。
      expect(Platform.environment['FLUTTER_TEST'], 'true');
      // 沙箱必须落在系统临时目录，而非真实 %APPDATA%/AuraDSP。
      expect(ConfigManager.baseDir.startsWith(Directory.systemTemp.path),
          isTrue);
      expect(SessionMemory.sessionPath.startsWith(ConfigManager.baseDir),
          isTrue);
      // 显式覆盖仍优先（plugin_manager_test 依赖此语义），且可恢复回沙箱。
      final sandbox = ConfigManager.baseDir;
      ConfigManager.baseDirOverride = Directory.systemTemp.path;
      expect(ConfigManager.baseDir, Directory.systemTemp.path);
      ConfigManager.baseDirOverride = null;
      expect(ConfigManager.baseDir.startsWith(Directory.systemTemp.path),
          isTrue);
      expect(ConfigManager.baseDir, isNot(Directory.systemTemp.path));
      expect(ConfigManager.baseDir, isNot(sandbox));
    });

    test('v2 config migrates vizFps to the render-friendly default', () {
      final prev = ConfigManager.baseDir;
      final dir = Directory.systemTemp.createTempSync('auradsp_cfgmig_');
      ConfigManager.baseDirOverride = dir.path;
      try {
        File(ConfigManager.configPath)
            .writeAsStringSync('{"version":2,"audio":{"vizFps":30}}');
        final cfg = ConfigManager.load();
        expect(cfg.vizFps, AppConfig.defaultVizFps);
        // 迁移后落盘为 v3，避免每次启动重复迁移
        expect(File(ConfigManager.configPath).readAsStringSync(),
            contains('"version": 3'));
      } finally {
        ConfigManager.baseDirOverride = prev;
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
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

  group('Liveprog v2: 会话/预设带回使能与滑块', () {
    test('snapshot 携带 liveprog{enabled,params,codeHash}（schemaVersion 3）',
        () {
      final m = AppModel();
      m.lpEnabled = true;
      m.lpParams[0] = 0.7;
      m.lpCode = '@init\nx = 1;\n@sample\nspl0 = 1;\n';
      final snap = PresetLibrary.snapshot(m, name: '__lp__');
      expect(snap.schemaVersion, 3);
      final lp = snap.params['liveprog'] as Map<String, dynamic>;
      expect(lp['enabled'], isTrue);
      expect((lp['params'] as List)[0], closeTo(0.7, 1e-9));
      expect((lp['codeHash'] as String).isNotEmpty, isTrue);
    });

    test('apply 恢复使能与滑块；指纹一致 → mismatch 为 false', () {
      final m = AppModel();
      const code = '@init\nx = 1;\n@sample\nspl0 = 1;\n';
      m.lpCode = code;
      final src = AppModel()
        ..lpCode = code
        ..lpEnabled = true;
      src.lpParams[2] = 0.5;
      final snap = PresetLibrary.snapshot(src, name: '__lp_src__');
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__lp_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.lpEnabled, isTrue);
      expect(m.lpParams[2], closeTo(0.5, 1e-9));
      expect(m.lpPresetCodeMismatch, isFalse);
    });

    test('apply 时编辑器代码与存档不一致 → mismatch 为 true', () {
      final m = AppModel()..lpCode = '@init\ny = 2;\n@sample\nspl0 = 1;\n';
      final preset = AuraPreset(
        name: '__lp_mismatch__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'liveprog': {
            'enabled': true,
            'params': List<double>.filled(8, 0.0),
            'codeHash': 'deadbeef',
          },
        },
      );
      PresetLibrary.apply(m, preset);
      expect(m.lpEnabled, isTrue);
      expect(m.lpPresetCodeMismatch, isTrue);
    });

    test('无 liveprog 节的老预设不碰脚本态', () {
      final m = AppModel()
        ..lpEnabled = true
        ..lpCode = 'keepme';
      m.lpParams[0] = 0.9;
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__legacy__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 1.0, 'limiterEnable': true},
              }));
      expect(m.lpEnabled, isTrue);
      expect(m.lpCode, 'keepme');
      expect(m.lpParams[0], closeTo(0.9, 1e-9));
    });

    test('setLiveprogCode 采纳声明默认值；同签名重应用保留用户值', () {
      final m = AppModel();
      const code = 'slider1:1.5<0,2,0.01>vol\n@init\nx = 1;\n@sample\n'
          'spl0 *= slider1;\n';
      m.setLiveprogCode(code);
      expect(m.lpParams[0], closeTo(1.5, 1e-9));
      // 用户把滑块拉到 0.2 后只改注释重应用 → 保留用户值
      m.setLiveprogParam(0, 0.2);
      m.setLiveprogCode('$code// touched\n');
      expect(m.lpParams[0], closeTo(0.2, 1e-9));
      // 声明变化 → 采纳新默认值
      m.setLiveprogCode(code.replaceFirst('slider1:1.5', 'slider1:0.8'));
      expect(m.lpParams[0], closeTo(0.8, 1e-9));
    });

    test('unload 保留 lpCode，只关使能', () {
      final m = AppModel()
        ..lpEnabled = true
        ..lpCode = 'keepme'
        ..lpStatus = 1;
      m.unloadLiveprog();
      expect(m.lpEnabled, isFalse);
      expect(m.lpStatus, 0);
      expect(m.lpCode, 'keepme');
    });
  });

  group('Liveprog v3: 脚本入口 FileGate L1', () {
    Directory makeTempDir() =>
        Directory.systemTemp.createTempSync('auradsp_lp_gate_');

    test('gateCheck：正常放行，超限/坏编码隔离', () {
      final d = makeTempDir();
      try {
        final ok = File('${d.path}${Platform.pathSeparator}a.eel')
          ..writeAsStringSync('@init\nx = 1;\n@sample\nspl0 = 1;\n');
        expect(LiveprogLibrary.gateCheck(ok), isNull);

        final big = File('${d.path}${Platform.pathSeparator}big.eel')
          ..writeAsBytesSync(List<int>.filled(
              LiveprogLibrary.maxScriptBytes + 1, 0x20));
        expect(LiveprogLibrary.gateCheck(big), 'tooLarge');

        final bad = File('${d.path}${Platform.pathSeparator}bad.eel')
          ..writeAsBytesSync([0xFF, 0xFE, 0x00, 0x41]);
        expect(LiveprogLibrary.gateCheck(bad), 'unreadable');
      } finally {
        d.deleteSync(recursive: true);
      }
    });

    test('listAll 跳过坏文件并计数，不中断整批', () {
      final d = makeTempDir();
      try {
        File('${d.path}${Platform.pathSeparator}good.eel')
            .writeAsStringSync('@init\nx = 1;\n@sample\nspl0 = 1;\n');
        File('${d.path}${Platform.pathSeparator}evil.eel')
            .writeAsBytesSync([0xFF, 0xFE]);
        final items = LiveprogLibrary.listAll([d.path]);
        expect(items.any((e) => e.name == 'good.eel'), isTrue);
        expect(items.any((e) => e.name == 'evil.eel'), isFalse);
        expect(LiveprogLibrary.lastSkipped, 1);
      } finally {
        d.deleteSync(recursive: true);
      }
    });

    test('deletePath：库外拒绝，库内删除，不存在幂等成功', () {
      final d = makeTempDir();
      try {
        // 库外路径一律拒绝
        expect(
            LiveprogLibrary.deletePath(
                '${d.path}${Platform.pathSeparator}x.eel', []),
            isFalse);
        // 库内（登记为外部目录）可删
        final f = File('${d.path}${Platform.pathSeparator}y.eel')
          ..writeAsStringSync('x');
        expect(LiveprogLibrary.deletePath(f.path, [d.path]), isTrue);
        expect(f.existsSync(), isFalse);
        // 不存在视为成功
        expect(LiveprogLibrary.deletePath(f.path, [d.path]), isTrue);
      } finally {
        d.deleteSync(recursive: true);
      }
    });

    test('renamePath：遍历名拒绝，同目录先写后删，目标存在拒绝', () {
      final d = makeTempDir();
      try {
        final old = File('${d.path}${Platform.pathSeparator}a.eel')
          ..writeAsStringSync('@init\nx = 1;\n@sample\nspl0 = 1;\n');
        expect(
            LiveprogLibrary.renamePath(old.path, '../evil.eel', [d.path]),
            isFalse);
        expect(old.existsSync(), isTrue);
        expect(
            LiveprogLibrary.renamePath(old.path, 'b.eel', [d.path]), isTrue);
        expect(old.existsSync(), isFalse);
        expect(
            File('${d.path}${Platform.pathSeparator}b.eel').existsSync(),
            isTrue);
        // 目标已存在 → 拒绝（调用方弹覆盖确认，不静默覆盖）
        final c = File('${d.path}${Platform.pathSeparator}c.eel')
          ..writeAsStringSync('c');
        expect(
            LiveprogLibrary.renamePath(
                '${d.path}${Platform.pathSeparator}b.eel', 'c.eel', [d.path]),
            isFalse);
        expect(c.readAsStringSync(), 'c');
      } finally {
        d.deleteSync(recursive: true);
      }
    });
  });

  group('BassMono: 低频单声道化', () {
    test('默认值：关闭 + 120Hz', () {
      final m = AppModel();
      expect(m.bassmonoOn, isFalse);
      expect(m.bassmonoFreq, closeTo(120.0, 1e-9));
      expect(m.isStageEnabled('bassmono'), isFalse);
    });

    test('分频点钳位 20~300Hz', () {
      final m = AppModel();
      m.setBassmonoFreq(10);
      expect(m.bassmonoFreq, closeTo(20.0, 1e-9));
      m.setBassmonoFreq(500);
      expect(m.bassmonoFreq, closeTo(300.0, 1e-9));
      m.setBassmonoFreq(80);
      expect(m.bassmonoFreq, closeTo(80.0, 1e-9));
    });

    test('toggleStage 翻转独立开关位', () {
      final m = AppModel();
      m.toggleStage('bassmono');
      expect(m.bassmonoOn, isTrue);
      m.toggleStage('bassmono');
      expect(m.bassmonoOn, isFalse);
    });

    test('snapshot/apply 对称恢复使能与分频点', () {
      final src = AppModel()
        ..setBassmonoEnabled(true)
        ..setBassmonoFreq(200);
      final snap = PresetLibrary.snapshot(src, name: '__bm__');
      final bm = snap.params['bassmono'] as Map<String, dynamic>;
      expect(bm['enable'], isTrue);
      expect((bm['freq'] as num).toDouble(), closeTo(200.0, 1e-9));

      final m = AppModel();
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__bm_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.bassmonoOn, isTrue);
      expect(m.bassmonoFreq, closeTo(200.0, 1e-9));
    });

    test('无 bassmono 节的老预设不碰开关', () {
      final m = AppModel()..setBassmonoEnabled(true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__legacy__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 0.0, 'limiterEnable': true},
              }));
      expect(m.bassmonoOn, isTrue);
    });
  });

  group('Haas: 差分环绕', () {
    test('默认值：关闭 + 12ms + 全湿', () {
      final m = AppModel();
      expect(m.haasOn, isFalse);
      expect(m.haasDelayMs, closeTo(12.0, 1e-9));
      expect(m.haasMix, closeTo(1.0, 1e-9));
      expect(m.isStageEnabled('haas'), isFalse);
    });

    test('延迟/混合钳位', () {
      final m = AppModel();
      m.setHaasDelay(-5);
      expect(m.haasDelayMs, closeTo(0.0, 1e-9));
      m.setHaasDelay(40);
      expect(m.haasDelayMs, closeTo(25.0, 1e-9));
      m.setHaasMix(1.5);
      expect(m.haasMix, closeTo(1.0, 1e-9));
      m.setHaasMix(-0.5);
      expect(m.haasMix, closeTo(0.0, 1e-9));
    });

    test('toggleStage 翻转独立开关位', () {
      final m = AppModel();
      m.toggleStage('haas');
      expect(m.haasOn, isTrue);
      m.toggleStage('haas');
      expect(m.haasOn, isFalse);
    });

    test('snapshot/apply 对称恢复三字段', () {
      final src = AppModel()
        ..setHaasEnabled(true)
        ..setHaasDelay(8)
        ..setHaasMix(0.6);
      final snap = PresetLibrary.snapshot(src, name: '__hs__');
      final hs = snap.params['haas'] as Map<String, dynamic>;
      expect(hs['enable'], isTrue);
      expect((hs['delay'] as num).toDouble(), closeTo(8.0, 1e-9));
      expect((hs['mix'] as num).toDouble(), closeTo(0.6, 1e-9));

      final m = AppModel();
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__hs_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.haasOn, isTrue);
      expect(m.haasDelayMs, closeTo(8.0, 1e-9));
      expect(m.haasMix, closeTo(0.6, 1e-9));
    });

    test('延迟侧切换：setHaasSide 归一 0/1 且快照恢复', () {
      final m = AppModel();
      expect(m.haasSide, 0);
      m.setHaasSide(1);
      expect(m.haasSide, 1);
      m.setHaasSide(9);
      expect(m.haasSide, 1);
      m.setHaasSide(0);
      expect(m.haasSide, 0);

      final src = AppModel()
        ..setHaasEnabled(true)
        ..setHaasSide(1);
      final snap = PresetLibrary.snapshot(src, name: '__hs_side__');
      final hs = snap.params['haas'] as Map<String, dynamic>;
      expect(hs['side'], 1);

      final m2 = AppModel();
      PresetLibrary.apply(
          m2,
          AuraPreset(
              name: '__hs_side_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m2.haasSide, 1);
    });

    test('延迟标称随设定值走（底栏/徽标用）', () {
      final m = AppModel()
        ..setHaasEnabled(true)
        ..setHaasDelay(15);
      expect(m.componentLatency('haas').ms, closeTo(15.0, 1e-9));
      m.setHaasEnabled(false);
      expect(m.componentLatency('haas').ms, closeTo(0.0, 1e-9));
    });
  });

  group('Exciter: 激励器', () {
    test('默认值：关闭 + 0.3 + 5kHz', () {
      final m = AppModel();
      expect(m.exciterOn, isFalse);
      expect(m.exciterAmount, closeTo(0.3, 1e-9));
      expect(m.exciterHifreq, closeTo(5000.0, 1e-9));
      expect(m.isStageEnabled('exciter'), isFalse);
    });

    test('量/分频钳位', () {
      final m = AppModel();
      m.setExciterAmount(2.0);
      expect(m.exciterAmount, closeTo(1.0, 1e-9));
      m.setExciterAmount(-1.0);
      expect(m.exciterAmount, closeTo(0.0, 1e-9));
      m.setExciterHifreq(1000);
      expect(m.exciterHifreq, closeTo(3000.0, 1e-9));
      m.setExciterHifreq(20000);
      expect(m.exciterHifreq, closeTo(10000.0, 1e-9));
    });

    test('toggleStage 翻转独立开关位', () {
      final m = AppModel();
      m.toggleStage('exciter');
      expect(m.exciterOn, isTrue);
      m.toggleStage('exciter');
      expect(m.exciterOn, isFalse);
    });

    test('snapshot/apply 对称恢复三字段', () {
      final src = AppModel()
        ..setExciterEnabled(true)
        ..setExciterAmount(0.7)
        ..setExciterHifreq(8000);
      final snap = PresetLibrary.snapshot(src, name: '__ex__');
      final ex = snap.params['exciter'] as Map<String, dynamic>;
      expect(ex['enable'], isTrue);
      expect((ex['amount'] as num).toDouble(), closeTo(0.7, 1e-9));
      expect((ex['hifreq'] as num).toDouble(), closeTo(8000.0, 1e-9));

      final m = AppModel();
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__ex_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.exciterOn, isTrue);
      expect(m.exciterAmount, closeTo(0.7, 1e-9));
      expect(m.exciterHifreq, closeTo(8000.0, 1e-9));
    });

    test('无 exciter 节的老预设不碰开关', () {
      final m = AppModel()..setExciterEnabled(true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__legacy__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 0.0, 'limiterEnable': true},
              }));
      expect(m.exciterOn, isTrue);
    });
  });

  group('P-010: 每效果输出增益门 + 自动补偿', () {
    test('setter 下发引擎参数（镜像闭环）', () {
      final m = AppModel();
      // setBassOutputGain 走 setFloat → mirror 回写同一字段
      m.setBassOutputGain(6.0);
      expect(m.bassOutputGain, closeTo(6.0, 1e-9));
      m.setBassOutputGain(99.0);
      expect(m.bassOutputGain, closeTo(6.0, 1e-9)); // 钳位 [-12,6]
      m.setBassOutputGain(-99.0);
      expect(m.bassOutputGain, closeTo(-12.0, 1e-9));
      m.setBassAutoGain(true);
      expect(m.bassAutoGain, isTrue);
    });

    test('五效果全部有独立字段与钳位', () {
      final m = AppModel();
      for (final setter in [
        (double v) => m.setEqOutputGain(v),
        (double v) => m.setTubeOutputGain(v),
        (double v) => m.setCompOutputGain(v),
        (double v) => m.setReverbOutputGain(v),
      ]) {
        setter(9.0);
      }
      expect(m.eqOutputGain, closeTo(6.0, 1e-9));
      expect(m.tubeOutputGain, closeTo(6.0, 1e-9));
      expect(m.compOutputGain, closeTo(6.0, 1e-9));
      expect(m.reverbOutputGain, closeTo(6.0, 1e-9));
    });

    test('arbmag 有独立字段与钳位', () {
      final m = AppModel();
      m.setArbmagOutputGain(12.0);
      expect(m.arbmagOutputGain, closeTo(6.0, 1e-9));
      m.setArbmagOutputGain(-20.0);
      expect(m.arbmagOutputGain, closeTo(-12.0, 1e-9));
      m.setArbmagAutoGain(true);
      expect(m.arbmagAutoGain, isTrue);
    });

    test('snapshot/apply 对称恢复 autoGain + outputGain', () {
      final src = AppModel()
        ..setBassAutoGain(true)
        ..setBassOutputGain(4.5)
        ..setEqAutoGain(true)
        ..setEqOutputGain(-3.0)
        ..setArbmagAutoGain(true)
        ..setArbmagOutputGain(-1.5)
        ..setArbmagString('GraphicEQ: 20 0; 20000 0');
      final snap = PresetLibrary.snapshot(src, name: '__ag__');
      final bass = snap.params['bass'] as Map<String, dynamic>;
      expect(bass['autoGain'], isTrue);
      expect((bass['outputGain'] as num).toDouble(), closeTo(4.5, 1e-9));

      final arb = snap.params['arbmag'] as Map<String, dynamic>;
      expect(arb['autoGain'], isTrue);
      expect((arb['outputGain'] as num).toDouble(), closeTo(-1.5, 1e-9));
      expect(arb['string'], 'GraphicEQ: 20 0; 20000 0');

      final m = AppModel();
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__ag_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.bassAutoGain, isTrue);
      expect(m.bassOutputGain, closeTo(4.5, 1e-9));
      expect(m.eqAutoGain, isTrue);
      expect(m.eqOutputGain, closeTo(-3.0, 1e-9));
      expect(m.arbmagAutoGain, isTrue);
      expect(m.arbmagOutputGain, closeTo(-1.5, 1e-9));
      expect(m.arbmagString, 'GraphicEQ: 20 0; 20000 0');
    });

    test('Crossfeed: 默认值、模式联动与自定义分频/衰减', () {
      final m = AppModel();
      expect(m.xfeedOn, isFalse);
      expect(m.xfeedMode, 0);
      expect(m.xfeedFcut, closeTo(700.0, 1e-9));
      expect(m.xfeedFeed, closeTo(4.5, 1e-9));

      // 切换 Chu Moy 预设
      m.setCrossfeedMode(1);
      expect(m.xfeedMode, 1);
      expect(m.xfeedFcut, closeTo(700.0, 1e-9));
      expect(m.xfeedFeed, closeTo(6.0, 1e-9));

      // 切换 Jan Meier 预设
      m.setCrossfeedMode(2);
      expect(m.xfeedMode, 2);
      expect(m.xfeedFcut, closeTo(650.0, 1e-9));
      expect(m.xfeedFeed, closeTo(9.5, 1e-9));

      // 自定义分频点与馈送量，联动切为自定义模式 3
      m.setCrossfeedFcut(800.0);
      expect(m.xfeedMode, 3);
      expect(m.xfeedFcut, closeTo(800.0, 1e-9));

      m.setCrossfeedFeed(7.5);
      expect(m.xfeedMode, 3);
      expect(m.xfeedFeed, closeTo(7.5, 1e-9));

      // 验证快照与恢复对称性
      m.setCrossfeedEnabled(true);
      final snap = PresetLibrary.snapshot(m, name: '__xf_snap__');
      final xf = snap.params['crossfeed'] as Map<String, dynamic>;
      expect(xf['enable'], isTrue);
      expect(xf['mode'], 3);
      expect(xf['fcut'], closeTo(800.0, 1e-9));
      expect(xf['feed'], closeTo(7.5, 1e-9));

      // 重置并恢复
      m.setCrossfeedMode(0);
      m.setCrossfeedEnabled(false);
      PresetLibrary.apply(m, snap);
      expect(m.xfeedOn, isTrue);
      expect(m.xfeedMode, 3);
      expect(m.xfeedFcut, closeTo(800.0, 1e-9));
      expect(m.xfeedFeed, closeTo(7.5, 1e-9));
    });

    test('SpatialReverb: setReverbCustomParam 调整干湿比不误关混响', () {
      final m = AppModel();
      m.selectReverbPreset(0); // 大音乐厅
      expect(m.isSpatialReverbOn, isTrue);

      // 用户拖动干湿比滑块
      m.setReverbCustomParam('wet', 0.6);
      expect(m.reverbPreset, -2); // 变为自定义模式
      expect(m.fvOn, isTrue);
      expect(m.fvWet, closeTo(0.6, 1e-9));
      expect(m.isSpatialReverbOn, isTrue); // 仍旧保持开启，绝不误关闭！
    });
  });

  group('Gate + Deesser', () {
    test('默认值', () {
      final m = AppModel();
      expect(m.gateOn, isFalse);
      expect(m.gateThreshold, closeTo(-40.0, 1e-9));
      expect(m.gateAttackMs, closeTo(10.0, 1e-9));
      expect(m.gateReleaseMs, closeTo(100.0, 1e-9));
      expect(m.gateAutoGain, isFalse);
      expect(m.deesserOn, isFalse);
      expect(m.deesserFreq, closeTo(6000.0, 1e-9));
      expect(m.deesserAmount, closeTo(0.5, 1e-9));
      expect(m.isStageEnabled('gate'), isFalse);
    });

    test('钳位', () {
      final m = AppModel();
      m.setGateThreshold(-100);
      expect(m.gateThreshold, closeTo(-60.0, 1e-9));
      m.setGateThreshold(10);
      expect(m.gateThreshold, closeTo(0.0, 1e-9));
      m.setGateAttack(0);
      expect(m.gateAttackMs, closeTo(1.0, 1e-9));
      m.setGateRelease(9999);
      expect(m.gateReleaseMs, closeTo(500.0, 1e-9));
      m.setDeesserFreq(100);
      expect(m.deesserFreq, closeTo(2000.0, 1e-9));
      m.setDeesserAmount(5);
      expect(m.deesserAmount, closeTo(1.0, 1e-9));
    });

    test('toggleStage 翻转 gate', () {
      final m = AppModel();
      m.toggleStage('gate');
      expect(m.gateOn, isTrue);
      expect(m.isStageEnabled('gate'), isTrue);
      m.toggleStage('gate');
      expect(m.gateOn, isFalse);
    });

    test('snapshot/apply 对称恢复 gate + deesser', () {
      final src = AppModel()
        ..setGateEnabled(true)
        ..setGateThreshold(-35)
        ..setGateAttack(20)
        ..setGateRelease(200)
        ..setGateAutoGain(true)
        ..setDeesserEnabled(true)
        ..setDeesserFreq(7500)
        ..setDeesserAmount(0.8);
      final snap = PresetLibrary.snapshot(src, name: '__gate__');
      final g = snap.params['gate'] as Map<String, dynamic>;
      expect(g['enable'], isTrue);
      expect((g['threshold'] as num).toDouble(), closeTo(-35.0, 1e-9));
      expect(g['autoGain'], isTrue);
      final d = snap.params['deesser'] as Map<String, dynamic>;
      expect(d['enable'], isTrue);
      expect((d['freq'] as num).toDouble(), closeTo(7500.0, 1e-9));

      final m = AppModel();
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__gate_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.gateOn, isTrue);
      expect(m.gateThreshold, closeTo(-35.0, 1e-9));
      expect(m.gateReleaseMs, closeTo(200.0, 1e-9));
      expect(m.gateAutoGain, isTrue);
      expect(m.deesserOn, isTrue);
      expect(m.deesserFreq, closeTo(7500.0, 1e-9));
      expect(m.deesserAmount, closeTo(0.8, 1e-9));
    });
  });

  group('Bass v3.1: ViPER 三模式 + 心理声学接线', () {
    test('mode 宏写入谐波配方（不再碰 shelf）', () {
      final m = AppModel();
      m.setBassMode(1);
      expect(m.bassMode, 1);
      expect(m.bassHarmonics, closeTo(0.35, 1e-9));
      expect(m.bassHarmonicBlend, closeTo(0.5, 1e-9));
      m.setBassMode(2);
      expect(m.bassHarmonics, closeTo(0.7, 1e-9));
      expect(m.bassHarmonicBlend, closeTo(0.7, 1e-9));
      m.setBassMode(0);
      expect(m.bassHarmonics, closeTo(0.0, 1e-9));
    });

    test('谐波三滑块下发引擎（不再是死控件）', () {
      final m = AppModel();
      m.setBassHarmonics(0.6);
      expect(m.bassHarmonics, closeTo(0.6, 1e-9));
      m.setBassHarmonicBlend(0.4);
      expect(m.bassHarmonicBlend, closeTo(0.4, 1e-9));
      m.setBassSubFloor(15);
      expect(m.bassSubFloor, closeTo(15.0, 1e-9));
      m.setBassCutoff(200);
      expect(m.bassCutoff, closeTo(200.0, 1e-9));
    });

    test('snapshot/apply 对称（含谐波三件套）', () {
      final src = AppModel()
        ..setBassMode(2)
        ..setBassIntensity(0.6)
        ..setBassCutoff(140)
        ..setBassHarmonics(0.75)
        ..setBassHarmonicBlend(0.65)
        ..setBassSubFloor(20);
      final snap = PresetLibrary.snapshot(src, name: '__bass31__');
      final b = snap.params['bass'] as Map<String, dynamic>;
      expect(b['mode'], 2);
      expect((b['harmonics'] as num).toDouble(), closeTo(0.75, 1e-9));

      final m = AppModel();
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__bass31_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.bassMode, 2);
      expect(m.bassHarmonics, closeTo(0.75, 1e-9));
      expect(m.bassHarmonicBlend, closeTo(0.65, 1e-9));
      expect(m.bassSubFloor, closeTo(20.0, 1e-9));
    });
  });

  group('Filter: 独立滤波器', () {
    test('默认值 + 钳位 + 开关', () {
      final m = AppModel();
      expect(m.filterOn, isFalse);
      expect(m.filterType, 0);
      expect(m.filterFreq, closeTo(80.0, 1e-9));
      expect(m.filterQ, closeTo(0.707, 1e-9));
      m.setFilterType(9);
      expect(m.filterType, 2);
      m.setFilterFreq(1);
      expect(m.filterFreq, closeTo(20.0, 1e-9));
      m.setFilterQ(99);
      expect(m.filterQ, closeTo(10.0, 1e-9));
      m.toggleStage('filter');
      expect(m.filterOn, isTrue);
      expect(m.isStageEnabled('filter'), isTrue);
    });

    test('snapshot/apply 对称', () {
      final src = AppModel()
        ..setFilterEnabled(true)
        ..setFilterType(1)
        ..setFilterFreq(200)
        ..setFilterQ(1.0);
      final snap = PresetLibrary.snapshot(src, name: '__ft__');
      final f = snap.params['filter'] as Map<String, dynamic>;
      expect(f['enable'], isTrue);
      expect(f['type'], 1);

      final m = AppModel();
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__ft_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.filterOn, isTrue);
      expect(m.filterType, 1);
      expect(m.filterFreq, closeTo(200.0, 1e-9));
      expect(m.filterQ, closeTo(1.0, 1e-9));
    });
  });
}

