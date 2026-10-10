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

/// 插入阶段定义与友好描述
abstract final class PluginInsertStage {
  static const preDsp = 0;
  static const preVendor = 1;
  static const postVendor = 2;
  static const postReverb = 3;
  static const postLimiter = 4;

  static const defaultStage = postReverb;

  static String labelOf(int stage) {
    switch (stage) {
      case preDsp:
        return '输入前置 (Pre-DSP)';
      case preVendor:
        return '音效前置 (Pre-Vendor)';
      case postVendor:
        return '音效后置 (Post-Vendor)';
      case postReverb:
        return '混响后置 (Post-Reverb)';
      case postLimiter:
        return '总输出级 (Post-Limiter)';
      default:
        return '阶段 $stage';
    }
  }

  static String shortLabelOf(int stage) {
    switch (stage) {
      case preDsp:
        return 'Pre-DSP';
      case preVendor:
        return 'Pre-Vendor';
      case postVendor:
        return 'Post-Vendor';
      case postReverb:
        return 'Post-Reverb';
      case postLimiter:
        return 'Post-Limit';
      default:
        return 'Stage $stage';
    }
  }
}

/// 插件指令派发回调函数类型
typedef PluginCommandSender = void Function(Map<String, dynamic> msg);

/// 插件管理器
class PluginManager extends ChangeNotifier {
  static const int kMaxSlots = 2;

  PluginCommandSender? _commandSender;

  List<PluginMetadata> _plugins = [];
  final List<PluginHostStatus> _slotStatuses = [
    PluginHostStatus.empty,
    PluginHostStatus.empty,
  ];
  final List<int> _slotStages = [
    PluginInsertStage.defaultStage,
    PluginInsertStage.defaultStage,
  ];
  int _selectedSlot = 0;

  List<String> _customDirs = [];
  bool _isScanning = false;
  String _filterFormat = 'all'; // 'all', 'vst3', 'clap'
  String _searchQuery = '';
  final Map<int, bool> _slotBusy = {};
  String? _lastError;
  int _lastScanCount = 0;

  bool isSlotBusy(int slot) => _slotBusy[slot] ?? false;

  PluginManager({PluginCommandSender? commandSender}) {
    _commandSender = commandSender;
  }

  void attachSender(PluginCommandSender sender) {
    _commandSender = sender;
  }

  // --- Getters ---
  List<PluginMetadata> get plugins => List.unmodifiable(_plugins);
  int get selectedSlot => _selectedSlot;
  List<String> get customDirs => List.unmodifiable(_customDirs);
  bool get isScanning => _isScanning;
  String get filterFormat => _filterFormat;
  String get searchQuery => _searchQuery;
  String? get lastError => _lastError;
  int get lastScanCount => _lastScanCount;

  // 插槽状态读取
  PluginHostStatus getSlotStatus(int slot) {
    if (slot >= 0 && slot < kMaxSlots) return _slotStatuses[slot];
    return PluginHostStatus.empty;
  }

  int getSlotStage(int slot) {
    if (slot >= 0 && slot < kMaxSlots) return _slotStages[slot];
    return PluginInsertStage.defaultStage;
  }

  bool isSlotActive(int slot) {
    final s = getSlotStatus(slot);
    return s.hasActive && s.plugin != null;
  }

  bool isSlotBypassed(int slot) => getSlotStatus(slot).bypassed;
  int getSlotLatency(int slot) => getSlotStatus(slot).latency;
  PluginMetadata? getSlotPlugin(int slot) => getSlotStatus(slot).plugin;

  // 映射当前选中槽位（向后兼容单槽访问）
  PluginHostStatus get hostStatus => getSlotStatus(_selectedSlot);
  bool get hasActivePlugin => isSlotActive(_selectedSlot);
  bool get isBypassed => isSlotBypassed(_selectedSlot);
  int get currentLatency => getSlotLatency(_selectedSlot);
  PluginMetadata? get activePlugin => getSlotPlugin(_selectedSlot);
  int get currentStage => getSlotStage(_selectedSlot);

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
  void selectSlot(int slot) {
    if (slot >= 0 && slot < kMaxSlots && _selectedSlot != slot) {
      _selectedSlot = slot;
      notifyListeners();
    }
  }

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

  // 自定义扫描目录管理
  void setCustomDirs(List<String> dirs) {
    _customDirs = List.from(dirs);
    notifyListeners();
  }

  void addCustomDir(String dir) {
    final trimmed = dir.trim();
    if (trimmed.isNotEmpty && !_customDirs.contains(trimmed)) {
      _customDirs.add(trimmed);
      notifyListeners();
    }
  }

  void removeCustomDir(String dir) {
    if (_customDirs.remove(dir)) {
      notifyListeners();
    }
  }

  /// 启动扫描（支持快扫、深扫与多目录聚合）
  void scan({String dir = '', bool deep = false}) {
    _isScanning = true;
    _lastError = null;
    notifyListeners();

    final allDirs = <String>[];
    if (dir.isNotEmpty) allDirs.add(dir);
    for (final cd in _customDirs) {
      if (!allDirs.contains(cd) && Directory(cd).existsSync()) {
        allDirs.add(cd);
      }
    }

    _commandSender?.call({
      'cmd': 'pluginScan',
      'dir': dir,
      'dirs': allDirs.isNotEmpty ? allDirs : null,
      'deep': deep,
    });
  }

  /// 请求刷新插件全量列表
  void refreshList() {
    _commandSender?.call({
      'cmd': 'pluginGetAll',
    });
  }

  /// 加载插件到指定槽位（默认当前选中槽位）
  void loadPlugin(PluginMetadata plugin, {int? slot}) {
    final s = slot ?? _selectedSlot;
    _lastError = null;
    _commandSender?.call({
      'cmd': 'pluginSlotLoad',
      'slot': s,
      'path': plugin.path,
      'id': plugin.id,
    });
  }

  /// 卸载指定槽位的插件
  void unloadPlugin({int? slot}) {
    final s = slot ?? _selectedSlot;
    _commandSender?.call({
      'cmd': 'pluginSlotUnload',
      'slot': s,
    });
  }

  /// 设置指定槽位旁路
  void setBypass(bool bypass, {int? slot}) {
    final s = slot ?? _selectedSlot;
    _commandSender?.call({
      'cmd': 'pluginSlotSetBypass',
      'slot': s,
      'bypass': bypass,
    });
  }

  /// 切换指定槽位旁路开关
  void toggleBypass({int? slot}) {
    final s = slot ?? _selectedSlot;
    setBypass(!isSlotBypassed(s), slot: s);
  }

  /// 打开插件原生 GUI 编辑器窗口
  void showEditor({int? slot, String? title}) {
    final s = slot ?? _selectedSlot;
    final meta = getSlotPlugin(s);
    final winTitle = title ?? (meta != null ? '${meta.name} - AuraDSP Host' : 'Plugin Editor');
    _commandSender?.call({
      'cmd': 'pluginSlotShowEditor',
      'slot': s,
      'title': winTitle,
    });
  }

  /// 关闭插件原生 GUI 编辑器窗口
  void closeEditor({int? slot}) {
    final s = slot ?? _selectedSlot;
    _commandSender?.call({
      'cmd': 'pluginSlotCloseEditor',
      'slot': s,
    });
  }

  /// 调整插件在处理链上的插入阶段
  void setInsertStage(int stage, {int? slot}) {
    final s = slot ?? _selectedSlot;
    _slotStages[s] = stage;
    notifyListeners();
    _commandSender?.call({
      'cmd': 'pluginSlotSetInsertStage',
      'slot': s,
      'stage': stage,
    });
  }

  /// 请求刷新指定槽位当前状态
  void refreshStatus({int? slot}) {
    final s = slot ?? _selectedSlot;
    _commandSender?.call({
      'cmd': 'pluginSlotGetStatus',
      'slot': s,
    });
  }

  // --- 插件预设系统管理 ---
  static Directory _getPresetsDir(String pluginName) {
    final appData = Platform.environment['APPDATA'] ?? '.';
    final safeName = pluginName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dir = Directory('$appData/AuraDSP/plugin_presets/$safeName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 列出指定插件所有已保存的预设
  List<String> listPresets(String pluginName) {
    try {
      final dir = _getPresetsDir(pluginName);
      if (!dir.existsSync()) return [];
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.aurapreset'))
          .map((f) {
            final filename = f.uri.pathSegments.last;
            return filename.substring(0, filename.length - '.aurapreset'.length);
          })
          .toList()
        ..sort();
    } catch (_) {
      return [];
    }
  }

  /// 保存当前槽位插件的预设
  bool savePreset(String presetName, {int? slot}) {
    final s = slot ?? _selectedSlot;
    final meta = getSlotPlugin(s);
    if (meta == null || presetName.trim().isEmpty) return false;
    try {
      final dir = _getPresetsDir(meta.name);
      final safePreset = presetName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final targetFile = File('${dir.path}/$safePreset.aurapreset');
      _commandSender?.call({
        'cmd': 'pluginSlotSavePreset',
        'slot': s,
        'path': targetFile.path,
      });
      return true;
    } catch (e) {
      _lastError = '保存预设失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 加载指定预设至槽位
  bool loadPreset(String presetName, {int? slot}) {
    final s = slot ?? _selectedSlot;
    final meta = getSlotPlugin(s);
    if (meta == null) return false;
    try {
      final dir = _getPresetsDir(meta.name);
      final safePreset = presetName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final targetFile = File('${dir.path}/$safePreset.aurapreset');
      if (!targetFile.existsSync()) {
        _lastError = '预设文件不存在: ${targetFile.path}';
        notifyListeners();
        return false;
      }
      _commandSender?.call({
        'cmd': 'pluginSlotLoadPreset',
        'slot': s,
        'path': targetFile.path,
      });
      return true;
    } catch (e) {
      _lastError = '加载预设失败: $e';
      notifyListeners();
      return false;
    }
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

  void onPluginSlotLoaded(int slot, String path, int rc, dynamic rawStatus, int stage) {
    if (slot >= 0 && slot < kMaxSlots) {
      if (rc != 1) {
        _lastError = '加载插件失败 (rc=$rc, slot=$slot): $path';
      } else {
        _lastError = null;
      }
      _slotStages[slot] = stage;
      _parseStatusJsonForSlot(slot, rawStatus);
      notifyListeners();
    }
  }

  void onPluginSlotUnloaded(int slot, int rc, dynamic rawStatus) {
    if (slot >= 0 && slot < kMaxSlots) {
      _parseStatusJsonForSlot(slot, rawStatus);
      notifyListeners();
    }
  }

  void onPluginSlotBypass(int slot, bool bypass, dynamic rawStatus) {
    if (slot >= 0 && slot < kMaxSlots) {
      _parseStatusJsonForSlot(slot, rawStatus);
      notifyListeners();
    }
  }

  void onPluginSlotStatus(int slot, dynamic rawStatus, int stage) {
    if (slot >= 0 && slot < kMaxSlots) {
      _slotStages[slot] = stage;
      _parseStatusJsonForSlot(slot, rawStatus);
      notifyListeners();
    }
  }

  void onPluginSlotInsertStage(int slot, int stage, int rc) {
    if (slot >= 0 && slot < kMaxSlots) {
      _slotStages[slot] = stage;
      notifyListeners();
    }
  }

  // 向后兼容旧单槽事件
  void onPluginLoaded(String path, int rc, dynamic rawStatus) =>
      onPluginSlotLoaded(0, path, rc, rawStatus, PluginInsertStage.defaultStage);

  void onPluginUnloaded(int rc, dynamic rawStatus) =>
      onPluginSlotUnloaded(0, rc, rawStatus);

  void onPluginBypass(bool bypass, dynamic rawStatus) =>
      onPluginSlotBypass(0, bypass, rawStatus);

  void onPluginStatus(dynamic rawStatus) =>
      onPluginSlotStatus(0, rawStatus, PluginInsertStage.defaultStage);

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

  void _parseStatusJsonForSlot(int slot, dynamic raw) {
    try {
      final Map<String, dynamic> map;
      if (raw is String) {
        map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } else if (raw is Map) {
        map = Map<String, dynamic>.from(raw);
      } else {
        return;
      }
      _slotStatuses[slot] = PluginHostStatus.fromJson(map);
    } catch (e) {
      debugPrint('[PluginManager] Error parsing status JSON for slot $slot: $e');
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
