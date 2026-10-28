// 预设系统契约门禁（2026-10-28）
//
// 钉住三条最容易静默腐化的约定：
//   1. assets/presets/defaults.json 必须与 ParamRegistry 的当前全量快照逐键逐值
//      一致 —— 它缺席的键在 fullRewrite 下不会被复位，「全部复写」会静默失效
//      （2026-10-28 实测漏 4 键：bassmono.pairs / bassmono.merge / comp.mode /
//      post.channelTrims）。
//   2. 每个出厂预设的键集必须与 defaults 完全一致 —— 多出的是孤儿旧键
//      （曾是 tube.oversampling，现行 spec 键为 tube.oversample），少了的键
//      载入后取不到基线值。
//   3. routing（全部 spec 带 sessionOnly）不得出现在预设/快照/指纹里 ——
//      它只随 SessionMemory 走，否则载入预设会清空用户的输出设备与 ASIO 配置
//      并即时落盘。
//
// 另：出厂资产清单（代码侧常量）与资产目录必须双向一致 —— pubspec 按目录打包，
// 只放文件不登记 = 编译通过但永不落盘。
import 'dart:convert';
import 'dart:io';

import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/session_memory.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

const String _defaultsPath = 'assets/presets/defaults.json';
const String _factoryDir = 'assets/presets/factory';

Map<String, dynamic> _readDefaultsParams() {
  final json =
      jsonDecode(File(_defaultsPath).readAsStringSync()) as Map<String, dynamic>;
  return (json['params'] as Map).cast<String, dynamic>();
}

/// 展平成 `节.子节.键 -> 值`，用于双向比对键集。
Map<String, dynamic> _flatten(Map<String, dynamic> m, [String prefix = '']) {
  final out = <String, dynamic>{};
  m.forEach((k, v) {
    if (v is Map) {
      out.addAll(_flatten(Map<String, dynamic>.from(v), '$prefix$k.'));
    } else {
      out['$prefix$k'] = v;
    }
  });
  return out;
}

String _describe(dynamic v) {
  if (v is List) return '[${v.length}]';
  return '$v';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await PresetLibrary.preloadFactoryAssets();
  });

  group('预设基线契约：defaults.json ↔ ParamRegistry', () {
    test('键集双向一致（无缺键、无孤儿键），且值等于全新模型的默认值', () {
      final fresh = PresetLibrary.snapshot(
        AppModel(testing: true),
        name: '__contract__',
      ).params;
      final live = _flatten(fresh);
      final disk = _flatten(_readDefaultsParams());

      final missing = live.keys.where((k) => !disk.containsKey(k)).toList()
        ..sort();
      final extra = disk.keys.where((k) => !live.containsKey(k)).toList()
        ..sort();
      expect(missing, isEmpty,
          reason: 'defaults.json 缺这些键 → fullRewrite 下它们不会被复位。'
              '请跑 `flutter test test/zz_gen_factory_presets.dart` 重生成');
      expect(extra, isEmpty,
          reason: 'defaults.json 多出这些键 → 注册表已删除/改名，属基线腐化。'
              '请跑 `flutter test test/zz_gen_factory_presets.dart` 重生成');

      final valueDiff = <String>[];
      live.forEach((k, v) {
        final d = disk[k];
        if (v is num && d is num) {
          if ((v.toDouble() - d.toDouble()).abs() > 1e-9) {
            valueDiff.add('$k: live=$v disk=$d');
          }
        } else if (v is List && d is List) {
          if (v.length != d.length) {
            valueDiff.add('$k: len ${v.length} != ${d.length}');
          } else {
            for (var i = 0; i < v.length; i++) {
              final a = v[i], b = d[i];
              if (a is num && b is num) {
                if ((a.toDouble() - b.toDouble()).abs() > 1e-9) {
                  valueDiff.add('$k[$i]: live=$a disk=$b');
                  break;
                }
              } else if (a != b) {
                valueDiff.add('$k[$i]: live=$a disk=$b');
                break;
              }
            }
          }
        } else if (_describe(v) != _describe(d)) {
          valueDiff.add('$k: live=${_describe(v)} disk=${_describe(d)}');
        }
      });
      expect(valueDiff, isEmpty,
          reason: '基线值漂移 → 载入全局预设会把参数复位成旧默认值');
    });

    test('每个出厂预设的键集与 defaults 完全一致', () {
      final base = _flatten(_readDefaultsParams()).keys.toSet();
      final files = Directory(_factoryDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .toList();
      expect(files, isNotEmpty);

      for (final f in files) {
        final obj =
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final presetParams =
            ((obj['params'] ?? obj['parameters']) as Map?)?.cast<String, dynamic>();
        expect(presetParams, isNotNull, reason: '${f.path} 缺 params 节');
        final keys = _flatten(presetParams!).keys.toSet();
        final extra = (keys.difference(base).toList()..sort());
        final missing = (base.difference(keys).toList()..sort());
        expect(extra, isEmpty,
            reason: '${f.path} 含默认基线没有的孤儿键（spec 已改名/删除？）');
        expect(missing, isEmpty,
            reason: '${f.path} 缺默认基线有的键（载入后取不到基线值）');
      }
    });

    test('出厂资产清单与资产目录双向一致', () {
      final registered = PresetLibrary.factoryAssetFiles.toSet();
      final onDisk = Directory(_factoryDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(RegExp(r'[\\/]')).last)
          .where((n) => n.toLowerCase().endsWith('.json'))
          .toSet();

      expect(registered.difference(onDisk), isEmpty,
          reason: '清单登记了但资产目录没有该文件');
      expect(onDisk.difference(registered), isEmpty,
          reason: '资产目录有该文件但没登记进 _factoryAssetFiles → '
              'pubspec 会把整目录打包，但 ensureInitialized 不会落盘，'
              '表现为「新出厂预设编译通过却永远不出现」');
    });
  });

  group('会话级参数（sessionOnly）不得进入预设系统', () {
    test('snapshot 不采集 routing 节', () {
      final m = AppModel(testing: true)
        ..setPipelineInputDevice('Mic (USB Audio)')
        ..setPipelineOutputDevice('Speakers (Realtek)')
        ..setAsioBufSize(512);
      final snap = PresetLibrary.snapshot(m, name: '__contract_route__');
      expect(snap.params.containsKey('routing'), isFalse,
          reason: 'routing 全节 sessionOnly，只随 SessionMemory 持久化');
    });

    test('指纹不受音频模式切换影响（不误报「自定义（未保存）」）', () {
      final m = AppModel(testing: true);
      final preset = AuraPreset(
        name: '__contract_dirty__',
        createdAt: DateTime.now().toIso8601String(),
        params: {'gate': {'threshold': 0.2}},
      );
      PresetLibrary.apply(m, preset);
      expect(m.evaluatePresetDirty(), isFalse);
      m.setAudioMode('asio');
      expect(m.evaluatePresetDirty(), isFalse,
          reason: '音频模式是路由/会话级状态，不该把预设标脏');
    });

    test('apply 忽略预设里携带的 routing（旧版用户预设也不得改动设备）', () {
      final m = AppModel(testing: true)
        ..setPipelineInputDevice('Mic (USB Audio)')
        ..setPipelineOutputDevice('Speakers (Realtek)')
        ..setAsioBufSize(512)
        ..setAsioOutPair(3);

      final legacy = AuraPreset(
        name: '__contract_legacy_route__',
        createdAt: DateTime.now().toIso8601String(),
        params: {
          'gate': {'threshold': 0.5},
          // 2026-10-28 之前的 snapshot 会带上这一节
          'routing': {
            'pipelineInputDevice': '',
            'pipelineOutputDevice': '',
            'pipelineInputEnabled': false,
            'pipelineOutputEnabled': false,
            'asioBufSize': 0,
            'asioOutPair': 0,
            'vaioOutputEndpoint': '',
            'apoTargetEndpoint': '',
            'monitorMirroring': true,
          },
        },
      );
      PresetLibrary.apply(m, legacy);

      expect(m.pipelineInputDevice, 'Mic (USB Audio)');
      expect(m.pipelineOutputDevice, 'Speakers (Realtek)');
      expect(m.config.asioBufSize, 512);
      expect(m.config.asioOutPair, 3);
      expect(m.config.monitorMirroring, isFalse);
    });

    test('出厂预设载入后复位 DSP 参数、保留路由与设备', () {
      final m = AppModel(testing: true)
        ..setPipelineOutputDevice('Speakers (Realtek)')
        ..setAsioBufSize(512)
        ..setBassmonoPairs(0x0F)
        ..setBassmonoMerge(1)
        ..setCompMode(1);

      final pop = PresetLibrary.listAll()
          .firstWhere((p) => p.name == 'Pop Vocal Clarity');
      PresetLibrary.apply(m, pop);

      // 路由：原样保留
      expect(m.pipelineOutputDevice, 'Speakers (Realtek)');
      expect(m.config.asioBufSize, 512);
      // 曾经的复位盲区：现在必须回到基线
      final base = _flatten(_readDefaultsParams());
      expect(m.bassmonoPairs, base['bassmono.pairs']);
      expect(m.bassmonoMerge, base['bassmono.merge']);
      expect(m.compMode, base['comp.mode']);
      // 应用即归零
      expect(m.presetDirty, isFalse);
    });

    test('v6 及更早会话的锚点按版本丢弃（指纹算法变更不误报脏）', () {
      final m = AppModel(testing: true);
      SessionMemory.restoreMemoryImage(m, {
        'version': 6,
        'appliedPresetFingerprint': 'stale-anchor-from-v6',
        'presetDirty': true,
      });
      expect(m.appliedPresetFingerprint, isNull,
          reason: 'v6 锚点按旧算法（含 routing）生成，必然失配 → 必须丢弃');
      expect(m.presetDirty, isFalse);

      // v7 起正常采纳
      final m2 = AppModel(testing: true);
      SessionMemory.restoreMemoryImage(m2, {
        'version': 7,
        'appliedPresetFingerprint': 'anchor-v7',
        'presetDirty': true,
      });
      expect(m2.appliedPresetFingerprint, 'anchor-v7');
      expect(m2.presetDirty, isTrue);
    });
  });
}
