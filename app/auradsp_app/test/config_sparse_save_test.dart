// config_sparse_save_test.dart — 用户配置稀疏落盘回归电池
// （资源计划 Part D 后置步，2026-11-12）。
//
// 稀疏落盘的安全前提是等价性：对任何 load 可产生的有效配置
// full 与基线 baseline，必须有
//   deepMergeUnder(baseline, sparseDiff(baseline, full)) ≡ full
// 否则用户设置会在下次启动被静默改写。本电池从三个层面钉死：
// ① sparseDiff 纯函数规则；② 真实 AppConfig 状态 × 两类基线
// （代码默认 / 模拟发行层）的往返等价；③ ConfigManager 落盘
// 集成（文件形态 + version 防重复迁移 + load 回读一致）。

import 'dart:convert';
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/defaults/defaults_layer.dart';
import 'package:auradsp_app/core/plugins/plugin_scan_dirs.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> merge(
        Map<String, dynamic> base, Map<String, dynamic> over) =>
    DefaultsLayer.deepMergeUnder(base, over);

void expectDeepEqual(Object? a, Object? b, [String? reason]) {
  expect(DefaultsLayer.jsonDeepEqual(a, b), isTrue,
      reason: reason ?? '深相等失败:\nA=$a\nB=$b');
}

void main() {
  group('sparseDiff 纯函数规则', () {
    test('全等 → 空（forceKeep 除外）', () {
      final base = {
        'version': 4,
        'audio': {'a': 1, 'b': 'x'},
        'ui': {'t': true},
      };
      expect(DefaultsLayer.sparseDiff(base, base), isEmpty);
      expect(
        DefaultsLayer.sparseDiff(base, base, forceKeep: {'version'}),
        {'version': 4},
      );
    });

    test('嵌套只收差异叶，相等子树整棵省略', () {
      final base = {
        'audio': {'a': 1, 'b': 2, 'c': 3},
        'viz': {'x': 1.5, 'y': 2},
      };
      final full = {
        'audio': {'a': 1, 'b': 20, 'c': 3},
        'viz': {'x': 1.5, 'y': 2},
      };
      expect(DefaultsLayer.sparseDiff(base, full), {
        'audio': {'b': 20},
      });
    });

    test('List 差异整表收录、相等整表省略', () {
      final base = {
        'dirs': [
          {'path': '/a', 'enabled': true},
        ],
        'tags': ['x'],
      };
      final changed = {
        'dirs': [
          {'path': '/a', 'enabled': false},
        ],
        'tags': ['x'],
      };
      expect(DefaultsLayer.sparseDiff(base, changed), {
        'dirs': [
          {'path': '/a', 'enabled': false},
        ],
      });
    });

    test('仅 full 有的键整值收录；类型翻转整值收录', () {
      final base = {'a': {'n': 1}, 'b': 1};
      final full = {'a': 7, 'b': 1, 'c': 'new'};
      expect(DefaultsLayer.sparseDiff(base, full), {'a': 7, 'c': 'new'});
    });

    test('num 跨 int/double 按值相等（1 ≡ 1.0 不算差异）', () {
      expect(
        DefaultsLayer.sparseDiff({'v': 1}, {'v': 1.0}),
        isEmpty,
      );
      expect(
        DefaultsLayer.sparseDiff({'v': 1.0}, {'v': 2}),
        {'v': 2},
      );
    });

    test('null 是真实值：与基线非 null 不同则收录', () {
      expect(
        DefaultsLayer.sparseDiff({'v': 'x'}, {'v': null}),
        {'v': null},
      );
      expect(DefaultsLayer.sparseDiff({'v': null}, {'v': null}), isEmpty);
    });
  });

  group('等价性电池：merge(baseline, sparse(full)) ≡ full', () {
    final codeBase = AppConfig().toJson();
    // 模拟发行默认层：与代码默认有若干处不同（含嵌套叶与列表）。
    final distroBase = merge(codeBase, {
      'themeId': 'aurora',
      'audio': {'asioBufSize': 256},
      'visualizer': _tweakFirstNumLeaf(codeBase['visualizer'] as Map),
    });

    Map<String, dynamic> producible(
        Map<String, dynamic> baseline, Map<String, dynamic> overlay) {
      // load 的真实路径：合并 → fromJson 规范化 → toJson 全量形。
      return AppConfig.fromJson(merge(baseline, overlay)).toJson();
    }

    void checkBattery(Map<String, dynamic> baseline, String label) {
      final states = <String, Map<String, dynamic>>{
        '纯基线': producible(baseline, const {}),
        '单节标量': producible(baseline, {
          'audio': {'asioBufSize': 1024, 'vbBusMask': 5},
          'vizFps': 24,
        }),
        '列表与字符串': producible(baseline, {
          'themeId': 'custom-x',
          'locale': 'en',
          'customScriptDirs': ['/tmp/scripts'],
          'audio': {'apoTargetEndpoint': '{dead-beef}'},
        }),
        '大杂烩': producible(baseline, {
          'audio': {
            'asioBufSize': 64,
            'channelsCount': 8,
            'monitorMirroring': true,
          },
          'vizFftSize': 4096,
          'closeToTray': false,
          'customScriptDirs': ['/a', '/b'],
        }),
      };
      states.forEach((name, full) {
        final sparse = DefaultsLayer.sparseDiff(baseline, full,
            forceKeep: const {'version'});
        final reloaded = merge(baseline, sparse);
        expectDeepEqual(reloaded, full, '$label/$name: 合并往返不等价');
        expectDeepEqual(AppConfig.fromJson(reloaded).toJson(), full,
            '$label/$name: fromJson 往返不等价');
        expect(sparse['version'], full['version'],
            reason: '$label/$name: version 必须强制落盘');
      });
    }

    test('代码默认基线', () => checkBattery(codeBase, 'code'));
    test('发行层基线（与代码默认有差异）', () => checkBattery(distroBase, 'distro'));

    test('与基线同值的显式设置被省略（稀疏语义本体）', () {
      final full = producible(codeBase, {
        'audio': {'asioBufSize': codeBase['audio']['asioBufSize']},
      });
      final sparse = DefaultsLayer.sparseDiff(codeBase, full);
      expect(sparse.containsKey('audio'), isFalse,
          reason: '与默认同值 = 未改，升级默认时应跟随新默认');
    });
  });

  group('ConfigManager 落盘集成', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('auradsp_sparse_');
      ConfigManager.baseDirOverride = tmp.path;
    });

    tearDown(() async {
      ConfigManager.baseDirOverride = null;
      await tmp.delete(recursive: true);
    });

    test('默认配置落盘只剩 version，回读仍是完整默认', () {
      expect(ConfigManager.save(AppConfig()), isTrue);
      final raw = jsonDecode(
          File(ConfigManager.configPath).readAsStringSync()) as Map;
      expect(raw, {'version': 4});
      expectDeepEqual(ConfigManager.load().toJson(), AppConfig().toJson());
    });

    test('改过的键落盘、未改的不落盘，回读全等', () {
      final cfg = AppConfig()
        ..themeId = 'aurora'
        ..closeToTray = false;
      cfg.asioBufSize = 512;
      cfg.pluginScanDirs = const [
        PluginScanDirEntry(path: '/opt/plugins', builtin: false),
      ];
      expect(ConfigManager.save(cfg), isTrue);
      final raw = jsonDecode(
          File(ConfigManager.configPath).readAsStringSync()) as Map;
      expect(raw['version'], 4);
      expect(raw['themeId'], 'aurora');
      expect(raw['closeToTray'], false);
      expect((raw['audio'] as Map)['asioBufSize'], 512);
      expect((raw['audio'] as Map).length, 1,
          reason: 'audio 节只应落被改的 asioBufSize');
      expect(raw.containsKey('visualizer'), isFalse);
      expectDeepEqual(ConfigManager.load().toJson(), cfg.toJson());
    });

    test('旧全量档仍可读（升级兼容），再存即变稀疏', () {
      File(ConfigManager.configPath)
          .writeAsStringSync(jsonEncode(AppConfig().toJson()));
      final loaded = ConfigManager.load();
      expectDeepEqual(loaded.toJson(), AppConfig().toJson());
      expect(ConfigManager.save(loaded), isTrue);
      final raw = jsonDecode(
          File(ConfigManager.configPath).readAsStringSync()) as Map;
      expect(raw, {'version': 4});
    });
  });
}

/// 把嵌套 Map 里第一个数值叶 +1（造一个与基线不同的嵌套值）。
Map<String, dynamic> _tweakFirstNumLeaf(Map<dynamic, dynamic> src) {
  final out = <String, dynamic>{};
  var done = false;
  src.forEach((k, v) {
    if (!done && v is num) {
      out[k.toString()] = v + 1;
      done = true;
    } else if (v is Map) {
      out[k.toString()] = v;
    } else {
      out[k.toString()] = v;
    }
  });
  return out;
}
