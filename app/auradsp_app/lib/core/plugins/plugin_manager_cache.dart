// plugin_manager_cache.dart — 本地磁盘缓存持久化（plugin_manager.dart 的 part，2026-10-28 拆分）。
part of 'plugin_manager.dart';

extension PluginManagerCache on PluginManager {
  // --- 本地磁盘缓存持久化 ---

  /// 缓存信封结构版本（B1 专题四）。
  ///
  /// 病史：plugin_cache.json 曾是裸 list、无版本戳，loadCache() 无条件全量
  /// 加载；2026-10-10 缓存被 3 条伪造数据覆盖后长期压制真实扫描结果
  /// （E-5：mtime 2026-10-10、76 条 vendor 全为字面量 "Unknown"、id 全空）。
  /// 现行约定：
  ///   1. 落盘一律写信封 {schema, scannedAt, deep, plugins}；
  ///   2. 读盘校验 schema，不符（旧裸 list / 被篡改）即整份丢弃，
  ///      不呈现陈旧数据，由下一次扫描重建；
  ///   3. 落盘前自检：非空快照若 vendor 全为 Unknown/空则拒绝写回
  ///      （伪造/损坏缓存的签名）；
  ///   4. 条目唯一键 = path + format。
  static const int kCacheSchemaVersion = 2;

  static File _getCacheFile() => File(
    ConfigManager.path('plugins${Platform.pathSeparator}plugin_cache.json'),
  );

  /// 剔除磁盘路径已不存在的条目，并按 path+format 去重，返回被剔除的数量。
  ///
  /// A3/A4：缓存可能被手工改写，或插件在扫描后被卸载/移动。曾出现缓存只剩
  /// 3 条伪造路径（C:\VST3\...，丢失 Program Files\Common Files）而真实扫描
  /// 有 76 个，用户因此看到 3 个永远加载不了的插件。启动路径不在音频线程，
  /// 此处的同步 IO 是安全的。
  int _dropMissingPaths() {
    if (_plugins.isEmpty) return 0;
    final before = _plugins.length;
    final seen = <String>{};
    _plugins = _plugins
        .where(
          (p) =>
              p.path.isNotEmpty &&
              File(p.path).existsSync() &&
              seen.add('${p.path}\u0000${p.format.label}'),
        )
        .toList();
    return before - _plugins.length;
  }

  /// 加载磁盘缓存（启动时秒级恢复历史扫描结果）。
  /// schema 不符的缓存整份丢弃——宁可重启后为空等重扫，也不展示陈旧数据。
  Future<void> loadCache() async {
    try {
      final read = DocumentStore.readJson(_getCacheFile().path);
      if (!read.ok) {
        // 缺文件 / 坏 JSON / 超大文件：一律等重扫，不呈现陈旧数据。
        return;
      }
      final decoded = read.data!;
      if (decoded['schema'] != kCacheSchemaVersion) {
        dbgLog(
          '[PluginManager] loadCache：缓存 schema 不符或为旧版裸 list，'
          '整份丢弃，等待重新扫描',
        );
        return;
      }
      final list = decoded['plugins'];
      if (list is! List) {
        dbgLog('[PluginManager] loadCache：信封缺少 plugins 数组，丢弃');
        return;
      }
      _plugins = list
          .whereType<Map>()
          .map((m) => PluginMetadata.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      final dropped = _dropMissingPaths();
      if (dropped > 0) {
        // 回写清理，避免每次启动重复展示失效条目
        await saveCache();
        dbgLog('[PluginManager] loadCache 剔除失效插件条目 $dropped 个');
      }
      if (_plugins.isNotEmpty) {
        _notify();
      }
    } catch (e) {
      dbgLog('[PluginManager] loadCache error: $e');
    }
  }

  /// 保存磁盘缓存（信封格式 + 落盘自检）。
  Future<void> saveCache() async {
    try {
      // 自检：非空快照却拿不到任何厂商名，是伪造/损坏缓层的签名，
      // 拒绝写回，避免把坏数据固化成"官方缓存"。
      if (_plugins.isNotEmpty &&
          _plugins.every((p) => p.vendor.isEmpty || p.vendor == 'Unknown')) {
        dbgLog(
          '[PluginManager] saveCache 自检未过'
          '（vendor 全空/Unknown），拒绝写回缓存',
        );
        return;
      }
      final file = _getCacheFile();
      // 父目录可能不存在（全新安装、或被外部清理过）。缺了这步 writeAsString 会
      // 抛 PathNotFoundException 并被下面的 catch 吞掉，表现为扫描结果每次启动都丢。
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final seen = <String>{};
      final list = _plugins
          .where((p) => seen.add('${p.path}\u0000${p.format.label}'))
          .map((p) => p.toJson())
          .toList();
      final envelope = <String, dynamic>{
        'schema': kCacheSchemaVersion,
        'scannedAt': DateTime.now().toIso8601String(),
        'deep': _lastScanDeep,
        'plugins': list,
      };
      await file.writeAsString(jsonEncode(envelope), flush: true);
    } catch (e) {
      dbgLog('[PluginManager] saveCache error: $e');
    }
  }
}
