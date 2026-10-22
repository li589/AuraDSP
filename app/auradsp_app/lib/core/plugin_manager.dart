/*
 * plugin_manager.dart — AuraDSP M1 第三方插件管理器与状态中心
 *
 * 规范对齐：docs/APP-插件与信号图扩展规划.md §2 与 §9.1
 * 支持 64位 VST3 (Steinberg) 与 CLAP 格式插件。
 * 具备目录发现、元数据检索、缓存快照、实时挂载/卸载/旁路管理功能。
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'config.dart';

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

  /// 插件自报名（CLAP descriptor / VST3 factory）。
  final String vendor;
  final String version;

  /// 真实分类：CLAP features 级联 / VST3 subCategories。
  /// 注意历史上曾被误填为 descriptor 的 description 自由文本（B1 已修）。
  final String category;

  /// Bundle/文件名 stem —— 用户在列表里实际选中的那一个。
  /// CLAP 的自报名与文件名可能不同（如自报名 "Element FX"、文件 KV-Element-FX）。
  final String bundleName;

  /// 自由文本描述，仅展示用，不参与分类判断。
  final String description;
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
    this.bundleName = '',
    this.description = '',
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
      bundleName: json['bundleName'] as String? ?? '',
      description: json['description'] as String? ?? '',
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
    'bundleName': bundleName,
    'description': description,
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

  /// 复制并覆盖部分字段（厂商表填充 vendor 用）。
  PluginMetadata copyWith({String? vendor}) => PluginMetadata(
    id: id,
    name: name,
    vendor: vendor ?? this.vendor,
    version: version,
    category: category,
    bundleName: bundleName,
    description: description,
    format: format,
    path: path,
    isCompatible: isCompatible,
    errorMessage: errorMessage,
  );
}

/// 宿主当前激活状态
class PluginHostStatus {
  final bool hasActive;
  final bool bypassed;
  final int latency;
  final int processCalls;
  final double inRms;
  final double outRms;
  final double maxDiff;
  final int lastFrames;
  final PluginMetadata? plugin;
  final bool remoteMode;
  final bool remoteFailed;
  final int transportLatency;
  final int inputOverflows;
  final int outputOverflows;
  final int channels;
  final int mainInChannels;
  final int mainOutChannels;

  const PluginHostStatus({
    this.hasActive = false,
    this.bypassed = false,
    this.latency = 0,
    this.processCalls = 0,
    this.inRms = 0,
    this.outRms = 0,
    this.maxDiff = 0,
    this.lastFrames = 0,
    this.plugin,
    this.remoteMode = false,
    this.remoteFailed = false,
    this.transportLatency = 0,
    this.inputOverflows = 0,
    this.outputOverflows = 0,
    this.channels = 0xFF,
    this.mainInChannels = 2,
    this.mainOutChannels = 2,
  });

  static const empty = PluginHostStatus();

  factory PluginHostStatus.fromJson(Map<String, dynamic> json) {
    PluginMetadata? meta;
    if (json['plugin'] != null && json['plugin'] is Map) {
      meta = PluginMetadata.fromJson(
        Map<String, dynamic>.from(json['plugin'] as Map),
      );
    }
    final busInfo = json['busInfo'] as Map?;
    return PluginHostStatus(
      hasActive: json['hasActive'] as bool? ?? false,
      bypassed: json['bypassed'] as bool? ?? false,
      latency: (json['latency'] as num?)?.toInt() ?? 0,
      processCalls: (json['processCalls'] as num?)?.toInt() ?? 0,
      inRms: (json['inRms'] as num?)?.toDouble() ?? 0,
      outRms: (json['outRms'] as num?)?.toDouble() ?? 0,
      maxDiff: (json['maxDiff'] as num?)?.toDouble() ?? 0,
      lastFrames: (json['lastFrames'] as num?)?.toInt() ?? 0,
      plugin: meta,
      remoteMode: json['remoteMode'] as bool? ?? false,
      remoteFailed: json['remoteFailed'] as bool? ?? false,
      transportLatency: (json['transportLatency'] as num?)?.toInt() ?? 0,
      inputOverflows: (json['inputOverflows'] as num?)?.toInt() ?? 0,
      outputOverflows: (json['outputOverflows'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 0xFF,
      mainInChannels: (busInfo?['mainInChannels'] as num?)?.toInt() ?? 2,
      mainOutChannels: (busInfo?['mainOutChannels'] as num?)?.toInt() ?? 2,
    );
  }

  Map<String, dynamic> toJson() => {
    'hasActive': hasActive,
    'bypassed': bypassed,
    'latency': latency,
    'processCalls': processCalls,
    'inRms': inRms,
    'outRms': outRms,
    'maxDiff': maxDiff,
    'lastFrames': lastFrames,
    'plugin': plugin?.toJson(),
    'remoteMode': remoteMode,
    'remoteFailed': remoteFailed,
    'transportLatency': transportLatency,
    'inputOverflows': inputOverflows,
    'outputOverflows': outputOverflows,
    'channels': channels,
    'mainInChannels': mainInChannels,
    'mainOutChannels': mainOutChannels,
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

/// VB 按路编辑器的「全部」路由值（kVbRouteAll）：打开主实例界面、参数/
/// Ch 走「全部」记忆（第 9 套，v3.2 继承/不继承双选项）。放本文件顶层
/// 避免 manager↔state 循环依赖。
const int kVbRouteAll = -2;

/// 插件管理器
class PluginManager extends ChangeNotifier {
  static const int kMaxSlots = 4;

  PluginCommandSender? _commandSender;

  List<PluginMetadata> _plugins = [];
  final List<PluginHostStatus> _slotStatuses = List.filled(
    kMaxSlots,
    PluginHostStatus.empty,
    growable: true,
  );
  final List<int> _slotStages = List.filled(
    kMaxSlots,
    PluginInsertStage.defaultStage,
    growable: true,
  );
  final List<int> _slotChannels = List.filled(kMaxSlots, 0xFF, growable: true);

  /// setInsertStage 下发前的阶段值，用于引擎拒绝时回滚（乐观 UI + 回执纠正）
  final Map<int, int> _pendingStages = {};

  // ---- P1 按路记忆与路由锁定（v3.1/v3.2） ----
  /// 该槽插件编辑器是否打开（路由锁定依据）。事件驱动（EditorResult）+
  /// status 轮询 is_editor_open 兜底（用户直接点插件自带关闭按钮也能解锁）。
  final List<bool> _slotEditorOpen = List.filled(
    kMaxSlots,
    false,
    growable: true,
  );

  /// per-route Ch 记忆：[slot][group]，VB 每路独立（v3.2「包括选择的声道
  /// 也跟随通道记忆切换」）。非 VB 单引擎走 [_slotChannels]。
  final List<List<int>> _routeChannels = List.generate(
    kMaxSlots,
    (_) => List.filled(8, 0xFF),
  );

  /// 「全部」的 Ch 记忆（第 9 套的一部分；参数记忆是 preset 文件）。
  final List<int> _allChannels = List.filled(kMaxSlots, 0xFF);

  /// 「全部」记忆的参数继承来源（P1-2 右侧标注三态）：
  /// >=0 = 继承自该组；-1 =「『全部』自有状态」；-2 = 尚未建立记忆。
  final List<int> _allInheritFrom = List.filled(kMaxSlots, -2, growable: true);

  /// 编辑器当前所在路由（-1=非 VB 单路；>=0=组号），用于关闭时记录来源。
  final List<int> _editorRoute = List.filled(kMaxSlots, -1, growable: true);

  /// 「全部」下打开的编辑器：关闭时自动收尾 sync_all（P1-6 兜底——
  /// 「全部」下调参只作用主实例，关界面时拉平全部组才生效于全部通道）。
  final List<bool> _slotSyncOnClose = List.filled(
    kMaxSlots,
    false,
    growable: true,
  );

  /// 最后关闭编辑器的路由 = 「继承自 X」的候选来源（v3.2）。
  int lastEditedRoute = -1;

  int _selectedSlot = 0;

  List<String> _customDirs = [];
  bool _isScanning = false;
  String _filterFormat = 'all'; // 'all', 'vst3', 'clap'
  String _searchQuery = '';
  final Map<int, bool> _slotBusy = {};

  /// 忙态动作标记（UI 动画文案：'load' 加载中 / 'unload' 卸载中）。
  final Map<int, String> _slotBusyAction = {};
  String? _lastError;
  String? _lastNotice;
  int _lastScanCount = 0;

  /// 最近一次扫描是否为深扫（决定缓存里元数据的可信度，随信封落盘）。
  bool _lastScanDeep = false;

  /// C2：分块扫描进度。total<=0 表示尚未拿到总数（UI 走不确定态动画）。
  int _scanDone = 0;
  int _scanTotal = 0;
  int _scanFound = 0;
  bool _pdcEnabled = false;

  // --- 插件级预设数据（assets/presets/plugin_tables.json + config 增量） ---
  Map<String, String> _vendorTable = {};
  final List<String> _closeQuarantine = []; // 引擎跳过 removed()/release()（防关闭崩溃）
  final List<String> _openQuarantine = []; // 历史崩溃标记（仅提示，不阻止加载/打开）
  bool _tablesLoaded = false;
  Timer? _journalTimer;

  /// 编辑器打开后超过该时长未崩溃视为「打开成功」，从崩溃日志移除，
  /// 避免稳定编辑器的陈旧日志在无关崩溃后被误登记。
  static const int kOpenHealthyMs = 15000;

  static File _quarantineConfigFile() => File(
    ConfigManager.path(
      'plugin_data${Platform.pathSeparator}editor_quarantine.json',
    ),
  );
  static File _editorJournalFile() => File(
    ConfigManager.path(
      'plugin_data${Platform.pathSeparator}editor_journal.json',
    ),
  );

  bool isSlotBusy(int slot) => _slotBusy[slot] ?? false;
  String slotBusyAction(int slot) => _slotBusyAction[slot] ?? 'load';

  /// C3：引擎回执挂载/卸载进行中（异步任务的"提交成功→进行中"与"终态"两次翻转）。
  /// 用于 UI 在挂载/卸载期间显示忙态并禁用重复操作。
  void onPluginSlotBusy(int slot, bool busy) {
    if (slot < 0 || slot >= kMaxSlots) return;
    _slotBusy[slot] = busy;
    notifyListeners();
  }

  PluginManager({PluginCommandSender? commandSender}) {
    _commandSender = commandSender;
  }
  // --- Getters ---
  List<PluginMetadata> get plugins => List.unmodifiable(_plugins);
  int get selectedSlot => _selectedSlot;
  List<String> get customDirs => List.unmodifiable(_customDirs);
  bool get isScanning => _isScanning;

  /// 扫描进度：已处理候选数 / 候选总数 / 已发现插件数
  int get scanDone => _scanDone;
  int get scanTotal => _scanTotal;
  int get scanFound => _scanFound;
  String get filterFormat => _filterFormat;
  String get searchQuery => _searchQuery;
  String? get lastError => _lastError;
  String? get lastNotice => _lastNotice;
  int get lastScanCount => _lastScanCount;

  void clearNotice() {
    if (_lastNotice == null) return;
    _lastNotice = null;
    notifyListeners();
  }

  // 插槽状态读取
  PluginHostStatus getSlotStatus(int slot) {
    if (slot >= 0 && slot < kMaxSlots) return _slotStatuses[slot];
    return PluginHostStatus.empty;
  }

  int getSlotStage(int slot) {
    if (slot >= 0 && slot < kMaxSlots) return _slotStages[slot];
    return PluginInsertStage.defaultStage;
  }

  /// Ch 记忆按路由取值（P1-4）：
  /// [group] >= 0 = VB 具体路；[kVbRouteAll](-2) = 「全部」记忆；
  /// -1 = 非 VB 单引擎（[_slotChannels]）。
  int getSlotChannels(int? slot, {int group = -1}) {
    final s = slot ?? _selectedSlot;
    if (s < 0 || s >= kMaxSlots) return 0xFF;
    if (group == kVbRouteAll) return _allChannels[s];
    if (group >= 0 && group < 8) return _routeChannels[s][group];
    return _slotChannels[s];
  }

  bool isSlotActive(int slot) {
    final s = getSlotStatus(slot);
    return s.hasActive && s.plugin != null;
  }

  /// 该槽插件编辑器是否打开（P1-1 路由锁定依据）。
  bool isSlotEditorOpen(int slot) =>
      slot >= 0 && slot < kMaxSlots && _slotEditorOpen[slot];

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
  int get countVst3 =>
      _plugins.where((p) => p.format == PluginFormat.vst3).length;
  int get countClap =>
      _plugins.where((p) => p.format == PluginFormat.clap).length;

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

  /// C2：分块扫描进度回执。扫描过程中被反复调用，UI 据此显示确定性进度；
  /// 列表同时在 onPluginList/渐进 get_all 中刷新。
  void onPluginScanProgress(int done, int total, int found) {
    _scanDone = done;
    _scanTotal = total;
    _scanFound = found;
    notifyListeners();
  }

  /// 启动扫描（支持快扫、深扫与多目录聚合）
  void scan({String dir = '', bool deep = false}) {
    _isScanning = true;
    _scanDone = 0;
    _scanTotal = 0;
    _scanFound = 0;
    _lastScanDeep = deep;
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
    _commandSender?.call({'cmd': 'pluginGetAll'});
  }

  /// 加载插件到指定槽位（默认当前选中槽位）
  void loadPlugin(PluginMetadata plugin, {int? slot}) {
    final s = slot ?? _selectedSlot;
    // C3：该槽已有挂载/卸载任务进行中则不重复下发——引擎也会拒绝，
    // 但提前拦截可以让 UI 不闪一下再失败。
    if (_slotBusy[s] == true) return;
    _lastError = null;
    // D2：扫描期已判定不兼容的插件（当前唯一情形：32 位）在 Dart 侧
    // 直接拦截，不走 isolate 往返。引擎侧 load() 有同样拒绝（双保险），
    // 两侧文案一致，这里补上插件名前缀便于定位是哪一项。
    if (!plugin.isCompatible) {
      _lastError = plugin.errorMessage.isNotEmpty
          ? '${plugin.name}：${plugin.errorMessage}'
          : '${plugin.name} 与当前 AuraDSP 版本不兼容，无法加载。';
      notifyListeners();
      return;
    }
    // C3：乐观置忙（引擎回执 pluginSlotBusy 会再确认一次）。
    _slotBusy[s] = true;
    _slotBusyAction[s] = 'load';
    notifyListeners();
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
    // C3：同上，避免在卸载还在进行时又发一次。
    if (_slotBusy[s] == true) return;
    // P2 自动记录：卸载前把当前调音落盘到激活 A/B 槽（不丢）。
    autoSaveAb(s, group: _editorRoute[s] >= 0 ? _editorRoute[s] : -1);
    _slotBusy[s] = true;
    _slotBusyAction[s] = 'unload';
    notifyListeners();
    _commandSender?.call({'cmd': 'pluginSlotUnload', 'slot': s});
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

  void setPdc(bool enable) {
    _pdcEnabled = enable;
    notifyListeners();
    _commandSender?.call({'cmd': 'pluginSetPdc', 'pdc': enable});
  }

  bool get pdcEnabled => _pdcEnabled;

  void onPluginPdc(bool pdc, int rc) {
    if (rc == 1) {
      _pdcEnabled = pdc;
    }
    notifyListeners();
  }

  /// 打开插件原生 GUI 编辑器窗口
  ///
  /// C1：同一插件可同时挂多个槽位，标题必须带槽位号区分多个编辑器窗口。
  /// 本地化标题由调用方经 `plugEditorTitleNamed` 传入；未传时的兜底也带
  /// 槽位号（本类无 BuildContext，取 locale 中性格式）。
  ///
  /// v2：VB 多总线下 [group] >= 0 时打开该组引擎上的编辑器（每路独立
  /// 配置插件）；其余模式传 -1 走单路语义。标题附加路号，多窗口可区分。
  ///
  /// 打开崩溃隔离：editorQuarantine.open 名单内插件阻止打开（曾打开即崩溃
  /// 自动登记于此），给出可操作提示而不是再次崩掉整个 APP。
  /// 历史崩溃仅提示：加载与编辑器打开都不再被阻止。插件关闭时由引擎
  /// 依据 [closeQuarantine] 跳过 `removed()`/`release()`，换用隔离 teardown。
  void showEditor({
    int? slot,
    String? title,
    int group = -1,
    bool syncOnClose = false,
  }) {
    final s = slot ?? _selectedSlot;
    final meta = getSlotPlugin(s);
    if (meta != null && isEditorCrashKnown(meta)) {
      _lastNotice =
          '${meta.name}：该插件曾导致 AuraDSP 崩溃。已记录到隔离名单，'
          '关闭插件时将跳过其自身的 teardown（removed/release）以避免二次崩溃；'
          '插件仍会正常加载和运行，但可能残留少量资源。';
      notifyListeners();
    }
    final routeTag = group >= 0 ? ' [Route ${group + 1}]' : '';
    final winTitle =
        title ??
        (meta != null
            ? '${meta.name} - AuraDSP Host [Slot ${s + 1}]$routeTag'
            : 'Plugin Editor [Slot ${s + 1}]$routeTag');
    // 崩溃日志：记录「正在打开」，供下次启动自动登记打开即崩溃的插件。
    if (meta != null) _journalEditorOpened(meta);
    // P1-1 路由锁定：记下编辑器所在路由；成功回执后置打开态。
    _editorRoute[s] = group;
    _slotSyncOnClose[s] = syncOnClose;
    _commandSender?.call({
      'cmd': 'pluginSlotShowEditor',
      'slot': s,
      'title': winTitle,
      'group': group,
    });
  }

  /// 关闭插件原生 GUI 编辑器窗口（group 语义同 [showEditor]）。
  void closeEditor({int? slot, int group = -1}) {
    final s = slot ?? _selectedSlot;
    _commandSender?.call({
      'cmd': 'pluginSlotCloseEditor',
      'slot': s,
      'group': group,
    });
  }

  /// 编辑器回执（P1-1/P1-5）：更新打开态；关闭成功时记录 lastEditedRoute
  /// （=「继承自 X」的来源候选，与路由锁定天然衔接——界面开着不能切路由）。
  void onPluginSlotEditorResult(int slot, String action, bool ok) {
    if (slot < 0 || slot >= kMaxSlots) return;
    if (action == 'show') {
      _slotEditorOpen[slot] = ok;
    } else if (action == 'close' && ok) {
      _slotEditorOpen[slot] = false;
      final r = _editorRoute[slot];
      if (r >= 0) lastEditedRoute = r;
      _editorRoute[slot] = -1;
      // P2 自动记录：编辑器关闭即把当前调音落盘到激活 A/B 槽。
      autoSaveAb(slot, group: r >= 0 ? r : -1);
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  /// status 轮询兜底（P1-1）：用户直接点插件自带关闭按钮时同步打开态。
  void onSlotEditorOpenPolled(int slot, bool open) {
    if (slot < 0 || slot >= kMaxSlots) return;
    if (_slotEditorOpen[slot] != open) {
      _slotEditorOpen[slot] = open;
      if (!open) {
        // 轮询解锁（用户点插件自带关闭按钮）也要落盘——与 close 回执同语义，
        // 否则该路径下调音不进 A/B 预设。
        if (_editorRoute[slot] >= 0) {
          lastEditedRoute = _editorRoute[slot];
          autoSaveAb(slot, group: _editorRoute[slot]);
          _editorRoute[slot] = -1;
        }
      }
      notifyListeners();
    }
  }

  /// 驱动模式切换（VB/ASIO/VAIO/WASAPI）前的插件状态收尾（P2 边界修复）：
  /// 全部活跃槽的各路由 A/B 激活槽落盘（引擎重建不丢调音）+ 编辑器状态
  /// 清理（重建后旧编辑器窗口已失效）。
  void onAudioModeSwitching() {
    for (var s = 0; s < kMaxSlots; s++) {
      if (!isSlotActive(s)) continue;
      // 非 VB 单路 + VB 各路（曾经记录过的路由都存）。
      autoSaveAb(s, group: -1);
      for (var g = 0; g < 8; g++) {
        if (_abMeta.containsKey(_abKey2(s, g, 'A')) ||
            _abMeta.containsKey(_abKey2(s, g, 'B'))) {
          autoSaveAb(s, group: g);
        }
      }
      _slotEditorOpen[s] = false;
      _editorRoute[s] = -1;
      _slotSyncOnClose[s] = false;
    }
    notifyListeners();
  }

  /// 「全部」记忆 preset 文件（第 9 套参数记忆，v3.2）。
  String allMemoryPath(int slot) {
    final dir = ConfigManager.path(
      'plugin_presets${Platform.pathSeparator}.all_memory',
    );
    Directory(dir).createSync(recursive: true);
    return '$dir${Platform.pathSeparator}slot$slot.aurapreset';
  }

  /// 「全部」记忆的继承来源标注（P1-2）：>=0=组号 / -1=自有 / -2=未建立。
  int allInheritFrom(int slot) =>
      (slot >= 0 && slot < kMaxSlots) ? _allInheritFrom[slot] : -2;

  /// P1-5 继承复制：srcGroup 的 state 快照写入「全部」记忆文件并应用到
  /// 全部组（桥内 save→load 批处理）；同时把 srcGroup 的 Ch 记忆设为
  /// 「全部」Ch 记忆并下发全组。
  void inheritAllFrom(int srcGroup, {int? slot}) {
    final s = slot ?? _selectedSlot;
    if (srcGroup < 0 || srcGroup > 7) return;
    _allChannels[s] = _routeChannels[s][srcGroup];
    _allInheritFrom[s] = srcGroup;
    _commandSender?.call({
      'cmd': 'pluginSlotSyncAll',
      'slot': s,
      'srcGroup': srcGroup,
      'path': allMemoryPath(s),
    });
    _commandSender?.call({
      'cmd': 'pluginSlotSetChannels',
      'slot': s,
      'mask': _allChannels[s],
      'group': -1,
    });
    notifyListeners();
  }

  /// P1-5 不继承：把「全部」记忆文件应用到全部组（现有全组扇出 loadPreset）
  /// + 「全部」Ch 记忆下发全组。
  void applyAllMemory({int? slot}) {
    final s = slot ?? _selectedSlot;
    _allInheritFrom[s] = -1;
    _commandSender?.call({
      'cmd': 'pluginSlotLoadPreset',
      'slot': s,
      'path': allMemoryPath(s),
    });
    _commandSender?.call({
      'cmd': 'pluginSlotSetChannels',
      'slot': s,
      'mask': _allChannels[s],
      'group': -1,
    });
    notifyListeners();
  }

  /// P1-5「全部」记忆文件是否存在（决定菜单「不继承」是否可选）。
  bool hasAllMemory(int slot) => File(allMemoryPath(slot)).existsSync();

  /// 调整插件在处理链上的插入阶段。
  ///
  /// 保持乐观写入（UI 即时反馈），但记录下发前的值：引擎回执
  /// [onPluginSlotInsertStage] 若带回非 0 的 rc，会回滚到该值，
  /// 避免「引擎拒绝但 UI 显示成功」。
  void setInsertStage(int stage, {int? slot}) {
    final s = slot ?? _selectedSlot;
    _pendingStages[s] = _slotStages[s];
    _slotStages[s] = stage;
    notifyListeners();
    _commandSender?.call({
      'cmd': 'pluginSlotSetInsertStage',
      'slot': s,
      'stage': stage,
    });
  }

  /// 设置 Ch 记忆并下发（P1-4 per-route；group 语义同 [getSlotChannels]）。
  /// VB 具体路 → set_channels_g 只发该组；「全部」→ 全组扇出 + 更新
  /// 第 9 套记忆；非 VB → 单路。
  void setSlotChannels(int mask, {int? slot, int group = -1}) {
    final s = slot ?? _selectedSlot;
    if (s < 0 || s >= kMaxSlots) return;
    if (group == kVbRouteAll) {
      _allChannels[s] = mask;
      _commandSender?.call({
        'cmd': 'pluginSlotSetChannels',
        'slot': s,
        'mask': mask,
        'group': -1, // 全组扇出
      });
    } else if (group >= 0 && group < 8) {
      _routeChannels[s][group] = mask;
      _commandSender?.call({
        'cmd': 'pluginSlotSetChannels',
        'slot': s,
        'mask': mask,
        'group': group,
      });
    } else {
      _slotChannels[s] = mask;
      _commandSender?.call({
        'cmd': 'pluginSlotSetChannels',
        'slot': s,
        'mask': mask,
        'group': -1,
      });
    }
    notifyListeners();
  }

  void refreshStatus({int? slot}) {
    final s = slot ?? _selectedSlot;
    _commandSender?.call({'cmd': 'pluginSlotGetStatus', 'slot': s});
  }

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
    } catch (_) {
      defaults = null;
    }
    final vt = (defaults?['vendorTable'] as Map?)?.cast<String, dynamic>();
    _vendorTable = vt?.map((k, v) => MapEntry(k, v as String)) ?? {};
    final defQ = (defaults?['editorQuarantine'] as Map?) ?? {};
    // 隔离名单：config 持久化优先；首次运行从资产默认值播种。
    if (!_quarantineConfigFile().existsSync()) {
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
    if (_editorJournalFile().existsSync()) {
      _startJournalTimerIfNeeded();
    }
    notifyListeners();
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

  /// 兼容旧调用点：历史崩溃不再阻止打开。
  bool isEditorOpenBlocked(PluginMetadata meta) => false;

  void _sendQuarantineToEngine() {
    _commandSender?.call({
      'cmd': 'setEditorQuarantineList',
      'patterns': _closeQuarantine.join(','),
    });
  }

  Map<String, List<String>> _readQuarantineConfig() {
    try {
      final f = _quarantineConfigFile();
      if (!f.existsSync()) return {'close': const [], 'open': const []};
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return {
        'close': (j['close'] as List?)?.cast<String>() ?? const [],
        'open': (j['open'] as List?)?.cast<String>() ?? const [],
      };
    } catch (_) {
      return {'close': const [], 'open': const []};
    }
  }

  void _saveQuarantineLists({
    required List<String> close,
    required List<String> open,
  }) {
    try {
      final f = _quarantineConfigFile();
      if (!f.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'close': close.where((p) => p.isNotEmpty).toSet().toList(),
          'open': open.where((p) => p.isNotEmpty).toSet().toList(),
        }),
      );
    } catch (e) {
      debugPrint('[PluginManager] quarantine config save failed: $e');
    }
  }

  /// 厂商表填充：命中（小写 name/path 子串）即覆盖引擎 vendor 字段。
  String? _vendorLookup(PluginMetadata meta) {
    final ln = meta.name.toLowerCase();
    final lp = meta.path.toLowerCase();
    for (final e in _vendorTable.entries) {
      if (ln.contains(e.key)) return e.value;
      if (lp.contains(e.key)) return e.value;
    }
    return null;
  }

  /// 崩溃日志：记录「正在打开该插件编辑器」。进程若在健康期内退出
  /// （未及 sweep 移除），下次启动自动登记。
  void _journalEditorOpened(PluginMetadata meta) {
    try {
      final f = _editorJournalFile();
      if (!f.existsSync()) f.parent.createSync(recursive: true);
      List existing;
      try {
        existing = (jsonDecode(f.readAsStringSync()) as List?) ?? [];
      } catch (_) {
        existing = [];
      }
      existing.removeWhere((e) => e is Map && e['path'] == meta.path);
      existing.add({
        'path': meta.path,
        'name': meta.name,
        'openedAt': DateTime.now().millisecondsSinceEpoch,
      });
      f.writeAsStringSync(jsonEncode(existing));
      // 写入日志后确保清扫定时器已激活
      _startJournalTimerIfNeeded();
    } catch (_) {}
  }

  /// 周期清扫：打开超过 kOpenHealthyMs 的条目视为「打开成功」，从日志移除。
  void sweepEditorJournal() {
    try {
      final f = _editorJournalFile();
      if (!f.existsSync()) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! List) {
        f.deleteSync();
        return;
      }
      final alive = j.where((e) {
        if (e is! Map) return false;
        final t = e['openedAt'];
        return t is int && (now - t) < kOpenHealthyMs;
      }).toList();
      if (alive.isEmpty) {
        f.deleteSync();
      } else {
        f.writeAsStringSync(jsonEncode(alive));
      }
    } catch (_) {}
  }

  /// 启动时检查崩溃日志：上一进程在编辑器打开后未健康化前退出（打开即崩溃）
  /// → 自动把该插件登记进 open 名单并持久化。登记后清空日志。
  void _autoRegisterFromCrashJournal() {
    List<String> crashed = [];
    try {
      final f = _editorJournalFile();
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is List) {
        for (final e in j) {
          if (e is! Map) continue;
          final p = _crashPattern(e['name'] as String?, e['path'] as String?);
          if (p != null && p.isNotEmpty) crashed.add(p);
        }
      }
      f.deleteSync();
    } catch (_) {}
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
      notifyListeners();
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
      const Duration(milliseconds: kOpenHealthyMs),
      (_) {
        sweepEditorJournal();
        // 若日志文件已不存在，则停止定时器，减少资源占用
        if (!_editorJournalFile().existsSync()) {
          _journalTimer?.cancel();
          _journalTimer = null;
        }
      },
    );
  }

  @override
  void dispose() {
    _journalTimer?.cancel();
    _journalTimer = null;
    super.dispose();
  }

  // --- 底层引擎事件回调处理 ---

  /// A5: 引擎 `auradsp_plugin_slot_load` 只返回 0/1，本身不携带诊断信息，
  /// 旧文案把 rc/slot 抛给用户却永远只能显示 "rc=0"，等于什么都没说。
  String _describeLoadFailure(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    if (!File(path).existsSync()) {
      return '插件文件不存在或已被移动：$name。'
          '请重新扫描插件，或在「自定义检索目录」中重新添加其所在位置。';
    }
    return '插件加载失败：$name。文件存在但引擎无法完成初始化，'
        '可能是格式不兼容、位数不符或文件已损坏。';
  }

  void onPluginScanned(int count, dynamic rawJson) {
    _isScanning = false;
    _scanDone = _scanTotal; // 收尾：进度条走满（避免停在 99% 的观感）
    _lastScanCount = count;
    _parsePluginsJson(rawJson);
    saveCache();
    notifyListeners();
  }

  void onPluginList(dynamic rawJson) {
    _parsePluginsJson(rawJson);
    notifyListeners();
  }

  void onPluginSlotLoaded(
    int slot,
    String path,
    int rc,
    dynamic rawStatus,
    int stage,
  ) {
    if (slot >= 0 && slot < kMaxSlots) {
      _slotBusy[slot] = false; // C3：任务终态，忙态清除
      _slotBusyAction.remove(slot);
      if (rc != 1) {
        // D2：扫描列表里已标记不兼容的插件（当前唯一情形：32 位）直接用
        // 引擎的精确原因，不再让用户看"可能位数不符"的猜测文案。
        // 引擎侧 load() 与 Dart loadPlugin() 都不放行，这里是最后一道兜底。
        PluginMetadata? known;
        for (final p in _plugins) {
          if (p.path == path) {
            known = p;
            break;
          }
        }
        if (known != null &&
            !known.isCompatible &&
            known.errorMessage.isNotEmpty) {
          _lastError = '${known.name}：${known.errorMessage}';
        } else {
          _lastError = _describeLoadFailure(path);
        }
      } else {
        _lastError = null;
        // P2 边界：挂载成功后自动应用激活 A/B 预设（若有记录）——
        // 模式切换/重挂后插件是出厂态，不恢复会丢调音。
        _restoreAbAfterLoad(slot);
      }
      _slotStages[slot] = stage;
      _parseStatusJsonForSlot(slot, rawStatus);
      notifyListeners();
    }
  }

  void onPluginSlotUnloaded(int slot, int rc, dynamic rawStatus) {
    if (slot >= 0 && slot < kMaxSlots) {
      _slotBusy[slot] = false; // C3：任务终态，忙态清除
      _slotBusyAction.remove(slot);
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

  /// 处理引擎对插入阶段的回执。
  /// 引擎契约：rc=1 成功，rc=0 拒绝；拒绝时回滚到下发前的值，
  /// 避免「引擎拒绝但 UI 显示成功」。
  void onPluginSlotInsertStage(int slot, int stage, int rc) {
    if (slot < 0 || slot >= kMaxSlots) return;
    if (rc != 1) {
      _slotStages[slot] = _pendingStages.remove(slot) ?? _slotStages[slot];
    } else {
      _pendingStages.remove(slot);
      _slotStages[slot] = stage;
    }
    notifyListeners();
  }

  void onPluginSlotChannels(int slot, int mask, int rc) {
    if (slot < 0 || slot >= kMaxSlots) return;
    if (rc == 1) _slotChannels[slot] = mask;
    notifyListeners();
  }

  // 向后兼容旧单槽事件
  void onPluginLoaded(String path, int rc, dynamic rawStatus) =>
      onPluginSlotLoaded(
        0,
        path,
        rc,
        rawStatus,
        PluginInsertStage.defaultStage,
      );

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

      _plugins = list.whereType<Map>().map((m) {
        final meta = PluginMetadata.fromJson(Map<String, dynamic>.from(m));
        // 厂商表覆盖（预设数据查表，引擎不再硬编码厂商名）：命中即覆盖。
        final v = _vendorLookup(meta);
        return v != null && v != meta.vendor ? meta.copyWith(vendor: v) : meta;
      }).toList();
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
      final status = PluginHostStatus.fromJson(map);
      _slotStatuses[slot] = status;
      if (map.containsKey('channels')) {
        _slotChannels[slot] = (map['channels'] as num?)?.toInt() ?? 0xFF;
      }
    } catch (e) {
      debugPrint(
        '[PluginManager] Error parsing status JSON for slot $slot: $e',
      );
    }
  }

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
      final file = _getCacheFile();
      if (!await file.exists()) {
        return;
      }
      final text = await file.readAsString();
      final dynamic decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != kCacheSchemaVersion) {
        debugPrint(
          '[PluginManager] loadCache：缓存 schema 不符或为旧版裸 list，'
          '整份丢弃，等待重新扫描',
        );
        return;
      }
      final list = decoded['plugins'];
      if (list is! List) {
        debugPrint('[PluginManager] loadCache：信封缺少 plugins 数组，丢弃');
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
        debugPrint('[PluginManager] loadCache 剔除失效插件条目 $dropped 个');
      }
      if (_plugins.isNotEmpty) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[PluginManager] loadCache error: $e');
    }
  }

  /// 保存磁盘缓存（信封格式 + 落盘自检）。
  Future<void> saveCache() async {
    try {
      // 自检：非空快照却拿不到任何厂商名，是伪造/损坏缓层的签名，
      // 拒绝写回，避免把坏数据固化成"官方缓存"。
      if (_plugins.isNotEmpty &&
          _plugins.every((p) => p.vendor.isEmpty || p.vendor == 'Unknown')) {
        debugPrint(
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
      debugPrint('[PluginManager] saveCache error: $e');
    }
  }

  // ==================== P2 A/B 预设槽（v3.3） ====================
  // 每「插件-槽位」两套预设 A/B（VB 再按 route 细分），内容 = 插件 state
  // + Ch 选择。激活槽自动记录（编辑器关闭/切换/切路由时落盘）；继承 =
  // 一次性复制（调参即归自定义）；复原清槽（不动源）。

  /// 每 (slot, route) 的激活槽：'$slot|$route' -> 'A' | 'B'。
  final Map<String, String> _abActive = {};

  /// 每槽元数据：'$slot|$route|$ab' -> {hasState, source, chMask}。
  /// source: 'custom' | 'inherit:r{route}:{A|B}'。
  final Map<String, Map<String, dynamic>> _abMeta = {};

  /// 各槽预设归属的插件 id（换插件即换预设库）。
  final List<String?> _abPluginId = List.filled(kMaxSlots, null, growable: true);

  /// 确定性短 hash（FNV-1a 32bit）——Dart String.hashCode 每次运行不同，
  /// 不能用于持久化文件名。
  static String _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final u in s.codeUnits) {
      h ^= u;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  String _abPluginKey(int slot) {
    final meta = getSlotPlugin(slot);
    final id = meta == null
        ? 'empty'
        : _fnv1a('${meta.path}|${meta.name}');
    return id;
  }

  Directory _abDir(String pluginId) => Directory(
      ConfigManager.path('plugin_presets${Platform.pathSeparator}.ab${Platform.pathSeparator}$pluginId'));

  String _abFile(int slot, int route, String ab) =>
      '${_abDir(_abPluginKey(slot)).path}${Platform.pathSeparator}s${slot}_r$route$ab.aurapreset';

  String _abMetaPath(String pluginId) =>
      '${_abDir(pluginId).path}${Platform.pathSeparator}meta.json';

  String _abKey(int slot, int route) => '$slot|$route';
  String _abKey2(int slot, int route, String ab) => '$slot|$route|$ab';

  /// 惰性加载/切换插件时重载预设库。
  void _ensureAbLoaded(int slot) {
    final id = _abPluginKey(slot);
    if (_abPluginId[slot] == id) return;
    _abPluginId[slot] = id;
    // 清除该 slot 的内存缓存再读盘（换插件 = 换预设库）。
    _abActive.removeWhere((k, _) => k.startsWith('$slot|'));
    _abMeta.removeWhere((k, _) => k.startsWith('$slot|'));
    try {
      final f = File(_abMetaPath(id));
      if (!f.existsSync()) return;
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final slots = (raw['slots'] as Map<String, dynamic>?) ?? {};
      final sr = (slots['$slot'] as Map<String, dynamic>?) ?? {};
      sr.forEach((rk, rv) {
        final r = rv as Map<String, dynamic>;
        _abActive[_abKey(slot, _routeFromKey(rk))] =
            (r['active'] as String?) ?? 'A';
        for (final ab in ['A', 'B']) {
          final m = (r[ab] as Map<String, dynamic>?) ??
              {'hasState': false, 'source': 'custom', 'chMask': 0xFF};
          _abMeta[_abKey2(slot, _routeFromKey(rk), ab)] = {
            'hasState': m['hasState'] == true,
            'source': m['source'] as String? ?? 'custom',
            'chMask': (m['chMask'] as num?)?.toInt() ?? 0xFF,
          };
        }
      });
    } catch (e) {
      debugPrint('[PluginManager] ab load error: $e');
    }
  }

  static int _routeFromKey(String k) =>
      k == 'rm1' ? -1 : int.tryParse(k.substring(1)) ?? -1;
  static String _routeKey(int route) => route < 0 ? 'rm1' : 'r$route';

  void _abPersist(int slot) {
    try {
      final id = _abPluginKey(slot);
      final dir = _abDir(id);
      dir.createSync(recursive: true);
      final slots = <String, dynamic>{};
      final seenRoutes = <int>{};
      for (final k in _abActive.keys) {
        final parts = k.split('|');
        if (parts[0] != '$slot') continue;
        seenRoutes.add(_routeFromKey(parts[1]));
      }
      for (final k in _abMeta.keys) {
        final parts = k.split('|');
        if (parts[0] != '$slot') continue;
        seenRoutes.add(_routeFromKey(parts[1]));
      }
      for (final route in seenRoutes) {
        final rk = _routeKey(route);
        slots[rk] = {
          'active': _abActive[_abKey(slot, route)] ?? 'A',
          'A': _abMeta[_abKey2(slot, route, 'A')] ??
              {'hasState': false, 'source': 'custom', 'chMask': 0xFF},
          'B': _abMeta[_abKey2(slot, route, 'B')] ??
              {'hasState': false, 'source': 'custom', 'chMask': 0xFF},
        };
      }
      File(_abMetaPath(id)).writeAsStringSync(jsonEncode({'slots': slots}));
    } catch (e) {
      debugPrint('[PluginManager] ab persist error: $e');
    }
  }

  Map<String, dynamic> _abMetaOf(int slot, int route, String ab) {
    _ensureAbLoaded(slot);
    return _abMeta[_abKey2(slot, route, ab)] ??=
        {'hasState': false, 'source': 'custom', 'chMask': 0xFF};
  }

  /// 当前激活槽（默认 A——插件加载即 A 记录）。
  String abActive(int slot, {int group = -1}) {
    _ensureAbLoaded(slot);
    return _abActive[_abKey(slot, group)] ?? 'A';
  }

  /// 槽元数据（UI：hasState/source/chMask）。
  Map<String, dynamic> abMeta(int slot, {int group = -1, required String ab}) =>
      Map.unmodifiable(_abMetaOf(slot, group, ab));

  /// A/B 预设文件路径（继承复制时作源/目标）。
  String abFilePath(int slot, {int group = -1, required String ab}) =>
      _abFile(slot, group, ab);

  /// 自动保存：当前实例 state + Ch → 激活槽（source 归 custom）。
  /// 时机：编辑器关闭 / 切换 A-B / 切路由 / 卸载前——用户感知「自动记录」。
  void autoSaveAb(int slot, {int group = -1}) {
    if (!isSlotActive(slot)) return;
    _ensureAbLoaded(slot);
    final ab = abActive(slot, group: group);
    final path = _abFile(slot, group, ab);
    try {
      _abDir(_abPluginKey(slot)).createSync(recursive: true);
    } catch (_) {}
    _commandSender?.call({
      'cmd': 'pluginSlotSavePresetG',
      'slot': slot,
      'group': group,
      'path': path,
    });
    final m = _abMetaOf(slot, group, ab);
    m['hasState'] = true;
    m['source'] = 'custom'; // 用户调过即自定义（继承后调参自动脱钩）
    m['chMask'] = getSlotChannels(slot, group: group);
    _abPersist(slot);
    notifyListeners();
  }

  /// 切换/激活 A 或 B。
  /// [inheritFrom] null = 自动保存（自定义）；'r{route}:{A|B}' = 一次性复制
  /// 该源预设（state 文件拷贝 + Ch 继承），复制后与源无关。
  void selectAb(int slot, {int group = -1, required String ab, String? inheritFrom}) {
    if (ab != 'A' && ab != 'B') return;
    if (!isSlotActive(slot)) return;
    _ensureAbLoaded(slot);
    // 离开当前状态前存回激活槽（不丢调音）。
    autoSaveAb(slot, group: group);
    final m = _abMetaOf(slot, group, ab);
    if (inheritFrom != null) {
      // 解析源 'r{route}:{A|B}'（排除自身已在 UI 过滤）。
      final mm = RegExp(r'^r(-?\d+):([AB])$').firstMatch(inheritFrom);
      if (mm != null) {
        final srcRoute = int.parse(mm.group(1)!);
        final srcAb = mm.group(2)!;
        final srcFile = _abFile(slot, srcRoute, srcAb);
        final dstFile = _abFile(slot, group, ab);
        try {
          _abDir(_abPluginKey(slot)).createSync(recursive: true);
          if (File(srcFile).existsSync()) {
            File(srcFile).copySync(dstFile);
            _commandSender?.call({
              'cmd': 'pluginSlotLoadPresetG',
              'slot': slot,
              'group': group,
              'path': dstFile,
            });
            m['hasState'] = true;
          } else {
            m['hasState'] = false;
          }
        } catch (e) {
          debugPrint('[PluginManager] ab inherit error: $e');
        }
        m['source'] = 'inherit:$inheritFrom';
        // Ch 跟随**源预设快照**的 chMask（不是源路由的当前记忆——
        // 边界修复：源预设可能早于当前路由记忆存档）。
        final srcMeta = _abMetaOf(slot, srcRoute, srcAb);
        final srcCh = (srcMeta['chMask'] as num?)?.toInt() ?? 0xFF;
        m['chMask'] = srcCh;
        setSlotChannels(srcCh, slot: slot, group: group);
      }
    } else if (m['hasState'] == true) {
      // 激活已有内容的槽：应用其 state。
      _commandSender?.call({
        'cmd': 'pluginSlotLoadPresetG',
        'slot': slot,
        'group': group,
        'path': _abFile(slot, group, ab),
      });
      setSlotChannels((m['chMask'] as num?)?.toInt() ?? 0xFF,
          slot: slot, group: group);
    }
    // 空槽 + 自动保存：不动参数，从此刻开始自动记录（「空预设」语义）。
    _abActive[_abKey(slot, group)] = ab;
    _abPersist(slot);
    notifyListeners();
  }

  /// 复原：清除该槽预设（回空；继承的源预设不动）。
  void resetAb(int slot, {int group = -1, required String ab}) {
    if (ab != 'A' && ab != 'B') return;
    _ensureAbLoaded(slot);
    try {
      final f = File(_abFile(slot, group, ab));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    _abMeta[_abKey2(slot, group, ab)] = {
      'hasState': false,
      'source': 'custom',
      'chMask': 0xFF,
    };
    _abPersist(slot);
    notifyListeners();
  }

  /// 挂载成功后恢复激活 A/B 预设（P2 边界：模式切换/重挂后插件出厂态，
  /// 不恢复则调音丢失）。VB 各有记录的路由逐路恢复；非 VB 恢复 -1 路。
  void _restoreAbAfterLoad(int slot) {
    _ensureAbLoaded(slot);
    final routes = <int>{-1};
    for (var g = 0; g < 8; g++) {
      if (_abMeta.containsKey(_abKey2(slot, g, 'A')) ||
          _abMeta.containsKey(_abKey2(slot, g, 'B'))) {
        routes.add(g);
      }
    }
    for (final route in routes) {
      final ab = abActive(slot, group: route);
      final m = _abMetaOf(slot, route, ab);
      if (m['hasState'] != true) continue;
      _commandSender?.call({
        'cmd': 'pluginSlotLoadPresetG',
        'slot': slot,
        'group': route,
        'path': _abFile(slot, route, ab),
      });
      final ch = (m['chMask'] as num?)?.toInt() ?? 0xFF;
      setSlotChannels(ch, slot: slot, group: route);
    }
    notifyListeners();
  }
}
