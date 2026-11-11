// defaults_emit_test.dart — 默认层生成器 + 分层合并契约（资源
// 计划 Part D / P2.5）。
//
// 双重身份：
//  1) 常驻契约测试（CI 恒跑）：代码默认的 toJson→fromJson 往返
//     必须无损（生成器的前提）；DefaultsLayer.deepMergeUnder 的
//     覆盖语义（叶子覆盖/Map 深合并/列表整体替换/入参不改）。
//  2) 打包期生成器：环境变量 AURADSP_EMIT_DEFAULTS=<目录> 在场
//     时，把默认层三件套写入该目录——config.default.json 来自
//     AppConfig() 本尊（代码是唯一真相、生成物不入库，漂移在
//     构造上不可能）、presets/ 复制出厂资产文件、manifest.json
//     记版本。pack.py / pack.sh 打包时以 flutter test 调用本文件。
import 'dart:convert';
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/defaults/defaults_layer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('defaults layer contracts', () {
    test('AppConfig defaults survive a toJson/fromJson round-trip', () {
      final once = AppConfig().toJson();
      final twice = AppConfig.fromJson(once).toJson();
      expect(twice, equals(once));
    });

    test('deepMergeUnder: overlay wins per leaf, maps merge deeply', () {
      final base = <String, dynamic>{
        'a': 1,
        'sec': {'x': 1, 'y': 2},
        'list': [1, 2],
      };
      final overlay = <String, dynamic>{
        'sec': {'y': 3, 'z': 4},
        'list': [9],
        'b': 2,
      };
      final merged = DefaultsLayer.deepMergeUnder(base, overlay);
      expect(merged['a'], 1);
      expect(merged['b'], 2);
      expect(merged['sec'], {'x': 1, 'y': 3, 'z': 4});
      expect(merged['list'], [9]);
      // 入参不被修改
      expect(base['sec'], {'x': 1, 'y': 2});
    });
  });

  test('emit defaults layer when AURADSP_EMIT_DEFAULTS is set', () {
    final out = Platform.environment['AURADSP_EMIT_DEFAULTS'];
    if (out == null || out.isEmpty) {
      // 普通 CI/本地跑测：不产出，只确认生成前提（往返契约）成立。
      return;
    }
    final dir = Directory(out)..createSync(recursive: true);
    final sep = Platform.pathSeparator;

    // 1) config.default.json —— 代码默认本尊导出。
    final cfgJson = AppConfig().toJson();
    File('${dir.path}${sep}config.default.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(cfgJson));

    // 2) presets/ —— 出厂资产文件原样复制（与 Flutter 资产同源）。
    final srcDir = Directory('assets/presets/factory');
    final dstDir = Directory('${dir.path}${sep}presets')
      ..createSync(recursive: true);
    final files = <String>['config.default.json'];
    for (final f in srcDir.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.json')) continue;
      final name = f.uri.pathSegments.last;
      File('${dstDir.path}$sep$name')
          .writeAsStringSync(f.readAsStringSync());
      files.add('presets/$name');
    }

    // 3) manifest.json —— 版本来自 pubspec（版本真源）。
    var version = '';
    for (final line in File('pubspec.yaml').readAsLinesSync()) {
      final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').firstMatch(line);
      if (m != null) {
        version = m.group(1)!;
        break;
      }
    }
    File('${dir.path}${sep}manifest.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'version': version,
        'defaultsVersion': 1,
        'generatedBy': 'defaults_emit_test (code truth)',
        'files': files,
      }),
    );
    expect(File('${dir.path}${sep}config.default.json').existsSync(), isTrue);
  });
}
