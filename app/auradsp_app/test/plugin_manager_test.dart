/*
 * plugin_manager_test.dart — 插件管理器与数据模型单元测试
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/plugin_manager.dart';

void main() {
  // rootBundle（assets/presets/plugin_tables.json）在纯 test() 下需要
  // TestWidgetsFlutterBinding 初始化才有可用的资产束。
  TestWidgetsFlutterBinding.ensureInitialized();

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
        'name': 'Element FX',
        'vendor': 'Kushview',
        'version': '1.0.0',
        'category': 'audio-effect',
        'bundleName': 'KV-Element-FX',
        'description': 'KV-Element-FX',
        'format': 'CLAP',
        'path': r'C:\CLAP\KV-Element-FX.clap',
        'isCompatible': true,
        'errorMessage': '',
      };

      final meta = PluginMetadata.fromJson(json);
      expect(meta.id, 'abc-123');
      expect(meta.name, 'Element FX');
      expect(meta.vendor, 'Kushview');
      expect(meta.version, '1.0.0');
      expect(meta.category, 'audio-effect');
      // B1：自报名与 bundle 名是两个字段，不可互相顶替
      expect(meta.bundleName, 'KV-Element-FX');
      expect(meta.description, 'KV-Element-FX');
      expect(meta.format, PluginFormat.clap);
      expect(meta.path, r'C:\CLAP\KV-Element-FX.clap');

      final serialized = meta.toJson();
      expect(serialized['id'], 'abc-123');
      expect(serialized['name'], 'Element FX');
      expect(serialized['bundleName'], 'KV-Element-FX');
      expect(serialized['description'], 'KV-Element-FX');
      expect(serialized['format'], 'CLAP');
    });

    test('PluginHostStatus parsing', () {
      final statusJson = {
        'hasActive': true,
        'bypassed': false,
        'latency': 288,
        'remoteMode': true,
        'remoteFailed': true,
        'transportLatency': 128,
        'inputOverflows': 3,
        'outputOverflows': 5,
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
      expect(status.remoteMode, isTrue);
      expect(status.remoteFailed, isTrue);
      expect(status.transportLatency, 128);
      expect(status.inputOverflows, 3);
      expect(status.outputOverflows, 5);
      expect(status.plugin, isNotNull);
      expect(status.plugin!.name, 'ValhallaSupermassive');
      expect(status.plugin!.format, PluginFormat.vst3);
      expect(status.toJson()['remoteFailed'], isTrue);
    });
  });

  group('PluginManager State & Filtering Tests', () {
    late PluginManager manager;
    late List<Map<String, dynamic>> dispatchedCmds;
    late Directory tempDir;

    tearDownAll(() async {
      // B5 终局清扫兜底：个别测试收尾时仍有挂起的 saveCache 异步写，
      // 2s 重试预算也可能输给事件循环时序（实测每轮漏 1~2 个）。
      // 本组专用前缀 + flutter test 串行执行，清扫不会误伤别的运行。
      final temp = Directory.systemTemp;
      await for (final entity in temp.list(followLinks: false)) {
        if (entity is Directory &&
            entity.path.contains('auradsp_plugin_test')) {
          for (var i = 0; i < 20 && entity.existsSync(); i++) {
            try {
              entity.deleteSync(recursive: true);
              break;
            } on FileSystemException {
              await Future.delayed(const Duration(milliseconds: 50));
            }
          }
        }
      }
    });

    setUp(() {
      // flutter test 不沙箱化：不注入临时根目录的话，下面的 onPluginScanned()
      // 会经 saveCache() 把测试 fixture 写进用户真实的
      // %APPDATA%\AuraDSP\plugins\plugin_cache.json。
      tempDir = Directory.systemTemp.createTempSync('auradsp_plugin_test');
      ConfigManager.baseDirOverride = tempDir.path;
      dispatchedCmds = [];
      manager = PluginManager(commandSender: (msg) {
        dispatchedCmds.add(msg);
      });
    });

    tearDown(() async {
      ConfigManager.baseDirOverride = null;
      // Windows 上临时目录可能被杀软实时扫描/索引器或尚未收尾的异步写句柄
      // 短暂占用（errno 32 "另一个程序正在使用此文件"）。清理失败不该判红：
      // 有限重试后放弃，最坏漏下一个 Temp 目录（2026-10-12 审查修复的瞬态）。
      //
      // B5：重试必须用 `await Future.delayed` 而不是同步 `sleep()`——
      // saveCache 是 fire-and-forget 的异步写（writeAsString flush:true），
      // 同步睡眠不泵事件循环，挂起的写永远收不了尾、句柄一直开着，
      // 目录必然删不掉（实测每轮 flutter test 漏 4 个）。异步等待让
      // 挂起的 Future 完成、句柄释放，重试随即成功。
      for (var i = 0; i < 40 && tempDir.existsSync(); i++) {
        try {
          tempDir.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    test('PluginManager command dispatching', () async {
      manager.scan(deep: true);
      expect(dispatchedCmds.length, 1);
      expect(dispatchedCmds.first['cmd'], 'pluginScan');
      expect(dispatchedCmds.first['deep'], isTrue);

      manager.unloadPlugin();
      // 优雅卸载（2026-10-22）：先内部直通（该槽 bypass、链早退）让音频
      // 平滑过渡，150ms 后才真正卸载——大插件 teardown 2-3s 的扰动不再
      // 影响音频流。因此即时末条命令是 pluginSlotSetBypass。
      expect(dispatchedCmds.last['cmd'], 'pluginSlotSetBypass');
      expect(dispatchedCmds.last['slot'], 0);
      expect(dispatchedCmds.last['bypass'], isTrue);
      await Future.delayed(const Duration(milliseconds: 250));
      expect(dispatchedCmds.last['cmd'], 'pluginSlotUnload');
      expect(dispatchedCmds.last['slot'], 0);

      manager.setBypass(true);
      expect(dispatchedCmds.last['cmd'], 'pluginSlotSetBypass');
      expect(dispatchedCmds.last['slot'], 0);
      expect(dispatchedCmds.last['bypass'], isTrue);

      // Slot 1
      manager.selectSlot(1);
      expect(manager.selectedSlot, 1);
      manager.setInsertStage(PluginInsertStage.preDsp);
      expect(dispatchedCmds.last['cmd'], 'pluginSlotSetInsertStage');
      expect(dispatchedCmds.last['slot'], 1);
      expect(dispatchedCmds.last['stage'], PluginInsertStage.preDsp);

      // PDC
      manager.setPdc(true);
      expect(manager.pdcEnabled, isTrue);
      expect(dispatchedCmds.last['cmd'], 'pluginSetPdc');
      expect(dispatchedCmds.last['pdc'], isTrue);
      manager.onPluginPdc(true, 1);
      expect(manager.pdcEnabled, isTrue);
      manager.onPluginPdc(false, 1);
      expect(manager.pdcEnabled, isFalse);
    });

    test('D2: 32-bit incompatible plugin is intercepted before dispatch', () {
      final meta32 = PluginMetadata.fromJson({
        'id': 'x86-1',
        'name': 'Legacy 32bit FX',
        'vendor': 'LegacyCo',
        'version': '2.0',
        'format': 'VST3',
        'path': r'C:\VST3\Legacy.vst3',
        'isCompatible': false,
        'errorMessage': '32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本',
      });

      final before = dispatchedCmds.length;
      manager.loadPlugin(meta32);
      // 不派发 pluginSlotLoad —— Dart 侧直接拦截，引擎不被打扰
      expect(dispatchedCmds.length, before);
      // lastError 带精确原因 + 插件名前缀
      expect(manager.lastError, isNotNull);
      expect(manager.lastError, contains('Legacy 32bit FX'));
      expect(manager.lastError, contains('32 位'));

      // 兼容插件照常派发
      final metaOk = PluginMetadata.fromJson({
        'id': 'ok-1',
        'name': 'Good FX',
        'vendor': 'GoodCo',
        'version': '1.0',
        'format': 'VST3',
        'path': r'C:\VST3\Good.vst3',
        'isCompatible': true,
      });
      manager.loadPlugin(metaOk);
      expect(dispatchedCmds.length, before + 1);
      expect(dispatchedCmds.last['cmd'], 'pluginSlotLoad');
      expect(manager.lastError, isNull);
    });

    test('D2: onPluginSlotLoaded surfaces engine 32-bit error verbatim', () {
      // 扫描列表里已带 32 位不兼容条目；即便有其它路径绕过 Dart 拦截
      // 走到引擎、被引擎 load() 拒绝（rc=0），错误文案也取引擎原话，
      // 不再显示"可能位数不符"的猜测文本（A5 旧文案）。
      manager.onPluginScanned(1, jsonEncode([
        {
          'id': 'x86-1',
          'name': 'Legacy 32bit FX',
          'vendor': 'LegacyCo',
          'version': '2.0',
          'format': 'VST3',
          'path': r'C:\VST3\Legacy.vst3',
          'isCompatible': false,
          'errorMessage': '32 位插件无法加载：AuraDSP 是 64 位进程，请安装 64 位版本',
        }
      ]));
      manager.onPluginSlotLoaded(0, r'C:\VST3\Legacy.vst3', 0, '{}', 3);
      expect(manager.lastError, contains('Legacy 32bit FX'));
      expect(manager.lastError, contains('32 位插件无法加载'));

      // 未知路径的失败仍走通用推断（A5 行为不回退：磁盘上不存在时
      // 给"文件不存在"文案，存在但加载失败时给"无法完成初始化"文案）
      manager.onPluginSlotLoaded(0, r'C:\VST3\Unknown.vst3', 0, '{}', 3);
      expect(manager.lastError, contains('插件文件不存在或已被移动'));
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

    test('loadCache 丢弃旧版裸 list 缓存，不呈现陈旧数据（B1 专题四回归）', () async {
      final cacheFile = File('${tempDir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}plugin_cache.json');
      cacheFile.parent.createSync(recursive: true);
      // 审查加固（失败注入发现）：条目路径必须是**磁盘上真实存在**的文件。
      // 旧版用 C:\VST3\DefinitelyNotInstalled.vst3 —— 即便 schema 门禁被旁路，
      // 条目也会被 _dropMissingPaths 清掉，测试照样绿，门禁机制未被钉住。
      // 现存路径下，只有"门禁真的在拦"才能得到空结果。
      final legacyPlugin =
          File('${tempDir.path}${Platform.pathSeparator}legacy.vst3');
      legacyPlugin.writeAsStringSync('stub');
      final legacy = [
        {
          'id': '1',
          'name': 'Ghost Plugin',
          'vendor': 'nobody',
          'version': '1.0',
          'category': '',
          'format': 'VST3',
          'path': legacyPlugin.path,
          'isCompatible': true,
          'errorMessage': '',
        },
      ];
      cacheFile.writeAsStringSync(jsonEncode(legacy));

      await manager.loadCache();

      expect(manager.plugins, isEmpty,
          reason: '无 schema 戳的旧缓存必须整份丢弃，由重新扫描重建');
      // 丢弃但不改写：文件保持原样，避免把丢弃动作固化成新缓存
      final after = jsonDecode(cacheFile.readAsStringSync());
      expect(after, isA<List>());
      expect((after as List).length, 1);
    });

    test('loadCache 接受 schema=2 信封并加载有效条目', () async {
      final realPlugin = File('${tempDir.path}${Platform.pathSeparator}real.vst3');
      realPlugin.writeAsStringSync('stub');
      final cacheFile = File('${tempDir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}plugin_cache.json');
      cacheFile.parent.createSync(recursive: true);
      cacheFile.writeAsStringSync(jsonEncode({
        'schema': 2,
        'scannedAt': '2026-10-12T01:00:00',
        'deep': true,
        'plugins': [
          {
            'id': 'abc',
            'name': 'Real Plugin',
            'vendor': 'RealVendor',
            'version': '2.0',
            'category': 'Fx',
            'bundleName': 'real',
            'description': '',
            'format': 'VST3',
            'path': realPlugin.path,
            'isCompatible': true,
            'errorMessage': '',
          },
        ],
      }));

      await manager.loadCache();

      expect(manager.plugins.length, 1);
      expect(manager.plugins.first.name, 'Real Plugin');
      expect(manager.plugins.first.bundleName, 'real');
    });

    test('loadCache 丢弃被篡改 schema 的缓存（陈旧数据不得赢过实时状态）', () async {
      final cacheFile = File('${tempDir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}plugin_cache.json');
      cacheFile.parent.createSync(recursive: true);
      // 审查加固（失败注入发现）：旧版条目用不存在的 C:\VST3\Stale.vst3，
      // 门禁被旁路时条目会被 _dropMissingPaths 清掉 → 测试照样绿。
      // 改用真实文件后，只有 schema 门禁真的在拦才能得到空结果。
      final stalePlugin =
          File('${tempDir.path}${Platform.pathSeparator}stale.vst3');
      stalePlugin.writeAsStringSync('stub');
      cacheFile.writeAsStringSync(jsonEncode({
        'schema': 1, // 被改过的版本戳
        'scannedAt': '2026-10-12T01:00:00',
        'deep': false,
        'plugins': [
          {
            'id': 'x',
            'name': 'Stale Entry',
            'vendor': 'StaleVendor',
            'version': '9.9',
            'category': 'Fx',
            'format': 'VST3',
            'path': stalePlugin.path,
            'isCompatible': true,
            'errorMessage': '',
          },
        ],
      }));

      await manager.loadCache();

      expect(manager.plugins, isEmpty);
    });

    test('loadCache 按 path+format 去重', () async {
      final realPlugin = File('${tempDir.path}${Platform.pathSeparator}dup.vst3');
      realPlugin.writeAsStringSync('stub');
      final cacheFile = File('${tempDir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}plugin_cache.json');
      cacheFile.parent.createSync(recursive: true);
      cacheFile.writeAsStringSync(jsonEncode({
        'schema': 2,
        'scannedAt': '2026-10-12T01:00:00',
        'deep': false,
        'plugins': [
          {
            'id': 'a',
            'name': 'Dup',
            'vendor': 'V',
            'version': '1',
            'format': 'VST3',
            'path': realPlugin.path,
          },
          {
            'id': 'b',
            'name': 'Dup Again',
            'vendor': 'V',
            'version': '1',
            'format': 'VST3',
            'path': realPlugin.path,
          },
        ],
      }));

      await manager.loadCache();

      expect(manager.plugins.length, 1,
          reason: '同一 path+format 只保留一条，唯一键不允许重复');
    });

    test('onPluginScanned 落盘为 schema=2 信封且只写测试临时目录'
        '（A 根因回归 + B1 信封化）', () async {
      manager.onPluginScanned(1, [
        {
          'id': '1',
          'name': 'Fixture Plugin',
          'vendor': 'x',
          'version': '1.0',
          'category': '',
          'format': 'VST3',
          'path': r'C:\VST3\Fixture.vst3',
          'isCompatible': true,
          'errorMessage': '',
        },
      ]);
      // saveCache() 是异步且 onPluginScanned 不 await，轮询等文件落盘
      final tmpCache = File('${tempDir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}plugin_cache.json');
      for (var i = 0; i < 100 && !tmpCache.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // 轮询只保证文件已被 open（创建即存在），内容可能仍在写 —— 沉降后再读，
      // 否则可能读到半个 JSON（竞态瞬态，2026-10-12 审查修复）。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tmpCache.existsSync(), isTrue);
      expect(manager.plugins.length, 1);

      final envelope = jsonDecode(tmpCache.readAsStringSync()) as Map;
      expect(envelope['schema'], 2);
      expect(envelope['plugins'], isA<List>());
      expect((envelope['plugins'] as List).length, 1);
      expect(envelope['deep'], isFalse);
      expect(envelope['scannedAt'], isA<String>());
    });

    test('saveCache 自检：vendor 全空/Unknown 的快照拒绝落盘'
        '（伪造缓存签名回归）', () async {
      manager.onPluginScanned(2, [
        {
          'id': '1',
          'name': 'Fake One',
          'vendor': 'Unknown',
          'version': '1.0',
          'category': '',
          'format': 'VST3',
          'path': r'C:\VST3\Fake1.vst3',
          'isCompatible': true,
          'errorMessage': '',
        },
        {
          'id': '2',
          'name': 'Fake Two',
          'vendor': '',
          'version': '1.0',
          'category': '',
          'format': 'VST3',
          'path': r'C:\VST3\Fake2.vst3',
          'isCompatible': true,
          'errorMessage': '',
        },
      ]);
      final tmpCache = File('${tempDir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}plugin_cache.json');
      // 轮询足够久，确认文件始终不出现
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(tmpCache.existsSync(), isFalse,
          reason: '全 Unknown 快照是伪造/损坏缓存的签名，不得固化');
      // 内存态仍然可用（自检只拦截落盘，不影响本次会话）
      expect(manager.plugins.length, 2);
    });

    test('saveCache 按 path+format 去重', () async {
      manager.onPluginScanned(2, [
        {
          'id': 'a',
          'name': 'Dup',
          'vendor': 'V',
          'version': '1',
          'format': 'VST3',
          'path': r'C:\VST3\Same.vst3',
        },
        {
          'id': 'b',
          'name': 'Dup Again',
          'vendor': 'V',
          'version': '1',
          'format': 'VST3',
          'path': r'C:\VST3\Same.vst3',
        },
      ]);
      final tmpCache = File('${tempDir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}plugin_cache.json');
      for (var i = 0; i < 100 && !tmpCache.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // 同上：等文件出现后仍需沉降，避免读到写一半的内容。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tmpCache.existsSync(), isTrue);
      final envelope = jsonDecode(tmpCache.readAsStringSync()) as Map;
      expect((envelope['plugins'] as List).length, 1);
    });
  });

  group('插件级预设数据：厂商表 / 隔离名单 / 崩溃自动登记', () {
    tearDown(() {
      final pd = Directory(ConfigManager.path('plugin_data'));
      if (pd.existsSync()) pd.deleteSync(recursive: true);
    });

    test('loadPluginTables 从资产播种隔离名单默认值（close 含 zebra2）', () async {
      final m = PluginManager();
      await m.loadPluginTables();
      expect(m.closeQuarantine, contains('zebra2'));
      expect(m.openQuarantine, isEmpty);
      m.dispose();
    });

    test('厂商表覆盖引擎 vendor（Zebra2 → u-he）', () async {
      final m = PluginManager();
      await m.loadPluginTables();
      m.onPluginScanned(1, jsonEncode([
        {
          'id': 'z2',
          'name': 'Zebra2(x64)',
          'vendor': 'Uhe_Zebra_Legacy_v2.9.3',
          'format': 'VST3',
          'path': r'C:\VST3\Zebra2(x64).vst3',
        },
      ]));
      expect(m.plugins.single.vendor, 'u-he');
      m.dispose();
    });

    test('打开崩溃日志 → 自动登记 open+close 名单并清空日志', () async {
      final pd = Directory(ConfigManager.path('plugin_data'));
      pd.createSync(recursive: true);
      final journal = File(ConfigManager.path(
          'plugin_data${Platform.pathSeparator}editor_journal.json'));
      journal.writeAsStringSync(jsonEncode([
        {
          'path': r'C:\VST3\Crashy.vst3',
          'name': 'Crashy Plugin',
          'openedAt': DateTime.now()
              .subtract(const Duration(seconds: 5))
              .millisecondsSinceEpoch,
        },
      ]));
      final m = PluginManager();
      await m.loadPluginTables();
      expect(
        m.openQuarantine.map((p) => p.toLowerCase()),
        contains('crashy plugin'),
        reason: '打开即崩溃的插件应自动登记进 open 名单（仅提示）',
      );
      expect(
        m.closeQuarantine.map((p) => p.toLowerCase()),
        contains('crashy plugin'),
        reason: '崩溃历史必须同时进入 close 名单，关闭时跳过插件 teardown',
      );
      expect(m.lastNotice, isNotNull);
      expect(journal.existsSync(), isFalse, reason: '登记后日志应清空');
      m.dispose();
    });

    test('历史崩溃插件仍允许 showEditor，只提示不阻止', () async {
      final pd = Directory(ConfigManager.path('plugin_data'));
      pd.createSync(recursive: true);
      final journal = File(ConfigManager.path(
          'plugin_data${Platform.pathSeparator}editor_journal.json'));
      journal.writeAsStringSync(jsonEncode([
        {
          'path': r'C:\VST3\Crashy.vst3',
          'name': 'Crashy Plugin',
          'openedAt': DateTime.now().millisecondsSinceEpoch,
        },
      ]));
      final sent = <Map<String, dynamic>>[];
      final m = PluginManager(commandSender: sent.add);
      await m.loadPluginTables();
      m.onPluginSlotLoaded(0, r'C:\VST3\Crashy.vst3', 1, {
        'hasActive': true,
        'bypassed': false,
        'latency': 0,
        'plugin': {
          'id': 'c',
          'name': 'Crashy Plugin',
          'vendor': '',
          'category': '',
          'format': 'VST3',
          'path': r'C:\VST3\Crashy.vst3',
        },
      }, 3);
      final meta = m.getSlotPlugin(0)!;
      expect(m.isEditorCrashKnown(meta), isTrue);
      expect(m.isEditorOpenBlocked(meta), isFalse);
      sent.clear();
      m.showEditor(slot: 0);
      expect(
        sent.any((c) => c['cmd'] == 'pluginSlotShowEditor'),
        isTrue,
        reason: '历史崩溃不得再阻止打开编辑器',
      );
      expect(m.lastNotice, contains('Crashy Plugin'));
      m.dispose();
    });
  });

  // F-3（2026-10-23 审查）：VB 多总线模式下 -1 不是合法路——桥按「单组 0」
  // 语义把它落成 eng[0]，与 route 0 的独立预设互相覆盖（自我强化循环）。
  // 判据：VB 下 -1 路既不落盘也不恢复；各路（g>=0）与非 VB 路径不受影响。
  group('F-3: VB 多总线模式下 -1 路不是合法路', () {
    late PluginManager m;
    late List<Map<String, dynamic>> sent;
    late Directory tempDir;

    void markActive() {
      m.onPluginSlotLoaded(0, r'C:\VST3\F3.vst3', 1, {
        'hasActive': true,
        'bypassed': false,
        'latency': 0,
        'plugin': {
          'id': 'f3',
          'name': 'F3 Probe',
          'vendor': '',
          'category': '',
          'format': 'VST3',
          'path': r'C:\VST3\F3.vst3',
        },
      }, 3);
    }

    setUp(() {
      // 不沙箱化会写进真实 %APPDATA%（与既有组同款注入）。
      tempDir = Directory.systemTemp.createTempSync('auradsp_plugin_test');
      ConfigManager.baseDirOverride = tempDir.path;
      sent = [];
      m = PluginManager(commandSender: sent.add);
    });

    tearDown(() {
      ConfigManager.baseDirOverride = null;
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('非 VB：autoSaveAb 走 -1 路（既有行为不变）', () {
      markActive();
      m.setVbMultiBus(false);
      sent.clear();
      m.autoSaveAb(0);
      final saves =
          sent.where((c) => c['cmd'] == 'pluginSlotSavePresetG').toList();
      expect(saves.length, 1);
      expect(saves.single['group'], -1);
    });

    test('VB：autoSaveAb(-1) 跳过（不落盘 eng[0]）', () {
      markActive();
      m.setVbMultiBus(true);
      sent.clear();
      m.autoSaveAb(0);
      expect(sent.where((c) => c['cmd'] == 'pluginSlotSavePresetG'), isEmpty,
          reason: 'VB 下 -1 落盘会被桥写成 eng[0]（F-3）');
    });

    test('VB：autoSaveAb(g=2) 各路独立照常落盘', () {
      markActive();
      m.setVbMultiBus(true);
      sent.clear();
      m.autoSaveAb(0, group: 2);
      final saves =
          sent.where((c) => c['cmd'] == 'pluginSlotSavePresetG').toList();
      expect(saves.length, 1);
      expect(saves.single['group'], 2);
    });

    test('VB：setSlotChannels(group:-1) no-op；g>=0 正常下发', () {
      markActive();
      m.setVbMultiBus(true);
      sent.clear();
      m.setSlotChannels(0x03);
      expect(sent.where((c) => c['cmd'] == 'pluginSlotSetChannels'), isEmpty,
          reason: 'VB 下未选路（-1）不应写 eng[0]');
      m.setSlotChannels(0x05, group: 1);
      final sets =
          sent.where((c) => c['cmd'] == 'pluginSlotSetChannels').toList();
      expect(sets.length, 1);
      expect(sets.single['group'], 1);
    });

    test('VB：重挂恢复不含 -1 路（route 0 不被 eng[0] 快照覆盖）', () {
      markActive();
      // 1) 非 VB 下保存 -1 路（写 meta hasState=true）
      m.setVbMultiBus(false);
      m.autoSaveAb(0);
      // 2) 切 VB 后重挂 → 恢复路径不得下发 group=-1
      m.setVbMultiBus(true);
      sent.clear();
      markActive();
      final loads =
          sent.where((c) => c['cmd'] == 'pluginSlotLoadPresetG').toList();
      expect(loads, isEmpty,
          reason: 'VB 下 -1 不是合法路：恢复它会以「单组 0」写 eng[0]，'
              '覆盖 route 0 的独立预设（F-3）');
    });

    test('F-7：setSlotChannels 回执 rc!=1 回滚乐观写入', () {
      markActive();
      m.setVbMultiBus(false);
      // 先建立基准值（rc=1 确认）
      m.setSlotChannels(0x0F, group: 0);
      m.onPluginSlotChannels(0, 0x0F, 1, group: 0);
      expect(m.getSlotChannels(0, group: 0), 0x0F);
      // 乐观写入 0x03 → 引擎拒收 → 必须回到 0x0F
      m.setSlotChannels(0x03, group: 0);
      expect(m.getSlotChannels(0, group: 0), 0x03,
          reason: '乐观写入先于回执（UI 即时反馈）');
      m.onPluginSlotChannels(0, 0x03, 0, group: 0);
      expect(m.getSlotChannels(0, group: 0), 0x0F,
          reason: 'F-7：引擎拒收必须回滚，否则 UI 记忆与实际生效不一致');
    });

    test('F-8：setSlotChannels 拒绝非法 group（-2 哨兵）', () {
      markActive();
      sent.clear();
      m.setSlotChannels(0x03, group: kVbRouteUnselected);
      expect(sent.where((c) => c['cmd'] == 'pluginSlotSetChannels'), isEmpty,
          reason: 'F-8：-2 不是合法路，静默走错分支属误用');
      m.setSlotChannels(0x03, group: 7);   // 上界合法
      expect(
          sent.where((c) => c['cmd'] == 'pluginSlotSetChannels').length, 1);
    });

    test('F-6：seedRouteChannels 播种各路 Ch 记忆', () {
      markActive();
      m.seedRouteChannels(0, [0x01, 0x02, 0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
      expect(m.getSlotChannels(0, group: 0), 0x01);
      expect(m.getSlotChannels(0, group: 2), 0x03);
      expect(m.getSlotChannels(0, group: 3), 0xFF);
    });

    test('非 VB：重挂恢复包含 -1 路（对照，行为不变）', () {
      markActive();
      m.setVbMultiBus(false);
      m.autoSaveAb(0);
      sent.clear();
      markActive();
      final loads =
          sent.where((c) => c['cmd'] == 'pluginSlotLoadPresetG').toList();
      expect(loads.where((c) => c['group'] == -1), isNotEmpty,
          reason: '非 VB 单引擎下 -1 仍是唯一合法路');
    });
  });
}
