// plugin_manager_tables.dart — 厂商表/编辑器隔离名单/崩溃日志（plugin_manager.dart 的 part，2026-10-28 拆分）。
part of 'plugin_manager.dart';

extension PluginManagerTables on PluginManager {
  // --- 插件级预设数据：厂商表 + 编辑器隔离名单 + 崩溃自动登记 ---

  /// 一次性加载 assets/presets/plugin_tables.json 的厂商表与隔离名单默认值，
  /// 与 config 增量合并后：把 close 名单推给引擎（跳过 removed()），
  /// 并检查上一进程的崩溃日志做自动登记。
  Future<void> loadPluginTables() async {
    if (_tablesLoaded) return;
    _tablesLoaded = true;
    Map<String, dynamic>? defaults;
    try {
      final raw = await rootBundle.loadString(
        'assets/presets/plugin_tables.json',
      );
      defaults = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e, st) {
      swallow(e, st);
      defaults = null;
    }
    final vt = (defaults?['vendorTable'] as Map?)?.cast<String, dynamic>();
    _vendorTable = vt?.map((k, v) => MapEntry(k, v as String)) ?? {};
    final defQ = (defaults?['editorQuarantine'] as Map?) ?? {};
    // 隔离名单：config 持久化优先；首次运行从资产默认值播种。
    if (!PluginManager._quarantineConfigFile().existsSync()) {
      _saveQuarantineLists(
        close: (defQ['close'] as List?)?.cast<String>() ?? const [],
        open: (defQ['open'] as List?)?.cast<String>() ?? const [],
      );
    }
    final cfg = _readQuarantineConfig();
    _closeQuarantine
      ..clear()
      ..addAll(cfg['close'] ?? const <String>[]);
    _openQuarantine
      ..clear()
      ..addAll(cfg['open'] ?? const <String>[]);
    _autoRegisterFromCrashJournal();
    _sendQuarantineToEngine();
    // 启动时若存在遗留的未清扫条目，才开启周期清扫；若本来就无日志，保持静默避免多余后台轮询
    if (PluginManager._editorJournalFile().existsSync()) {
      _startJournalTimerIfNeeded();
    }
    _notify();
  }

  /// 当前生效的编辑器关闭隔离名单（引擎跳过 removed()），小写子串。
  List<String> get closeQuarantine => List.unmodifiable(_closeQuarantine);

  /// 当前生效的编辑器打开隔离名单（应用阻止打开），小写子串。
  List<String> get openQuarantine => List.unmodifiable(_openQuarantine);

  /// 插件是否曾导致编辑器打开崩溃（仅用于提示，不阻止操作）。
  bool isEditorCrashKnown(PluginMetadata meta) {
    final ln = meta.name.toLowerCase();
    final lp = meta.path.toLowerCase();
    for (final p in _openQuarantine) {
      if (ln.contains(p)) return true;
      if (lp.contains(p)) return true;
    }
    return false;
  }

  void _sendQuarantineToEngine() {
    _commandSender?.call({
      'cmd': 'setEditorQuarantineList',
      'patterns': _closeQuarantine.join(','),
    });
  }

  Map<String, List<String>> _readQuarantineConfig() {
    try {
      final read = DocumentStore.readJson(
        PluginManager._quarantineConfigFile().path,
      );
      if (!read.ok) return {'close': const [], 'open': const []};
      final j = read.data!;
      return {
        'close': (j['close'] as List?)?.cast<String>() ?? const [],
        'open': (j['open'] as List?)?.cast<String>() ?? const [],
      };
    } catch (e, st) {
      swallow(e, st);
      return {'close': const [], 'open': const []};
    }
  }

  void _saveQuarantineLists({
    required List<String> close,
    required List<String> open,
  }) {
    try {
      ConfigManager.writeJsonFile(
        PluginManager._quarantineConfigFile().path,
        {
          'close': close.where((p) => p.isNotEmpty).toSet().toList(),
          'open': open.where((p) => p.isNotEmpty).toSet().toList(),
        },
      );
    } catch (e) {
      dbgLog('[PluginManager] quarantine config save failed: $e');
    }
  }

  /// 厂商表填充：命中即覆盖引擎 vendor 字段（数据驱动，引擎不硬编码厂商名）。
  String? _vendorLookup(PluginMetadata meta) =>
      matchVendorIn(_vendorTable, meta.name, meta.path);

  /// 崩溃日志：记录「正在打开该插件编辑器」。进程若在健康期内退出
  /// （未及 sweep 移除），下次启动自动登记。
  void _journalEditorOpened(PluginMetadata meta) {
    try {
      final path = PluginManager._editorJournalFile().path;
      final existing = List<dynamic>.from(
        DocumentStore.readJsonList(path) ?? const <dynamic>[],
      );
      existing.removeWhere((e) => e is Map && e['path'] == meta.path);
      existing.add({
        'path': meta.path,
        'name': meta.name,
        'openedAt': DateTime.now().millisecondsSinceEpoch,
      });
      DocumentStore.writeJson(path, existing);
      // 写入日志后确保清扫定时器已激活
      _startJournalTimerIfNeeded();
    } catch (e, st) { swallow(e, st); }
  }

  /// 周期清扫：打开超过 PluginManager.kOpenHealthyMs 的条目视为「打开成功」，从日志移除。
  void sweepEditorJournal() {
    try {
      final path = PluginManager._editorJournalFile().path;
      final j = DocumentStore.readJsonList(path);
      if (j == null) {
        // 缺失/坏格式：坏文件直接清掉，等待下次重建
        DocumentStore.delete(path);
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final alive = j.where((e) {
        if (e is! Map) return false;
        final t = e['openedAt'];
        return t is int && (now - t) < PluginManager.kOpenHealthyMs;
      }).toList();
      if (alive.isEmpty) {
        DocumentStore.delete(path);
      } else {
        DocumentStore.writeJson(path, alive);
      }
    } catch (e, st) { swallow(e, st); }
  }

  /// 启动时检查崩溃日志：上一进程在编辑器打开后未健康化前退出（打开即崩溃）
  /// → 自动把该插件登记进 open 名单并持久化。登记后清空日志。
  void _autoRegisterFromCrashJournal() {
    List<String> crashed = [];
    try {
      final path = PluginManager._editorJournalFile().path;
      final j = DocumentStore.readJsonList(path);
      if (j == null) {
        DocumentStore.delete(path);
        return;
      }
      for (final e in j) {
        if (e is! Map) continue;
        final p = _crashPattern(e['name'] as String?, e['path'] as String?);
        if (p != null && p.isNotEmpty) crashed.add(p);
      }
      DocumentStore.delete(path);
    } catch (e, st) { swallow(e, st); }
    if (crashed.isEmpty) return;
    var changed = false;
    for (final c in crashed) {
      final lp = c.toLowerCase();
      if (!_openQuarantine.any((e) => e.toLowerCase() == lp)) {
        _openQuarantine.add(lp);
        changed = true;
      }
      // 崩溃历史同时进入 close 名单：下次关闭该插件时跳过其自身 teardown。
      if (!_closeQuarantine.any((e) => e.toLowerCase() == lp)) {
        _closeQuarantine.add(lp);
        changed = true;
      }
    }
    if (changed) {
      _saveQuarantineLists(close: _closeQuarantine, open: _openQuarantine);
      _lastNotice =
          '检测到 ${crashed.length} 个插件上次在打开编辑器后崩溃，'
          '已记录到隔离名单；它们仍可加载，关闭时将使用安全 teardown。';
      _notify();
    }
  }

  static String? _crashPattern(String? name, String? path) {
    if (name != null && name.trim().isNotEmpty) return name.trim();
    if (path != null && path.trim().isNotEmpty) {
      final stem = path.trim().split(RegExp(r'[\\/]')).last;
      final dot = stem.lastIndexOf('.');
      return dot > 0 ? stem.substring(0, dot) : stem;
    }
    return null;
  }

  /// 按需启动崩溃日志清扫定时器（若尚未运行）。
  /// 仅在有日志文件需要清扫时才持有 Timer，以避免无谓的后台轮询。
  void _startJournalTimerIfNeeded() {
    if (_journalTimer != null) return; // 已在运行
    _journalTimer = Timer.periodic(
      const Duration(milliseconds: PluginManager.kOpenHealthyMs),
      (_) {
        sweepEditorJournal();
        // 若日志文件已不存在，则停止定时器，减少资源占用
        if (!PluginManager._editorJournalFile().existsSync()) {
          _journalTimer?.cancel();
          _journalTimer = null;
        }
      },
    );
  }
}

/// 厂商表匹配（纯函数，2026-10-28 加固 —— 替代裸子串）。
///
/// 规则：
/// 1. 名称**整体前缀**命中（`KV-Element` ← `kv-element`，保留连字符键）；
/// 2. 名称按非字母数字切词后**词首前缀**命中（`Zebra2` ← `zebra`）；
/// 3. 路径按目录段前缀命中（`...\u-he\Zebra2.vst3` ← `u-he`）；
/// 4. 多个 key 同时命中取**最长**者（等长按字典序），消除对 JSON 键序的
///    隐式依赖。
///
/// 为什么废弃裸子串：`hive` ⊂ `archive`、`element` ⊂ `Elements` 这类误归厂商
/// 无法从代码层拦，而厂商名会直接显示在插件列表里。
String? matchVendorIn(Map<String, String> table, String name, String path) {
  if (table.isEmpty) return null;
  final ln = name.toLowerCase();
  final lp = path.toLowerCase();
  final nameTokens =
      ln.split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).toList();
  final pathSegments =
      lp.split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty).toList();

  String? bestKey;
  String? bestVendor;
  for (final e in table.entries) {
    final k = e.key.toLowerCase();
    if (k.isEmpty) continue;
    final hit = ln.startsWith(k) ||
        nameTokens.any((t) => t.startsWith(k)) ||
        pathSegments.any((s) => s.startsWith(k));
    if (!hit) continue;
    if (bestKey == null ||
        k.length > bestKey.length ||
        (k.length == bestKey.length && k.compareTo(bestKey) < 0)) {
      bestKey = k;
      bestVendor = e.value;
    }
  }
  return bestVendor;
}
