/*
 * plugin_manager_test.dart — 插件管理器与数据模型单元测试
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/plugin_manager.dart';

void main() {
  group('PluginFormat & Metadata Tests', () {
    test('PluginFormat should correctly identify formats', () {
      expect(PluginFormat.fromString('vst3'), PluginFormat.vst3);
      expect(PluginFormat.fromString('VST3'), PluginFormat.vst3);
      expect(PluginFormat.fromString('clap'), PluginFormat.clap);
      expect(PluginFormat.fromString('CLAP'), PluginFormat.clap);
      expect(PluginFormat.fromString('unknown_fmt'), PluginFormat.unknown);
    });

    test('PluginMetadata fromJson and toJson roundtrip', () {
      final json = {
        'id': 'abc-123',
        'name': 'Test Reverb',
        'vendor': 'AudioCorp',
        'version': '1.2.0',
        'category': 'Reverb',
        'format': 'VST3',
        'path': r'C:\Plugins\TestReverb.vst3',
        'isCompatible': true,
        'errorMessage': '',
      };

      final meta = PluginMetadata.fromJson(json);
      expect(meta.id, 'abc-123');
      expect(meta.name, 'Test Reverb');
      expect(meta.vendor, 'AudioCorp');
      expect(meta.version, '1.2.0');
      expect(meta.format, PluginFormat.vst3);
      expect(meta.path, r'C:\Plugins\TestReverb.vst3');

      final serialized = meta.toJson();
      expect(serialized['id'], 'abc-123');
      expect(serialized['name'], 'Test Reverb');
      expect(serialized['format'], 'VST3');
    });

    test('PluginHostStatus parsing', () {
      final statusJson = {
        'hasActive': true,
        'bypassed': false,
        'latency': 288,
        'plugin': {
          'id': 'vst3-456',
          'name': 'ValhallaSupermassive',
          'vendor': 'Valhalla DSP',
          'version': '3.0.0',
          'category': 'Fx',
          'format': 'VST3',
          'path': r'C:\Program Files\Common Files\VST3\ValhallaSupermassive.vst3',
          'isCompatible': true,
          'errorMessage': '',
        }
      };

      final status = PluginHostStatus.fromJson(statusJson);
      expect(status.hasActive, isTrue);
      expect(status.bypassed, isFalse);
      expect(status.latency, 288);
      expect(status.plugin, isNotNull);
      expect(status.plugin!.name, 'ValhallaSupermassive');
      expect(status.plugin!.format, PluginFormat.vst3);
    });
  });

  group('PluginManager State & Filtering Tests', () {
    late PluginManager manager;
    late List<Map<String, dynamic>> dispatchedCmds;

    setUp(() {
      dispatchedCmds = [];
      manager = PluginManager(commandSender: (msg) {
        dispatchedCmds.add(msg);
      });
    });

    test('PluginManager command dispatching', () {
      manager.scan(deep: true);
      expect(dispatchedCmds.length, 1);
      expect(dispatchedCmds.first['cmd'], 'pluginScan');
      expect(dispatchedCmds.first['deep'], isTrue);

      manager.unloadPlugin();
      expect(dispatchedCmds.last['cmd'], 'pluginUnload');

      manager.setBypass(true);
      expect(dispatchedCmds.last['cmd'], 'pluginSetBypass');
      expect(dispatchedCmds.last['bypass'], isTrue);
    });

    test('PluginManager event handling and filtering', () {
      final samplePlugins = [
        {
          'id': '1',
          'name': 'ValhallaSupermassive',
          'vendor': 'Valhalla DSP',
          'version': '3.0',
          'format': 'VST3',
          'path': r'C:\VST3\Valhalla.vst3',
        },
        {
          'id': '2',
          'name': 'FabFilter Pro-Q 3',
          'vendor': 'FabFilter',
          'version': '3.1',
          'format': 'VST3',
          'path': r'C:\VST3\FabFilter.vst3',
        },
        {
          'id': '3',
          'name': 'Kushview Element FX',
          'vendor': 'Kushview',
          'version': '1.0',
          'format': 'CLAP',
          'path': r'C:\CLAP\Element.clap',
        },
      ];

      manager.onPluginScanned(3, samplePlugins);
      expect(manager.countAll, 3);
      expect(manager.countVst3, 2);
      expect(manager.countClap, 1);
      expect(manager.filteredPlugins.length, 3);

      // Filter by VST3
      manager.setFilterFormat('vst3');
      expect(manager.filteredPlugins.length, 2);
      expect(manager.filteredPlugins.every((p) => p.format == PluginFormat.vst3), isTrue);

      // Filter by CLAP
      manager.setFilterFormat('clap');
      expect(manager.filteredPlugins.length, 1);
      expect(manager.filteredPlugins.first.name, 'Kushview Element FX');

      // Reset format, search query
      manager.setFilterFormat('all');
      manager.setSearchQuery('fab');
      expect(manager.filteredPlugins.length, 1);
      expect(manager.filteredPlugins.first.name, 'FabFilter Pro-Q 3');

      manager.setSearchQuery('non-existent');
      expect(manager.filteredPlugins.isEmpty, isTrue);
    });

    test('PluginManager load and bypass reactive status', () {
      expect(manager.hasActivePlugin, isFalse);

      final statusJson = {
        'hasActive': true,
        'bypassed': false,
        'latency': 128,
        'plugin': {
          'id': 'p1',
          'name': 'Test Reverb',
          'format': 'VST3',
          'path': r'C:\Test.vst3',
        }
      };

      manager.onPluginLoaded(r'C:\Test.vst3', 1, statusJson);
      expect(manager.hasActivePlugin, isTrue);
      expect(manager.activePlugin?.name, 'Test Reverb');
      expect(manager.currentLatency, 128);
      expect(manager.isBypassed, isFalse);

      // Bypass
      final bypassedJson = Map<String, dynamic>.from(statusJson);
      bypassedJson['bypassed'] = true;
      manager.onPluginBypass(true, bypassedJson);
      expect(manager.isBypassed, isTrue);

      // Unload
      final unloadedJson = {
        'hasActive': false,
        'bypassed': false,
        'latency': 0,
        'plugin': null,
      };
      manager.onPluginUnloaded(1, unloadedJson);
      expect(manager.hasActivePlugin, isFalse);
      expect(manager.activePlugin, isNull);
    });
  });
}
