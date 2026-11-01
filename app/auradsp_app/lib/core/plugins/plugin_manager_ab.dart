// plugin_manager_ab.dart — A/B 预设槽（v3.3）（plugin_manager.dart 的 part，2026-10-28 拆分）。
part of 'plugin_manager.dart';

extension PluginManagerAb on PluginManager {
  // ==================== P2 A/B 预设槽（v3.3） ====================
  // 每「插件-槽位」两套预设 A/B（VB 再按 route 细分），内容 = 插件 state
  // + Ch 选择。激活槽自动记录（编辑器关闭/切换/切路由时落盘）；继承 =
  // 一次性复制（调参即归自定义）；复原清槽（不动源）。

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
      final read = DocumentStore.readJson(_abMetaPath(id));
      if (!read.ok) return;
      final raw = read.data!;
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
    // F-3：VB 多总线模式下 -1 不是合法路（落盘会被桥「单组 0」写成
    // eng[0]，与 route 0 独立预设互相覆盖）——直接跳过，不落盘。
    if (group < 0 && _vbMultiBus) return;
    _ensureAbLoaded(slot);
    final ab = abActive(slot, group: group);
    final path = _abFile(slot, group, ab);
    try {
      _abDir(_abPluginKey(slot)).createSync(recursive: true);
    } catch (e, st) { swallow(e, st); }
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
    _notify();
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
    _notify();
  }

  /// 复原：清除该槽预设（回空；继承的源预设不动）。
  void resetAb(int slot, {int group = -1, required String ab}) {
    if (ab != 'A' && ab != 'B') return;
    _ensureAbLoaded(slot);
    try {
      final f = File(_abFile(slot, group, ab));
      if (f.existsSync()) f.deleteSync();
    } catch (e, st) { swallow(e, st); }
    _abMeta[_abKey2(slot, group, ab)] = {
      'hasState': false,
      'source': 'custom',
      'chMask': 0xFF,
    };
    _abPersist(slot);
    _notify();
  }

  /// 挂载成功后恢复激活 A/B 预设（P2 边界：模式切换/重挂后插件出厂态，
  /// 不恢复则调音丢失）。VB 各有记录的路由逐路恢复；非 VB 恢复 -1 路。
  ///
  /// F-3：VB 多总线模式下**不含 -1 路**——-1 会被桥「单组 0」写成
  /// eng[0]，与 route 0 的独立预设互相覆盖（自我强化污染）。
  void _restoreAbAfterLoad(int slot) {
    _ensureAbLoaded(slot);
    final routes = <int>{if (!_vbMultiBus) -1};
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
    _notify();
  }
}
