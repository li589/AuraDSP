import 'dart:io';

import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/session_memory.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/features/liveprog_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 出厂预设/默认基线资产预载：让全文件走生产语义（apply 全量复写）。
  setUpAll(() async {
    await PresetLibrary.preloadFactoryAssets();
  });

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

    test('守护：apply() 写 activePresetName（预设高亮依赖），会话回放不得污染成 __restored__', () {
      final m = AppModel(testing: true);
      expect(m.activePresetName, isNull);
      final snap = PresetLibrary.snapshot(m, name: '__pollution_probe__');
      PresetLibrary.apply(m, snap);
      // apply 的副作用契约：成功应用后记住预设名，效果页据此高亮。
      expect(m.activePresetName, '__pollution_probe__');

      // 会话恢复路径：restoreMemoryImage 借道名为 '__restored__' 的哑预设，
      // 但最后必须把名字还原成会话里存的那个（否则启动后预设高亮永远不命中）。
      final m2 = AppModel(testing: true);
      m2.activePresetName = 'My_Night_Mode';
      expect(SessionMemory.save(m2), isTrue);
      final session = SessionMemory.load()!;
      final m3 = AppModel(testing: true);
      SessionMemory.restoreMemoryImage(m3, session);
      expect(m3.activePresetName, 'My_Night_Mode',
          reason: 'restoreMemoryImage 必须绕开 apply 的 activePresetName 污染');
    });

    test('守护：音频引擎选择随会话记忆（四种 Windows 模式 round-trip）', () {
      for (final mode in AudioModes.windows) {
        final m = AppModel(testing: true);
        m.audioMode = mode;
        m.config.audioMode = mode;
        expect(SessionMemory.save(m), isTrue, reason: 'mode=$mode');
        final session = SessionMemory.load()!;
        expect(session['audioMode'], mode, reason: 'mode=$mode');
        final m2 = AppModel(testing: true);
        SessionMemory.restoreMemoryImage(m2, session);
        expect(m2.audioMode, AudioModes.normalize(mode),
            reason: 'mode=$mode 重启后必须回到关闭前选择的引擎');
      }
    });

    test('守护：测试音状态不落盘（关闭前开着 440Hz，重启必须默认关闭）', () {
      final m = AppModel(testing: true);
      m.setSource('tone');
      expect(m.sourceKind, 'tone');
      expect(m.playing, isTrue);
      expect(SessionMemory.save(m), isTrue);
      final payload = File(SessionMemory.sessionPath).readAsStringSync();
      // 载荷里不得出现测试音状态：sourceKind 不在序列化集，'tone' 值也不得出现
      expect(payload.contains('sourceKind'), isFalse);
      expect(payload.contains('"tone"'), isFalse);
      // 重启路径双保险：restore 后 playing/sourceKind 保持全新安装默认
      final m2 = AppModel(testing: true);
      SessionMemory.restoreMemoryImage(m2, SessionMemory.load()!);
      expect(m2.playing, isFalse);
      expect(m2.sourceKind, '');
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

  group('Preset dirty tracking：偏离即自定义/未保存（2026-10-16 决策 #3）', () {
    test('apply 后不脏；任意一点偏离 → evaluatePresetDirty 翻 true', () {
      final m = AppModel(testing: true);
      final snap = PresetLibrary.snapshot(m, name: '__dirty_base__');
      PresetLibrary.apply(m, snap);
      expect(m.activePresetName, '__dirty_base__');
      expect(m.appliedPresetFingerprint, isNotNull);
      expect(m.evaluatePresetDirty(), isFalse);
      expect(m.presetDirty, isFalse);

      // 一点偏离（单个滑块）即脏
      m.setFloat('post.gain', 1.25);
      expect(m.evaluatePresetDirty(), isTrue);
      expect(m.presetDirty, isTrue);
    });

    test('saveAsUserPreset 保存即锚定：脏标记归零，再偏离又脏', () {
      final m = AppModel(testing: true);
      final snap = PresetLibrary.snapshot(m, name: '__dirty_base__');
      PresetLibrary.apply(m, snap);
      m.setFloat('post.gain', 1.25);
      expect(m.evaluatePresetDirty(), isTrue);

      final prev = ConfigManager.baseDir;
      final dir = Directory.systemTemp.createTempSync('auradsp_dirty_');
      ConfigManager.baseDirOverride = dir.path;
      try {
        expect(m.saveAsUserPreset('My_Custom_1'), isTrue);
      } finally {
        ConfigManager.baseDirOverride = prev;
      }
      expect(m.presetDirty, isFalse);
      expect(m.appliedPresetFingerprint, PresetLibrary.fingerprintOf(m),
          reason: '保存即锚定：锚点 = 当前状态');
      m.setFloat('post.gain', 2.0);
      expect(m.evaluatePresetDirty(), isTrue);
      try {
        Directory(dir.path).deleteSync(recursive: true);
      } catch (_) {}
    });

    test('SessionMemory v5：脏态与锚点随会话持久化，重启后仍是「未保存」', () {
      final prev = ConfigManager.baseDir;
      final dir = Directory.systemTemp.createTempSync('auradsp_dirty2_');
      ConfigManager.baseDirOverride = dir.path;
      try {
        final m = AppModel(testing: true);
        final snap = PresetLibrary.snapshot(m, name: '__dirty_v5__');
        PresetLibrary.apply(m, snap);
        m.setFloat('post.gain', 1.25);
        m.evaluatePresetDirty();
        expect(m.presetDirty, isTrue);
        final anchor = m.appliedPresetFingerprint;

        expect(SessionMemory.save(m), isTrue);
        final session = SessionMemory.load()!;
        expect(session['version'], 5);
        expect(session['presetDirty'], isTrue);
        expect(session['appliedPresetFingerprint'], anchor);

        // 模拟重启：全新模型回放会话
        final m2 = AppModel(testing: true);
        SessionMemory.restoreMemoryImage(m2, session);
        expect(m2.presetDirty, isTrue,
            reason: '未保存的自定义态重启后必须仍显示「未保存」');
        expect(m2.appliedPresetFingerprint, anchor);
        // 回放后的状态与原偏离状态一致 → 再评估仍脏（不是误报）
        expect(m2.evaluatePresetDirty(), isTrue);
      } finally {
        ConfigManager.baseDirOverride = prev;
        try {
          Directory(dir.path).deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('会话回放不误清脏态：restoreMemoryImage 用会话锚点覆盖 apply 的锚点', () {
      // 防回归：apply() 末尾会把指纹锚到回放后的状态（= 不脏），
      // restoreMemoryImage 必须随后用会话里存的锚点/脏标记覆盖。
      final prev = ConfigManager.baseDir;
      final dir = Directory.systemTemp.createTempSync('auradsp_dirty3_');
      ConfigManager.baseDirOverride = dir.path;
      try {
        final m = AppModel(testing: true);
        final snap = PresetLibrary.snapshot(m, name: '__dirty_v5__');
        PresetLibrary.apply(m, snap);
        m.setFloat('post.gain', 1.25);
        m.evaluatePresetDirty();
        SessionMemory.save(m);
        final session = SessionMemory.load()!;
        final anchor = session['appliedPresetFingerprint'] as String;
        expect(anchor, isNot(PresetLibrary.fingerprintOf(m)),
            reason: '偏离态的指纹必须不同于锚点');

        final m2 = AppModel(testing: true);
        SessionMemory.restoreMemoryImage(m2, session);
        expect(m2.appliedPresetFingerprint, anchor,
            reason: 'apply 在回放里把锚点改成了回放态指纹，必须被会话锚点覆盖');
      } finally {
        ConfigManager.baseDirOverride = prev;
        try {
          Directory(dir.path).deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('Readback: 防抖对账不变量（2026-10-16 决策 #4，源码形状钉住）', () {
    // _testing 构造不拉 isolate，功能断言不可达；与 E1 探针同一模式，
    // 以源码形状钉住三条不变量。
    test('scheduleAutoSave 的防抖回调 = 保存 + 回读，且编辑即盖 _lastEditAt', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final i = src.indexOf('void scheduleAutoSave() {');
      expect(i, greaterThan(-1), reason: '找不到 scheduleAutoSave 定义');
      final j = src.indexOf('\n  }', i);
      final body = src.substring(i, j);
      expect(body.contains('_lastEditAt'), isTrue,
          reason: '编辑即盖时间戳，回读过期判定的依据');
      expect(body.contains('SessionMemory.save'), isTrue);
      expect(body.contains('scheduleReadback()'), isTrue,
          reason: '风暴平息后必须回读对账（决策 #4）');
    });

    test('scheduleReadback 有 _testing/_isReplayingSession 短路 + 置 pending', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final i = src.indexOf('void scheduleReadback() {');
      expect(i, greaterThan(-1), reason: '找不到 scheduleReadback 定义');
      final j = src.indexOf('\n  }', i);
      final body = src.substring(i, j);
      expect(body.contains('_testing || _isReplayingSession'), isTrue,
          reason: '测试构造/会话回放不得发回读');
      expect(body.contains('_readbackPending = true'), isTrue);
      expect(body.contains("'getParams'"), isTrue);
    });

    test("'params' 分支顶部有过期守卫：编辑晚于回读发出 → 丢弃该轮", () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final i = src.indexOf("case 'params':");
      expect(i, greaterThan(-1));
      final body = src.substring(i, i + 700);
      final guard = body.indexOf('_readbackPending');
      expect(guard, greaterThan(-1), reason: '守卫必须位于分支顶部（采用任何引擎值之前）');
      expect(body.contains('_lastEditAt > _readbackRequestedAt'), isTrue);
      expect(body.indexOf('bassOn ='), greaterThan(guard),
          reason: '守卫必须在首次采用（bassOn =）之前');
    });
  });

  // ---------------------------------------------------------------------
  // 回归测试：以下三条对应已修复的高危缺陷，删除任一会让缺陷复活。
  // ---------------------------------------------------------------------
  group('Regressions: stereo band mirror / preset apply symmetry / EQ curve push', () {
    test('stereo.bandN 镜像生效（正则必须以裸美元符收尾，不能写成反斜杠转义）', () {
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
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

    test('apply() 对称读回 stereo.bandUsed（setStereoMix 副作用不得覆盖快照值）', () {
      // 方向一：用户调过分带 → 恢复后仍 true
      final m1 = AppModel(testing: true);
      m1.setStereoBand(2, 0.5);
      final snap1 = PresetLibrary.snapshot(m1, name: '__regress_band_used__');
      final t1 = AppModel(testing: true)..stereoBandUsed = false;
      PresetLibrary.apply(t1, snap1);
      expect(t1.stereoBandUsed, isTrue);
      expect(t1.stereoBands[2], closeTo(0.5, 1e-9));

      // 方向二：从未调过分带（bandUsed=false）→ 恢复后不得被强制置 true。
      // 修复前：apply 的 mix 分支调 setStereoMix，其副作用 bandUsed=true，
      // 而快照值无人读回 → 每个人都被切成 per-band 展宽模式，
      // 与全新安装（bandUsed=false）行为不一致。
      final m2 = AppModel(testing: true);
      expect(m2.stereoBandUsed, isFalse);
      final snap2 = PresetLibrary.snapshot(m2, name: '__regress_band_unused__');
      final t2 = AppModel(testing: true)..stereoBandUsed = true;
      PresetLibrary.apply(t2, snap2);
      expect(t2.stereoBandUsed, isFalse,
          reason: 'setStereoMix 自带 bandUsed=true 副作用，必须由快照值覆盖');
    });

    test('apply() reverb preset=-1 分支：全局预设基线复写 / 自有预设缺键不碰', () {
      // 出厂风格的最小 reverb 节：只关混响，不带任何 customParam
      final preset = AuraPreset(
        name: '__regress_reverb_off__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'reverb': {'enable': false, 'preset': -1},
        },
      );

      // 全局预设（fullRewrite=true，默认）：缺键由 defaults.json 基线补全复写，
      // 用户自调值被复位为出厂默认（0.5/0.35/1.2）。
      final m = AppModel(testing: true);
      m.setReverbCustomParam('decay', 0.9);
      m.setReverbCustomParam('wet', 0.8);
      m.setReverbCustomParam('roomSize', 2.2);
      PresetLibrary.apply(m, preset);
      expect(m.isSpatialReverbOn, isFalse);
      expect(m.fvDecay, closeTo(0.5, 1e-9));
      expect(m.fvWet, closeTo(0.35, 1e-9));
      expect(m.fvRoomSize, closeTo(1.2, 1e-9));

      // 效果器自有预设（fullRewrite=false）：只应用实际携带的键，
      // 缺键不碰用户自调值（钉住 F2 按键守卫：?? 硬编码兜底不得复活）。
      final m2 = AppModel(testing: true);
      m2.setReverbCustomParam('decay', 0.9);
      m2.setReverbCustomParam('wet', 0.8);
      m2.setReverbCustomParam('roomSize', 2.2);
      PresetLibrary.apply(m2, preset, fullRewrite: false);
      expect(m2.isSpatialReverbOn, isFalse);
      expect(m2.fvDecay, closeTo(0.9, 1e-9));
      expect(m2.fvWet, closeTo(0.8, 1e-9));
      expect(m2.fvRoomSize, closeTo(2.2, 1e-9));

      // 显式携带的键仍必须写入；未携带的键保持现值
      final preset2 = AuraPreset(
        name: '__regress_reverb_partial__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'reverb': {'enable': false, 'preset': -1, 'decay': 0.3},
        },
      );
      PresetLibrary.apply(m2, preset2, fullRewrite: false);
      expect(m2.fvDecay, closeTo(0.3, 1e-9));
      expect(m2.fvWet, closeTo(0.8, 1e-9));
    });

    test('resetConfig 连带清除会话记忆（恢复默认 = 全部归零）', () {
      final m = AppModel(testing: true);
      m.setGateEnabled(true);
      expect(SessionMemory.save(m), isTrue);
      expect(File(SessionMemory.sessionPath).existsSync(), isTrue);
      m.resetConfig();
      expect(File(SessionMemory.sessionPath).existsSync(), isFalse,
          reason: 'resetConfig 后会话文件必须删除，否则下次启动旧参数全回来');
    });

    test('不变量：setGraphOrder 挂自动保存、两处回放均有守卫（_testing 短路 → 源码审计）', () {
      // scheduleAutoSave 在 _testing/_isReplayingSession 下短路，功能断言
      // 不可达，只能以源码形状钉住不变量（与 E1 探针同一模式）。
      final src = File('lib/core/state.dart').readAsStringSync();

      final i = src.indexOf('void setGraphOrder(String order) {');
      expect(i, greaterThan(-1), reason: '找不到 setGraphOrder 定义');
      final j = src.indexOf('\n  }', i);
      final body = src.substring(i, j);
      expect(body.contains('scheduleAutoSave'), isTrue,
          reason: 'setGraphOrder 必须持久化 chainOrder（snapshot 已采集），'
              '否则处理链重排重启即丢');

      final guardCount =
          RegExp(r'_isReplayingSession = true').allMatches(src).length;
      expect(guardCount, 2,
          reason: 'replaySessionToEngine 与构造期 restoreMemoryImage '
              '两处回放都必须置守卫，缺一即启动自写');
    });
  });

  group('Liveprog v2: 会话/预设带回使能与滑块', () {
    test('snapshot 携带 liveprog{enabled,params,codeHash}（schemaVersion 3）',
        () {
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
      const code = '@init\nx = 1;\n@sample\nspl0 = 1;\n';
      m.lpCode = code;
      final src = AppModel(testing: true)
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
      final m = AppModel(testing: true)..lpCode = '@init\ny = 2;\n@sample\nspl0 = 1;\n';
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

    test('无 liveprog 节的全局预设：使能/滑块复位默认，脚本正文（会话级）保留', () {
      // 2026-10-16 语义定版：全局预设全部复写。lpCode 属会话级资源态，
      // 不在预设 params 内，故不随预设复写。
      final m = AppModel(testing: true)
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
      expect(m.lpEnabled, isFalse, reason: '缺节 = 复位默认（关闭）');
      expect(m.lpCode, 'keepme', reason: '脚本正文是会话级资源，不随预设复写');
      expect(m.lpParams[0], isNot(closeTo(0.9, 1e-9)));
    });

    test('效果器自有预设（fullRewrite=false）：liveprog 缺省节不碰脚本态', () {
      final m = AppModel(testing: true)
        ..lpEnabled = true
        ..lpCode = 'keepme';
      m.lpParams[0] = 0.9;
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__scoped__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 1.0, 'limiterEnable': true},
              }),
          fullRewrite: false);
      expect(m.lpEnabled, isTrue);
      expect(m.lpCode, 'keepme');
      expect(m.lpParams[0], closeTo(0.9, 1e-9));
    });

    test('setLiveprogCode 采纳声明默认值；同签名重应用保留用户值', () {
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true)
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
      final m = AppModel(testing: true);
      expect(m.bassmonoOn, isFalse);
      expect(m.bassmonoFreq, closeTo(120.0, 1e-9));
      expect(m.isStageEnabled('bassmono'), isFalse);
    });

    test('分频点钳位 20~300Hz', () {
      final m = AppModel(testing: true);
      m.setBassmonoFreq(10);
      expect(m.bassmonoFreq, closeTo(20.0, 1e-9));
      m.setBassmonoFreq(500);
      expect(m.bassmonoFreq, closeTo(300.0, 1e-9));
      m.setBassmonoFreq(80);
      expect(m.bassmonoFreq, closeTo(80.0, 1e-9));
    });

    test('toggleStage 翻转独立开关位', () {
      final m = AppModel(testing: true);
      m.toggleStage('bassmono');
      expect(m.bassmonoOn, isTrue);
      m.toggleStage('bassmono');
      expect(m.bassmonoOn, isFalse);
    });

    test('snapshot/apply 对称恢复使能与分频点', () {
      final src = AppModel(testing: true)
        ..setBassmonoEnabled(true)
        ..setBassmonoFreq(200);
      final snap = PresetLibrary.snapshot(src, name: '__bm__');
      final bm = snap.params['bassmono'] as Map<String, dynamic>;
      expect(bm['enable'], isTrue);
      expect((bm['freq'] as num).toDouble(), closeTo(200.0, 1e-9));

      final m = AppModel(testing: true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__bm_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.bassmonoOn, isTrue);
      expect(m.bassmonoFreq, closeTo(200.0, 1e-9));
    });

    test('无 bassmono 节的全局预设：开关复位默认（关闭）', () {
      // 2026-10-16 语义定版：全局预设全部复写，缺节 = 复位默认。
      final m = AppModel(testing: true)..setBassmonoEnabled(true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__legacy__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 0.0, 'limiterEnable': true},
              }));
      expect(m.bassmonoOn, isFalse);
    });
  });

  group('Haas: 差分环绕', () {
    test('默认值：关闭 + 12ms + 全湿', () {
      final m = AppModel(testing: true);
      expect(m.haasOn, isFalse);
      expect(m.haasDelayMs, closeTo(12.0, 1e-9));
      expect(m.haasMix, closeTo(1.0, 1e-9));
      expect(m.isStageEnabled('haas'), isFalse);
    });

    test('延迟/混合钳位', () {
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
      m.toggleStage('haas');
      expect(m.haasOn, isTrue);
      m.toggleStage('haas');
      expect(m.haasOn, isFalse);
    });

    test('snapshot/apply 对称恢复三字段', () {
      final src = AppModel(testing: true)
        ..setHaasEnabled(true)
        ..setHaasDelay(8)
        ..setHaasMix(0.6);
      final snap = PresetLibrary.snapshot(src, name: '__hs__');
      final hs = snap.params['haas'] as Map<String, dynamic>;
      expect(hs['enable'], isTrue);
      expect((hs['delay'] as num).toDouble(), closeTo(8.0, 1e-9));
      expect((hs['mix'] as num).toDouble(), closeTo(0.6, 1e-9));

      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
      expect(m.haasSide, 0);
      m.setHaasSide(1);
      expect(m.haasSide, 1);
      m.setHaasSide(9);
      expect(m.haasSide, 1);
      m.setHaasSide(0);
      expect(m.haasSide, 0);

      final src = AppModel(testing: true)
        ..setHaasEnabled(true)
        ..setHaasSide(1);
      final snap = PresetLibrary.snapshot(src, name: '__hs_side__');
      final hs = snap.params['haas'] as Map<String, dynamic>;
      expect(hs['side'], 1);

      final m2 = AppModel(testing: true);
      PresetLibrary.apply(
          m2,
          AuraPreset(
              name: '__hs_side_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m2.haasSide, 1);
    });

    test('延迟标称随设定值走（底栏/徽标用）', () {
      final m = AppModel(testing: true)
        ..setHaasEnabled(true)
        ..setHaasDelay(15);
      expect(m.componentLatency('haas').ms, closeTo(15.0, 1e-9));
      m.setHaasEnabled(false);
      expect(m.componentLatency('haas').ms, closeTo(0.0, 1e-9));
    });
  });

  group('Exciter: 激励器', () {
    test('默认值：关闭 + 0.3 + 5kHz', () {
      final m = AppModel(testing: true);
      expect(m.exciterOn, isFalse);
      expect(m.exciterAmount, closeTo(0.3, 1e-9));
      expect(m.exciterHifreq, closeTo(5000.0, 1e-9));
      expect(m.isStageEnabled('exciter'), isFalse);
    });

    test('量/分频钳位', () {
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
      m.toggleStage('exciter');
      expect(m.exciterOn, isTrue);
      m.toggleStage('exciter');
      expect(m.exciterOn, isFalse);
    });

    test('snapshot/apply 对称恢复三字段', () {
      final src = AppModel(testing: true)
        ..setExciterEnabled(true)
        ..setExciterAmount(0.7)
        ..setExciterHifreq(8000);
      final snap = PresetLibrary.snapshot(src, name: '__ex__');
      final ex = snap.params['exciter'] as Map<String, dynamic>;
      expect(ex['enable'], isTrue);
      expect((ex['amount'] as num).toDouble(), closeTo(0.7, 1e-9));
      expect((ex['hifreq'] as num).toDouble(), closeTo(8000.0, 1e-9));

      final m = AppModel(testing: true);
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

    test('无 exciter 节：全局预设复位开关，效果器自有预设不碰', () {
      final m = AppModel(testing: true)..setExciterEnabled(true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__legacy__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 0.0, 'limiterEnable': true},
              }));
      // 2026-10-16 语义定版：全局预设全部复写，缺节 = 复位默认（关闭）。
      expect(m.exciterOn, isFalse);

      // 效果器自有预设（fullRewrite=false）：缺 exciter 节不碰本效果器状态。
      final m2 = AppModel(testing: true)..setExciterEnabled(true);
      PresetLibrary.apply(
          m2,
          AuraPreset(
              name: '__own__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 0.0, 'limiterEnable': true},
              }),
          fullRewrite: false);
      expect(m2.exciterOn, isTrue);
    });
  });

  group('DyneQ: 全参数动态EQ', () {
    test('默认值：全关 + 包络 2ms/120ms', () {
      final m = AppModel(testing: true);
      expect(m.dyneqOn, isFalse);
      expect(m.dyneqLowOn || m.dyneqMidOn || m.dyneqHighOn, isFalse);
      expect(m.dyneqAttackMs, closeTo(2.0, 1e-9));
      expect(m.dyneqReleaseMs, closeTo(120.0, 1e-9));
      expect(m.isStageEnabled('dyneq'), isFalse);
    });

    test('分段钳位', () {
      final m = AppModel(testing: true);
      m.setDyneqLowFreq(1.0);
      expect(m.dyneqLowFreq, closeTo(20.0, 1e-9));
      m.setDyneqMidQ(99.0);
      expect(m.dyneqMidQ, closeTo(10.0, 1e-9));
      m.setDyneqHighQ(0.1);
      expect(m.dyneqHighQ, closeTo(0.5, 1e-9));
      m.setDyneqMidRange(-5.0);
      expect(m.dyneqMidRange, closeTo(0.0, 1e-9));
      m.setDyneqLowThreshold(-99.0);
      expect(m.dyneqLowThreshold, closeTo(-60.0, 1e-9));
    });

    test('toggleStage 翻转总开关', () {
      final m = AppModel(testing: true);
      m.toggleStage('dyneq');
      expect(m.dyneqOn, isTrue);
      m.toggleStage('dyneq');
      expect(m.dyneqOn, isFalse);
    });

    test('Issue #4：graph.order 只留 12 个 vendor id（保序去杂）', () {
      expect(
        AppModel.filterVendorOrder('gate,tube,dyneq,filter,output'),
        'tube,output',
      );
      expect(
        AppModel.filterVendorOrder(
            'gate,filter,bassmono,tube,comp,bass,eq,arbmag,convolver,ddc,liveprog,crossfeed,stereo,haas,exciter,reverb,loudness,output'),
        'tube,comp,bass,eq,arbmag,convolver,ddc,liveprog,crossfeed,stereo,reverb,output',
      );
    });

    test('snapshot/apply 对称恢复三段', () {
      final src = AppModel(testing: true)
        ..setDyneqEnabled(true)
        ..setDyneqMidEnabled(true)
        ..setDyneqMidFreq(2000)
        ..setDyneqMidRange(12)
        ..setDyneqHighThreshold(-20);
      final snap = PresetLibrary.snapshot(src, name: '__dq__');
      final dq = snap.params['dyneq'] as Map<String, dynamic>;
      expect(dq['enable'], isTrue);
      expect(((dq['mid'] as Map)['freq'] as num).toDouble(), closeTo(2000.0, 1e-9));
      expect(((dq['mid'] as Map)['range'] as num).toDouble(), closeTo(12.0, 1e-9));
      expect(((dq['high'] as Map)['threshold'] as num).toDouble(), closeTo(-20.0, 1e-9));
      final m = AppModel(testing: true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__dq_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.dyneqOn, isTrue);
      expect(m.dyneqMidOn, isTrue);
      expect(m.dyneqMidFreq, closeTo(2000.0, 1e-9));
      expect(m.dyneqMidRange, closeTo(12.0, 1e-9));
      expect(m.dyneqHighThreshold, closeTo(-20.0, 1e-9));
    });

    test('无 dyneq 节：全局预设复位开关，效果器自有预设不碰', () {
      final m = AppModel(testing: true)..setDyneqEnabled(true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__legacy__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 0.0, 'limiterEnable': true},
              }));
      // 2026-10-16 语义定版：全局预设全部复写，缺节 = 复位默认（关闭）。
      expect(m.dyneqOn, isFalse);

      // 效果器自有预设（fullRewrite=false）：缺 dyneq 节不碰本效果器状态。
      final m2 = AppModel(testing: true)..setDyneqEnabled(true);
      PresetLibrary.apply(
          m2,
          AuraPreset(
              name: '__own__',
              createdAt: DateTime.now().toIso8601String(),
              params: {
                'post': {'gain': 0.0, 'limiterEnable': true},
              }),
          fullRewrite: false);
      expect(m2.dyneqOn, isTrue);
    });
  });

  group('P-010: 每效果输出增益门 + 自动补偿', () {
    test('setter 下发引擎参数（镜像闭环）', () {
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
      m.setArbmagOutputGain(12.0);
      expect(m.arbmagOutputGain, closeTo(6.0, 1e-9));
      m.setArbmagOutputGain(-20.0);
      expect(m.arbmagOutputGain, closeTo(-12.0, 1e-9));
      m.setArbmagAutoGain(true);
      expect(m.arbmagAutoGain, isTrue);
    });

    test('snapshot/apply 对称恢复 autoGain + outputGain', () {
      final src = AppModel(testing: true)
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

      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
      m.toggleStage('gate');
      expect(m.gateOn, isTrue);
      expect(m.isStageEnabled('gate'), isTrue);
      m.toggleStage('gate');
      expect(m.gateOn, isFalse);
    });

    test('snapshot/apply 对称恢复 gate + deesser', () {
      final src = AppModel(testing: true)
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

      final m = AppModel(testing: true);
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
    // 注意：AppModel 构造会 spawn 真实 isolate，其 getParams 回读（float32）
    // 可能竞态覆盖字段；非二进制精确常量（0.35/0.7/0.707/0.8）一律用 1e-6。
    test('mode 宏写入谐波配方（不再碰 shelf）', () {
      final m = AppModel(testing: true);
      m.setBassMode(1);
      expect(m.bassMode, 1);
      expect(m.bassHarmonics, closeTo(0.35, 1e-6));
      expect(m.bassHarmonicBlend, closeTo(0.5, 1e-9));
      m.setBassMode(2);
      expect(m.bassHarmonics, closeTo(0.7, 1e-6));
      expect(m.bassHarmonicBlend, closeTo(0.7, 1e-6));
      m.setBassMode(0);
      expect(m.bassHarmonics, closeTo(0.0, 1e-9));
    });

    test('谐波三滑块下发引擎（不再是死控件）', () {
      final m = AppModel(testing: true);
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
      final src = AppModel(testing: true)
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

      final m = AppModel(testing: true);
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
      final m = AppModel(testing: true);
      expect(m.filterOn, isFalse);
      expect(m.filterType, 0);
      expect(m.filterFreq, closeTo(80.0, 1e-9));
      expect(m.filterQ, closeTo(0.707, 1e-6)); // 见 Bass v3.1 组注：防 isolate 回读竞态
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
      final src = AppModel(testing: true)
        ..setFilterEnabled(true)
        ..setFilterType(1)
        ..setFilterFreq(200)
        ..setFilterQ(1.0);
      final snap = PresetLibrary.snapshot(src, name: '__ft__');
      final f = snap.params['filter'] as Map<String, dynamic>;
      expect(f['enable'], isTrue);
      expect(f['type'], 1);

      final m = AppModel(testing: true);
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

  group('Loudness: 响度补偿', () {
    test('默认值 + 钳位 + 开关', () {
      final m = AppModel(testing: true);
      expect(m.loudnessOn, isFalse);
      expect(m.loudnessAmount, closeTo(0.5, 1e-9));
      m.setLoudnessAmount(5);
      expect(m.loudnessAmount, closeTo(1.0, 1e-9));
      m.setLoudnessAmount(-1);
      expect(m.loudnessAmount, closeTo(0.0, 1e-9));
      m.toggleStage('loudness');
      expect(m.loudnessOn, isTrue);
      expect(m.isStageEnabled('loudness'), isTrue);
    });

    test('snapshot/apply 对称', () {
      final src = AppModel(testing: true)
        ..setLoudnessEnabled(true)
        ..setLoudnessAmount(0.8);
      final snap = PresetLibrary.snapshot(src, name: '__ld__');
      final ld = snap.params['loudness'] as Map<String, dynamic>;
      expect(ld['enable'], isTrue);
      expect((ld['amount'] as num).toDouble(), closeTo(0.8, 1e-6)); // 防 isolate 回读竞态

      final m = AppModel(testing: true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__ld_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.loudnessOn, isTrue);
      expect(m.loudnessAmount, closeTo(0.8, 1e-6)); // 防 isolate 回读竞态
    });
  });

  group('Legacy stages: 快照/恢复往返', () {
    test('tube/stereo/shelf/input/limiter/bass/comp/fv 全节往返', () {
      final src = AppModel(testing: true)
        ..setTubeEnabled(true)
        ..setTubeGain(6.0)
        ..setStereoEnabled(true)
        ..setStereoMix(0.5)
        ..setInt('shelf.enable', 1)
        ..setFloat('shelf.freq', 100.0)
        ..setFloat('shelf.gain', 6.0)
        ..setInputGain(-6.0)
        ..setInputBalanceL(0.5)
        ..setInt('limiter.enable', 1)
        ..setFloat('post.gain', 6.0)
        ..setBassIntensity(0.5)
        ..setCompEnabled(true)
        ..setCompGranularity(2)
        ..setFreeverbEnabled(true)
        ..setReverbCustomParam('wet', 0.5);
      final snap = PresetLibrary.snapshot(src, name: '__legacy__');

      final m = AppModel(testing: true);
      PresetLibrary.apply(
          m,
          AuraPreset(
              name: '__legacy_apply__',
              createdAt: DateTime.now().toIso8601String(),
              params: snap.params));
      expect(m.tubeOn, isTrue);
      expect(m.tubeGain, closeTo(6.0, 1e-9));
      expect(m.stereoOn, isTrue);
      expect(m.stereoMix, closeTo(0.5, 1e-9));
      expect(m.shelfOn, isTrue);
      expect(m.shelfFreq, closeTo(100.0, 1e-9));
      expect(m.inputGain, closeTo(-6.0, 1e-9));
      expect(m.inputBalanceL, closeTo(0.5, 1e-9));
      expect(m.limiterOn, isTrue);
      expect(m.postGain, closeTo(6.0, 1e-9));
      expect(m.bassIntensity, closeTo(0.5, 1e-9));
      expect(m.compOn, isTrue);
      expect(m.compGranularity, 2);
      expect(m.fvOn, isTrue);
      expect(m.fvWet, closeTo(0.5, 1e-9));
    });

    test('自定义态下 enable 不得切回 preset（regression：wet 曾被 0.45 覆盖）', () {
      final m = AppModel(testing: true);
      m.setReverbCustomParam('wet', 0.5);
      m.setReverbCustomParam('decay', 0.7);
      expect(m.reverbPreset, -2);
      // 自定义态重复 enable：只开开关，不许碰参数
      m.setSpatialReverbEnabled(true);
      expect(m.fvWet, closeTo(0.5, 1e-9));
      expect(m.fvDecay, closeTo(0.7, 1e-9));
      expect(m.reverbPreset, -2);
    });

    test('Issue #3 方案A：自定义态关开关保留 -2，开回来恢复参数', () {
      final m = AppModel(testing: true);
      m.setReverbCustomParam('wet', 0.5);
      m.setReverbCustomParam('decay', 0.7);
      expect(m.reverbPreset, -2);
      expect(m.fvOn, isTrue);
      // 关：只关声音，标记保持 -2，参数不动
      m.setSpatialReverbEnabled(false);
      expect(m.reverbPreset, -2);
      expect(m.fvOn, isFalse);
      expect(m.fvWet, closeTo(0.5, 1e-9));
      expect(m.fvDecay, closeTo(0.7, 1e-9));
      // 开：恢复自定义，不许串入 preset 0
      m.setSpatialReverbEnabled(true);
      expect(m.reverbPreset, -2);
      expect(m.fvOn, isTrue);
      expect(m.fvWet, closeTo(0.5, 1e-9));
      expect(m.fvDecay, closeTo(0.7, 1e-9));
    });

    test('非自定义态关开关照旧落 -1，开回 preset 0', () {
      final m = AppModel(testing: true);
      m.selectReverbPreset(3);
      expect(m.reverbPreset, 3);
      m.setSpatialReverbEnabled(false);
      expect(m.reverbPreset, -1);
      expect(m.fvOn, isFalse);
      m.setSpatialReverbEnabled(true);
      expect(m.reverbPreset, 0);
    });
  });

  group('Issue #2 测试隔离', () {
    test('testing 构造不拉 isolate、不落 session', () {
      final dir = Directory.systemTemp.createTempSync('auradsp_iso2_');
      try {
        ConfigManager.baseDirOverride = dir.path;
        final m = AppModel(testing: true);
        // setter 照常走本地 mirror（回读值不断言引擎，只断言内存态）。
        m.setTubeGain(6.0);
        expect(m.tubeGain, closeTo(6.0, 1e-9));
        // isolate 从未拉起：连接态恒为 connecting。
        expect(m.conn, EngineConn.connecting);
        // session 绝不落盘（构造回放 + 防抖自动保存 + dispose 全跳过）。
        m.dispose();
        expect(File('${dir.path}${Platform.pathSeparator}session_state.json').existsSync(), isFalse);
      } finally {
        ConfigManager.baseDirOverride = null;
      }
    });
  });
}

