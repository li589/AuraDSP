/*
 * plugin_scan_dirs_test.dart — 插件扫描目录（P-042）与列表排序单元测试
 *
 * 覆盖：
 *   1. TextCollation：大小写/变音折叠、自然数字序、空串沉底；
 *   2. PluginScanDirEntry JSON 往返；
 *   3. AppConfig 迁移：旧 customPluginDirs → pluginScanDirs（启用/非内置）；
 *   4. PluginScanDirs.discoverFrom：只保留真实存在目录 + 去重；
 *   5. PluginManager.pluginGroups：厂商字典序（未知沉底）、组内名称序。
 */
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/plugins/plugin_manager.dart';
import 'package:auradsp_app/core/plugins/plugin_scan_dirs.dart';
import 'package:auradsp_app/core/plugins/text_collation.dart';

PluginMetadata _p(String name, String vendor, {String path = ''}) {
  return PluginMetadata(
    id: path,
    name: name,
    vendor: vendor,
    format: PluginFormat.vst3,
    path: path.isEmpty ? '/x/$name' : path,
  );
}

void main() {
  group('TextCollation', () {
    test('大小写与变音符号折叠后视为同组，但保持全序', () {
      // 主键相同 → 回退原文比较：非 0 且方向相反（反对称，全序稳定）。
      final ab = TextCollation.compare('acme', 'ACME');
      expect(ab, isNot(0));
      expect(TextCollation.compare('ACME', 'acme'), -ab);
      expect(TextCollation.compare('Éclat Audio', 'Eclat Audio'), isNot(0));
    });

    test('自然数字序：2 在 10 之前', () {
      expect(TextCollation.compare('Plugin 2', 'Plugin 10'), lessThan(0));
      expect(TextCollation.compare('Plugin 10', 'Plugin 9'), greaterThan(0));
    });

    test('空串 / 纯标点排最后', () {
      expect(TextCollation.compare('', 'Acme'), greaterThan(0));
      expect(TextCollation.compare('---', 'Acme'), greaterThan(0));
    });

    test('标点差异不影响主键顺序', () {
      expect(TextCollation.compare('ACME Inc', 'ACME, Inc.'), isNot(0));
    });

    test('vendorKey：未知厂商归入空键', () {
      expect(TextCollation.vendorKey('Unknown'), '');
      expect(TextCollation.vendorKey('  '), '');
      expect(TextCollation.vendorKey('iZotope'), 'iZotope');
    });
  });

  group('PluginScanDirEntry', () {
    test('JSON 往返保持 path/enabled/builtin', () {
      const e = PluginScanDirEntry(
        path: r'C:\Plugins',
        enabled: false,
        builtin: true,
      );
      final r = PluginScanDirEntry.fromJson(e.toJson());
      expect(r.path, e.path);
      expect(r.enabled, isFalse);
      expect(r.builtin, isTrue);
    });

    test('缺省字段：enabled=true / builtin=false', () {
      final r = PluginScanDirEntry.fromJson({'path': '/x'});
      expect(r.enabled, isTrue);
      expect(r.builtin, isFalse);
    });
  });

  group('AppConfig 扫描目录迁移', () {
    test('旧 customPluginDirs → 启用且非内置条目', () {
      final cfg = AppConfig.fromJson({
        'version': 3,
        'paths': {
          'customPluginDirs': [r'D:\VST3', r'E:\Plugins'],
        },
      });
      expect(cfg.pluginScanDirs.length, 2);
      expect(cfg.pluginScanDirs.first.enabled, isTrue);
      expect(cfg.pluginScanDirs.first.builtin, isFalse);
      expect(cfg.pluginScanDirsSeeded, isFalse);
    });

    test('新格式往返（含 seeded 标记）', () {
      final cfg = AppConfig(
        pluginScanDirs: const [
          PluginScanDirEntry(path: '/a', enabled: true),
          PluginScanDirEntry(path: '/b', enabled: false),
          PluginScanDirEntry(path: '/builtin', builtin: true),
        ],
        pluginScanDirsSeeded: true,
      );
      final back = AppConfig.fromJson(cfg.toJson());
      expect(back.pluginScanDirs.length, 3);
      expect(back.pluginScanDirs[1].enabled, isFalse);
      expect(back.pluginScanDirs[2].builtin, isTrue);
      expect(back.pluginScanDirsSeeded, isTrue);
    });
  });

  group('PluginScanDirs.discoverFrom', () {
    test('只保留存在的目录并去重', () {
      final tmp = Directory.systemTemp.createTempSync('aura_scan_');
      try {
        final a = Directory('${tmp.path}${Platform.pathSeparator}a')
          ..createSync();
        final missing = '${tmp.path}${Platform.pathSeparator}missing';
        final found = PluginScanDirs.discoverFrom([
          a.path,
          a.path, // 重复
          missing, // 不存在
          '   ', // 空白
        ]);
        expect(found, [a.path]);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('PluginManager.pluginGroups', () {
    test('厂商字典序（未知沉底）+ 组内名称自然序', () {
      final m = PluginManager(commandSender: (_) {});
      final json = [
        _p('Zeta Verb', 'iZotope').toJson(),
        _p('Alpha EQ', 'acme').toJson(),
        _p('Plugin 10', 'acme').toJson(),
        _p('Plugin 2', 'acme').toJson(),
        _p('Nameless', '').toJson(),
      ];
      m.onPluginList(json);
      final groups = m.pluginGroups;
      expect(groups.keys.toList(), ['acme', 'iZotope', '']);
      expect(
        groups['acme']!.map((e) => e.name).toList(),
        ['Alpha EQ', 'Plugin 2', 'Plugin 10'],
      );
    });
  });
}
