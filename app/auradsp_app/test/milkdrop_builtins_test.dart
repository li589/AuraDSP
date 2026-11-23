// milkdrop_builtins_test.dart — 内置 MilkDrop 预设真文件化（r65）
//
// r64 验收定罪：三个内置预设是 'builtin:' 伪路径——原生桥拒绝
// 加载、parseFile 不解析 id，三者全塌成同一套默认参数。本测试钉：
//  1. 声明表三只参数互异（回落渲染口径）；
//  2. parseFile 对 builtin id 返回声明参数（不再塌默认）；
//  3. resolveFilePath 单一解析口：非内置直通、内置拼落盘路径；
//  4. ensureStaged 把三份真 .milk 资产落盘，且落盘文件按标准键
//     （fDecay / nWaveMode）解析出的参数与声明表一致。
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/features/visualizer/plugins/milkdrop_builtins.dart';
import 'package:auradsp_app/features/visualizer/plugins/milkdrop_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置 MilkDrop 预设（r65）', () {
    test('声明表三只参数互异', () {
      final ps = MilkdropPreset.builtInPresets;
      expect(ps.length, 3);
      expect(ps.map((p) => p.filePath).toSet().length, 3);
      expect(ps.map((p) => p.decay).toSet().length, 3);
      expect(ps.map((p) => p.waveMode).toSet().length, 3);
      for (final p in ps) {
        expect(MilkdropPreset.isBuiltinPath(p.filePath), isTrue);
      }
    });

    test('parseFile(builtin) 返回声明参数而非默认', () {
      MilkdropPreset.builtinDir = null;
      for (final declared in MilkdropPreset.builtInPresets) {
        final parsed = MilkdropPreset.parseFile(declared.filePath);
        expect(parsed.name, declared.name);
        expect(parsed.decay, declared.decay);
        expect(parsed.zoom, declared.zoom);
        expect(parsed.waveMode, declared.waveMode);
      }
    });

    test('resolveFilePath 解析口', () {
      MilkdropPreset.builtinDir = null;
      expect(
        MilkdropPreset.resolveFilePath('builtin:cosmic_warp'),
        'builtin:cosmic_warp',
        reason: '未落盘时原样返回伪路径，调用方据此延后',
      );
      expect(
        MilkdropPreset.resolveFilePath(r'C:\presets\x.milk'),
        r'C:\presets\x.milk',
      );
      MilkdropPreset.builtinDir = 'D:${Platform.pathSeparator}stage';
      expect(
        MilkdropPreset.resolveFilePath('builtin:bio_pulsar'),
        'D:${Platform.pathSeparator}stage${Platform.pathSeparator}'
        'bio_pulsar.milk',
      );
      MilkdropPreset.builtinDir = null;
    });

    test('ensureStaged 落盘三份真 .milk 且参数与声明一致', () async {
      await MilkdropBuiltinStaging.ensureStaged();
      final dir = MilkdropPreset.builtinDir;
      expect(dir, isNotNull);
      expect(dir, ConfigManager.path('milkdrop_builtins'));
      for (final declared in MilkdropPreset.builtInPresets) {
        final resolved = MilkdropPreset.resolveFilePath(declared.filePath);
        final file = File(resolved);
        expect(file.existsSync(), isTrue, reason: resolved);
        final text = file.readAsStringSync();
        expect(text, contains('[preset00]'));
        expect(text, contains('per_frame_1='));
        // 落盘真文件按标准键解析：decay/waveMode 与声明表一致。
        final parsed = MilkdropPreset.parseFile(resolved);
        expect(parsed.decay, declared.decay, reason: declared.name);
        expect(parsed.waveMode, declared.waveMode, reason: declared.name);
        expect(parsed.hasCustomEquations, isTrue, reason: declared.name);
        // 经 builtin id 解析同样拿到声明身份（名称不被文件名覆盖）。
        final viaBuiltin = MilkdropPreset.parseFile(declared.filePath);
        expect(viaBuiltin.name, declared.name);
        expect(viaBuiltin.hasCustomEquations, isTrue);
      }
    });
  });
}
