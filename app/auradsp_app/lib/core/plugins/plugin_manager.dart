/*
 * plugin_manager.dart — AuraDSP 第三方插件管理器与状态中心（core/plugins）
 *
 * 2026-10-28 拆分：模型（PluginFormat/PluginMetadata/PluginHostStatus/
 * PluginInsertStage）独立为 plugin_models.dart；管理器方法按职责拆为
 * 5 个 part（slots / tables / events / cache / ab）。对外 API 与语义不变，
 * plugin_manager.dart 继续 export models，既有 import 只需改路径。
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../config.dart';
import '../error_sink.dart';
import 'plugin_models.dart';
import 'text_collation.dart';

export 'plugin_models.dart';

part 'plugin_manager_slots.dart';
part 'plugin_manager_tables.dart';
part 'plugin_manager_events.dart';
part 'plugin_manager_cache.dart';
part 'plugin_manager_ab.dart';

typedef PluginCommandSender = void Function(Map<String, dynamic> msg);

/// VB 按路编辑器目标路的「未选择」哨兵（state.vbPluginEditorGroup 初值）。
/// F-8（2026-10-23）：「全部」在 v3.3 已撤除，本常量只剩「未选」语义——
/// 原名 kVbRouteAll 会让调用方误以为存在「全部路」分支。凡把它当合法
/// group 传入（setSlotChannels/setSlotChannelsG 等）都属误用：range 断言
/// 以 [-1, 8) 为合法域，-2 会被拒。
const int kVbRouteUnselected = -2;

/// group 取值合法域断言（VB 多总线：-1=单引擎/无路，0..7=具体组）。
bool isValidPluginGroup(int group) => group >= -1 && group < 8;

/// 插件管理器
class PluginManager extends ChangeNotifier {
  static const int kMaxSlots = 4;

  PluginCommandSender? _commandSender;

  /// VB 多总线模式（Voicemeeter 每 8 声道一组独立引擎，route 0-7 各自
  /// 独立预设/Ch）。非 VB（单引擎 WASAPI/ASIO/VAIO）下 -1 是唯一合法路。
  ///
  /// F-3（2026-10-23）：VB 下 -1 **不是合法路**——桥按「单组 0」语义把它
  /// 落成 eng[0]，与 route 0 的独立预设互相覆盖（`_restoreAbAfterLoad`
  /// 恒含 -1 → 每次挂载/卸载自我强化污染 route 0）。故 VB 下 -1 路
  /// 既不落盘也不恢复（A1 报告原始建议）。由 AppModel 在构造/模式切换
  /// 时同步（setVbMultiBus）。
  bool _vbMultiBus = false;
  bool get vbMultiBus => _vbMultiBus;
  void setVbMultiBus(bool on) => _vbMultiBus = on;

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
  /// F-7（2026-10-23）：Ch 乐观写入的待确认表（键 "slot|group" → 下发前值）。
  /// 回执 rc!=1 时回滚，避免引擎拒收后 UI 记忆与实际生效值长期不一致。
  final Map<String, int> _pendingChannels = {};

  final List<List<int>> _routeChannels = List.generate(
    kMaxSlots,
    (_) => List.filled(8, 0xFF),
  );

  /// 编辑器当前所在路由（-1=非 VB 单路；>=0=组号），用于关闭时记录来源。
  final List<int> _editorRoute = List.filled(kMaxSlots, -1, growable: true);

  int _selectedSlot = 0;

  List<String> _scanDirs = [];
  bool _isScanning = false;
  String _filterFormat = 'all'; // 'all', 'vst3', 'clap'
  String _searchQuery = '';
  final Map<int, bool> _slotBusy = {};

  /// 忙态动作标记（UI 动画文案：'load' 加载中 / 'unload' 卸载中）。
  final Map<int, String> _slotBusyAction = {};

  /// 旁路切换在途标记（slot → 已下发的目标 bypass 值）。引擎状态回读
  /// 确认与请求一致后自动解除；10s 看门狗兜底（Zone12 级插件 setBypass
  /// 同步秒级返回，正常远小于此；超时即恢复可点，按轮询状态如实显示）。
  final Map<int, bool> _slotBypassPending = {};
  final Map<int, Timer> _bypassPendingTimers = {};
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

  /// 旁路切换是否在途（已下发、引擎尚未回读确认）。UI 据此把旁路按钮
  /// 转切换动画并禁点（防连点、防与卸载竞态）。
  bool isSlotBypassPending(int slot) => _slotBypassPending.containsKey(slot);

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
  List<String> get scanDirs => List.unmodifiable(_scanDirs);
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
  /// [group] >= 0 = VB 具体路；-1 = 非 VB 单引擎（[_slotChannels]）。
  /// F-6（2026-10-23）：直接播种 VB 各路 Ch 记忆（会话恢复用——不下发
  /// 引擎，实际下发由 replay 路径逐路负责；避免恢复期多余命令）。
  void seedRouteChannels(int slot, List<int> masks) {
    if (slot < 0 || slot >= kMaxSlots) return;
    for (var g = 0; g < 8 && g < masks.length; g++) {
      _routeChannels[slot][g] = masks[g];
    }
  }

  int getSlotChannels(int? slot, {int group = -1}) {
    final s = slot ?? _selectedSlot;
    if (s < 0 || s >= kMaxSlots) return 0xFF;
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

  /// 预留格式计数（驱动未实现时恒 0，分类按钮照常显示占位）。
  int get countVst2 =>
      _plugins.where((p) => p.format == PluginFormat.vst2).length;
  int get countAu =>
      _plugins.where((p) => p.format == PluginFormat.au).length;
  int get countLv2 =>
      _plugins.where((p) => p.format == PluginFormat.lv2).length;

  /// 厂商分组（2026-10-28）：厂商按字典序（大小写/变音折叠 + 自然序），
  /// 组内插件按名称同序；未知厂商（空串键）固定沉底。
  Map<String, List<PluginMetadata>> get pluginGroups {
    final map = <String, List<PluginMetadata>>{};
    for (final p in filteredPlugins) {
      final key = TextCollation.vendorKey(p.vendor);
      map.putIfAbsent(key, () => <PluginMetadata>[]).add(p);
    }
    for (final list in map.values) {
      list.sort((a, b) => TextCollation.comparePluginNames(
            a.name,
            b.name,
            a.path,
            b.path,
          ));
    }
    final keys = map.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
        return TextCollation.compare(a, b);
      });
    return <String, List<PluginMetadata>>{
      for (final k in keys) k: map[k]!,
    };
  }

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
  /// 同步「参与扫描」的目录（调用方已按 enabled 过滤；内置目录恒在其中）。
  void setScanDirs(List<String> dirs) {
    _scanDirs = List.from(dirs);
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
    for (final cd in _scanDirs) {
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

  // --- A/B 预设槽状态（方法见 part: plugin_manager_ab.dart） ---

  /// 每 (slot, route) 的激活槽：'$slot|$route' -> 'A' | 'B'。
  final Map<String, String> _abActive = {};

  /// 每槽元数据：'$slot|$route|$ab' -> {hasState, source, chMask}。
  /// source: 'custom' | 'inherit:r{route}:{A|B}'。
  final Map<String, Map<String, dynamic>> _abMeta = {};

  /// 各槽预设归属的插件 id（换插件即换预设库）。
  final List<String?> _abPluginId =
      List.filled(kMaxSlots, null, growable: true);

  /// 内部通知代理：part 扩展里直接调 notifyListeners 会触发
  /// invalid_use_of_protected_member（Flutter 元数据限制），统一走这里。
  void _notify() => notifyListeners();

  @override
  void dispose() {
    _journalTimer?.cancel();
    _journalTimer = null;
    for (final t in _bypassPendingTimers.values) {
      t.cancel();
    }
    _bypassPendingTimers.clear();
    super.dispose();
  }
}
