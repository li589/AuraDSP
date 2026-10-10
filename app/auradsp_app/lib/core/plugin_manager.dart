/*
 * plugin_manager.dart — AuraDSP M1 第三方插件管理器与状态中心
 *
 * 规范对齐：docs/APP-插件与信号图扩展规划.md §2 与 §9.1
 * 支持 64位 VST3 (Steinberg) 与 CLAP 格式插件。
 * 具备目录发现、元数据检索、缓存快照、实时挂载/卸载/旁路管理功能。
 */

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// 插件格式枚举
enum PluginFormat {
  vst3,
  clap,
  unknown;

  static PluginFormat fromString(String val) {
    final s = val.toLowerCase().trim();
    if (s.contains('vst3')) return PluginFormat.vst3;
    if (s.contains('clap')) return PluginFormat.clap;
    return PluginFormat.unknown;
  }

  String get label {
    switch (this) {
      case PluginFormat.vst3:
        return 'VST3';
      case PluginFormat.clap:
        return 'CLAP';
      case PluginFormat.unknown:
        return 'OTHER';
    }
  }
}

/// 插件元数据模型
class PluginMetadata {
  final String id;
  final String name;
  final String vendor;
  final String version;
  final String category;
  final PluginFormat format;
  final String path;
  final bool isCompatible;
  final String errorMessage;

  const PluginMetadata({
    required this.id,
    required this.name,
    this.vendor = '',
    this.version = '',
    this.category = '',
    required this.format,
    required this.path,
    this.isCompatible = true,
    this.errorMessage = '',
  });

  factory PluginMetadata.fromJson(Map<String, dynamic> json) {
    return PluginMetadata(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unknown Plugin',
      vendor: json['vendor'] as String? ?? '',
      version: json['version'] as String? ?? '',
      category: json['category'] as String? ?? '',
      format: PluginFormat.fromString(json['format'] as String? ?? ''),
      path: json['path'] as String? ?? '',
      isCompatible: json['isCompatible'] as bool? ?? true,
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'vendor': vendor,
        'version': version,
        'category': category,
        'format': format.label,
        'path': path,
        'isCompatible': isCompatible,
        'errorMessage': errorMessage,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginMetadata &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          id == other.id;

  @override
  int get hashCode => path.hashCode ^ id.hashCode;
}

/// 宿主当前激活状态
class PluginHostStatus {
  final bool hasActive;
  final bool bypassed;
  final int latency;
  final PluginMetadata? plugin;

  const PluginHostStatus({
    this.hasActive = false,
    this.bypassed = false,
    this.latency = 0,
    this.plugin,
  });

  static const empty = PluginHostStatus();

  factory PluginHostStatus.fromJson(Map<String, dynamic> json) {
    PluginMetadata? meta;
    if (json['plugin'] != null && json['plugin'] is Map) {
      meta = PluginMetadata.fromJson(Map<String, dynamic>.from(json['plugin'] as Map));
    }
    return PluginHostStatus(
      hasActive: json['hasActive'] as bool? ?? false,
      bypassed: json['bypassed'] as bool? ?? false,
      latency: (json['latency'] as num?)?.toInt() ?? 0,
      plugin: meta,
    );
  }

  Map<String, dynamic> toJson() => {
        'hasActive': hasActive,
        'bypassed': bypassed,
        'latency': latency,
        'plugin': plugin?.toJson(),
      };
}

/// 插件指令派发回调函数类型
typedef PluginCommandSender = void Function(Map<String, dynamic> msg);

/// 插件管理器
class PluginManager extends ChangeNotifier {
  PluginCommandSender? _commandSender;

  List<PluginMetadata> _plugins = [];
  PluginHostStatus _hostStatus = PluginHostStatus.empty;
  bool _isScanning = false;
  String _filterFormat = 'all'; // 'all', 'vst3', 'clap'
  String _searchQuery = '';
  String? _lastError;
  int _lastScanCount = 0;

  PluginManager({this._commandSender});

  void attachSender(PluginCommandSender sender) {
    _commandSender = sender;
  }

  // --- Getters ---
  List<PluginMetadata> get plugins => List.unmodifiable(_plugins);
  PluginHostStatus get hostStatus => _hostStatus;
  bool get isScanning => _isScanning;
  String get filterFormat => _filterFormat;
  String get searchQuery => _searchQuery;
  String? get lastError => _lastError;
  int get lastScanCount => _lastScanCount;

  bool get hasActivePlugin => _hostStatus.hasActive && _hostStatus.plugin != null;
  bool get isBypassed => _hostStatus.bypassed;
  int get currentLatency => _hostStatus.latency;
  PluginMetadata? get activePlugin => _hostStatus.plugin;

  int get countAll => _plugins.length;
  int get countVst3 => _plugins.where((p) => p.format == PluginFormat.vst3).length;
  int get countClap => _plugins.where((p) => p.format == PluginFormat.clap).length;

  /// 过滤后的插件列表
  List<PluginMetadata> get filteredPlugins {
    var list = _plugins;
    if (_filterFormat == 'vst3') {
      list = list.where((p) => p.format == PluginFormat.vst3).toList();
    } else if (_filterFormat == 'clap') {
      list = list.where((p) => p.format == PluginFormat.clap).toList();
    }

    final q = _searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((p) {
        return p.name.toLowerCase().contains(q) ||
            p.vendor.toLowerCase().contains(q) ||
            p.category.toLowerCase().contains(q) ||
            p.path.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  // --- UI 控制操作 ---
  void setFilterFormat(String format) {
    if (_filterFormat != format) {
      _filterFormat = format;
      notifyListeners();
    }
  }

  void setSearchQuery(String query) {
    if (_searchQuery != query) {
      _searchQuery = query;
      notifyListeners();
    }
  }

  /// 启动扫描（支持快扫与全盘深扫）
  void scan({String dir = '', bool deep = false}) {
    _isScanning = true;
    _lastError = null;
    notifyListeners();

    _commandSender?.call({
      'cmd': 'pluginScan',
      'dir': dir,
      'deep': deep,
    });
  }

  /// 请求刷新插件全量列表
  void refreshList() {
    _commandSender?.call({
      'cmd': 'pluginGetAll',
    });
  }

  /// 加载指定插件
  void loadPlugin(PluginMetadata plugin) {
    _lastError = null;
    _commandSender?.call({
      'cmd': 'pluginLoad',
      'path': plugin.path,
      'id': plugin.id,
    });
  }

  /// 卸载当前插件
  void unloadPlugin() {
    _commandSender?.call({
      'cmd': 'pluginUnload',
    });
  }

  /// 设置插件旁路
  void setBypass(bool bypass) {
    _commandSender?.call({
      'cmd': 'pluginSetBypass',
      'bypass': bypass,
    });
  }

  /// 切换旁路开关
  void toggleBypass() {
    setBypass(!_hostStatus.bypassed);
  }

  /// 请求刷新当前状态
  void refreshStatus() {
    _commandSender?.call({
      'cmd': 'pluginGetStatus',
    });
  }

  // --- 底层引擎事件回调处理 ---
  void onPluginScanned(int count, dynamic rawJson) {
    _isScanning = false;
    _lastScanCount = count;
    _parsePluginsJson(rawJson);
    saveCache();
    notifyListeners();
  }

  void onPluginList(dynamic rawJson) {
    _parsePluginsJson(rawJson);
    notifyListeners();
  }

  void onPluginLoaded(String path, int rc, dynamic rawStatus) {
    if (rc != 1) {
      _lastError = '加载插件失败 (rc=$rc): $path';
    } else {
      _lastError = null;
    }
    _parseStatusJson(rawStatus);
    notifyListeners();
  }

  void onPluginUnloaded(int rc, dynamic rawStatus) {
    _parseStatusJson(rawStatus);
    notifyListeners();
  }

  void onPluginBypass(bool bypass, dynamic rawStatus) {
    _parseStatusJson(rawStatus);
    notifyListeners();
  }

  void onPluginStatus(dynamic rawStatus) {
    _parseStatusJson(rawStatus);
    notifyListeners();
  }

  void _parsePluginsJson(dynamic raw) {
    try {
      final List list;
      if (raw is String) {
        list = jsonDecode(raw) as List;
      } else if (raw is List) {
        list = raw;
      } else {
        return;
      }

      _plugins = list
          .whereType<Map>()
          .map((m) => PluginMetadata.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e) {
      debugPrint('[PluginManager] Error parsing plugins JSON: $e');
    }
  }

  void _parseStatusJson(dynamic raw) {
    try {
      final Map<String, dynamic> map;
      if (raw is String) {
        map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } else if (raw is Map) {
        map = Map<String, dynamic>.from(raw);
      } else {
        return;
      }
      _hostStatus = PluginHostStatus.fromJson(map);
    } catch (e) {
      debugPrint('[PluginManager] Error parsing status JSON: $e');
    }
  }

  // --- 本地磁盘缓存持久化 ---
  static File _getCacheFile() {
    final appData = Platform.environment['APPDATA'] ?? '.';
    final dir = Directory('$appData/AuraDSP/plugins');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return File('${dir.path}/plugin_cache.json');
  }

  /// 加载磁盘缓存（启动时秒级恢复历史扫描结果）
  Future<void> loadCache() async {
    try {
      final file = _getCacheFile();
      if (await file.exists()) {
        final text = await file.readAsString();
        _parsePluginsJson(text);
        if (_plugins.isNotEmpty) {
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('[PluginManager] loadCache error: $e');
    }
  }

  /// 保存磁盘缓存
  Future<void> saveCache() async {
    try {
      final file = _getCacheFile();
      final list = _plugins.map((p) => p.toJson()).toList();
      await file.writeAsString(jsonEncode(list), flush: true);
    } catch (e) {
      debugPrint('[PluginManager] saveCache error: $e');
    }
  }
}
