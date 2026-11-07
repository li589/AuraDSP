// part of state.dart —— P6 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// Voicemeeter 桥总线/插件组 + ASIO 驱动选择 + VAIO 输出端点。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()）。

/// Z15：VB 超预算保护激活时，指定路的插件处理被桥自动旁路（有效掩码收窄
/// 到监听总线 hotGrp，其余路直通）。插件页「生效中」按钮据此显示第三态
/// 「部分旁路」——诚实反映该路插件实际未在处理，但不新增显示点位。
///
/// 纯函数（不依赖 AppModel 实例）便于单测；数据源 = vbstatus 心跳
/// （protect/hotGrp，约 1s 一拍，保护切换本身是秒级过程，1s 刷新足够）。
bool vbRouteProtectBypassed(Map<String, dynamic> info, int group) {
  if (group < 0) return false;
  final protRaw = info['protect'];
  if (protRaw is! num || protRaw.toInt() != 1) return false;
  final hotRaw = info['hotGrp'];
  final hot = hotRaw is num ? hotRaw.toInt() : -1;
  return group != hot;
}

extension VbAsioState on AppModel {

  /// Z15：当前编辑器目标路是否处于「保护旁路」态（见 [vbRouteProtectBypassed]）。
  /// 与用户全旁路（isSlotBypassed）互相独立：本态为 false 时该路插件
  /// 要么完全生效、要么被用户自己旁路。
  bool get vbSelectedRouteProtectBypassed =>
      vbRouteProtectBypassed(vbInfo, vbPluginEditorGroup);

  // ---- Voicemeeter 桥 ----

  /// VB 总线开关：落盘 + 通知；桥在跑则即时下发（mask 活在 ctx，CHANGE 重建不丢）。
  ///
  /// 异步语义（2026-11-07）：界面不等原生返回。开路要建引擎+回放效果器/脚本+
  /// 后台挂插件（重插件 2-4s），关路要逐槽旁路再销毁；底层结构锁在后台补挂
  /// 期间可能被持有 2-4s。这里只发命令 + 入"在途表"，由心跳 routeState 收尾，
  /// 动画与禁点由 [vbRouteBusy] 驱动，绝不阻塞 UI 心跳。
  void setVbBus(int group, bool on) {
    if (group < 0 || group > 7) return;
    // 在途期间拒绝重复点击/重复命令（用户明确：加载期不允许再点、不重复入队）。
    if (vbRouteBusy(group)) return;
    final next = on ? (vbBusMask | (1 << group)) : (vbBusMask & ~(1 << group));
    if (next == vbBusMask) return;
    vbBusMask = next & 0xFF;
    config.vbBusMask = vbBusMask;
    ConfigManager.save(config);
    vbRoutePending[group] = on;
    vbRoutePendingAt[group] = DateTime.now().millisecondsSinceEpoch;
    _toIso?.send({'cmd': 'setBusMask', 'mask': vbBusMask});
    // 关掉当前编辑器所在总线后，目标路会脱离有效掩码 → 与按路插件开关
    // 走同一回落逻辑（否则 UI 下拉指向不存在的 items）。
    _fallbackVbPluginEditorGroup();
    _notifyUi();
  }

  /// 该路是否有在途启停（UI 据此禁点 + 显示加载/释放动画）。
  /// 纯读：超时清理交给 [vbReconcileRoutePending]（避免 build 期改状态）。
  bool vbRouteBusy(int g) {
    final at = vbRoutePendingAt[g];
    if (at == null) return false;
    return DateTime.now().millisecondsSinceEpoch - at <= _kVbRoutePendingMs;
  }

  /// 在途目标是"打开"（true=加载中；false=释放中）。仅在 busy 时有意义。
  bool vbRoutePendingOn(int g) => vbRoutePending[g] ?? false;

  /// 心跳 routeState 确认目标达成 → 清在途，UI 从"加载中/释放中"回到稳态。
  /// 开=就绪(2)，关=已关闭(0)；超时兜底避免桥异常时开关永久锁死。
  void vbReconcileRoutePending() {
    if (vbRoutePending.isEmpty) return;
    final st = (vbInfo['routeState'] as List?)
        ?.map((e) => (e as num?)?.toInt() ?? 0)
        .toList();
    var changed = false;
    final done = <int>[];
    for (final e in vbRoutePending.entries) {
      final state = (st != null && e.key < st.length) ? st[e.key] : -1;
      final bit = (vbBusMask >> e.key) & 1;
      final reached = e.value ? (state == 2) : (state == 0 && bit == 0);
      if (reached) done.add(e.key);
    }
    for (final g in done) {
      vbRoutePending.remove(g);
      vbRoutePendingAt.remove(g);
      changed = true;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    vbRoutePendingAt.removeWhere((g, at) {
      if (nowMs - at <= _kVbRoutePendingMs) return false;
      vbRoutePending.remove(g);
      changed = true;
      return true;
    });
    if (changed) _notifyUi();
  }

  /// 桥停/失活：清空在途（否则开关会等到超时才解禁）。
  void vbClearRoutePending() {
    if (vbRoutePending.isEmpty) return;
    vbRoutePending.clear();
    vbRoutePendingAt.clear();
    _notifyUi();
  }

  static const int _kVbRoutePendingMs = 20000;


  /// VB 按路插件处理开关：bit g = 组 g 总线吃插件链（厂商 DSP 不受影响）。
  void setVbPluginGroup(int group, bool on) {
    if (group < 0 || group > 7) return;
    final next = on
        ? (vbPluginGroupMask | (1 << group))
        : (vbPluginGroupMask & ~(1 << group));
    if (next == vbPluginGroupMask) return;
    vbPluginGroupMask = next & 0xFF;
    config.vbPluginGroupMask = vbPluginGroupMask;
    ConfigManager.save(config);
    _toIso?.send({'cmd': 'setPluginGroupMask', 'mask': vbPluginGroupMask});
    _fallbackVbPluginEditorGroup();
    _notifyUi();
  }

  /// Z12 超预算自动保护开关：回调持续超预算时桥自动收窄插件到监听总线，
  /// 回落后自动还原。关闭即纯手动（组开关照常可用）。
  bool get vbAutoProtect => config.vbAutoProtect;

  void setVbAutoProtect(bool on) {
    if (config.vbAutoProtect == on) return;
    config.vbAutoProtect = on;
    ConfigManager.save(config);
    _toIso?.send({'cmd': 'setPluginAutoProtect', 'on': on});
    _notifyUi();
  }

  /// 批处理：全部总线开/关插件链。
  void setVbPluginGroupAll(bool on) {
    final next = on ? 0xFF : 0x00;
    if (next == vbPluginGroupMask) return;
    // 全关 = 「全部不勾」：只影响有实例的路是否参与插件处理，不决定实例
    // 生死（实例由路开关 mask 决定）。全关仍是合法显式选择，原值落盘。
    vbPluginGroupMask = next;
    config.vbPluginGroupMask = next;
    ConfigManager.save(config);
    _toIso?.send({'cmd': 'setPluginGroupMask', 'mask': vbPluginGroupMask});
    _fallbackVbPluginEditorGroup();
    _notifyUi();
  }

  /// v2 按路编辑器目标路选择（仅有效掩码内合法路；v3.3「全部」已撤除）。
  void setVbPluginEditorGroup(int group) {
    if (group < 0 || group > 7) return;
    if ((vbEffectiveRouteMask & (1 << group)) == 0) return;
    if (vbPluginEditorGroup == group) return;
    vbPluginEditorGroup = group;
    _notifyUi();
  }

  /// 选中路失效（通道关/插件取消勾选）时回落最低有效路；无有效路置 -1。
  void _fallbackVbPluginEditorGroup() {
    if (vbPluginEditorGroup >= 0 &&
        (vbEffectiveRouteMask & (1 << vbPluginEditorGroup)) != 0) {
      return;
    }
    var next = -1;
    for (var g = 0; g < 8; g++) {
      if ((vbEffectiveRouteMask & (1 << g)) != 0) {
        next = g;
        break;
      }
    }
    if (vbPluginEditorGroup != next) {
      vbPluginEditorGroup = next;
    }
  }

  // ---- ASIO 驱动 / VAIO 端点 ----

  /// ASIO 驱动重选：落盘 + 通知；桥在跑则热切换（stop→start 新参数）。
  void setAsioDriver(String name) {
    if (config.asioDriver == name) return;
    config.asioDriver = name;
    ConfigManager.save(config);
    if (asioActive) _sendAsioRestart();
    _notifyUi();
  }

  /// ASIO 缓冲档：0=驱动 preferredSize；桥在跑则热切换。
  void setAsioBufSize(int frames) {
    if (config.asioBufSize == frames) return;
    config.asioBufSize = frames;
    ConfigManager.save(config);
    if (asioActive) _sendAsioRestart();
    _notifyUi();
  }

  /// ASIO 输出对起始声道（L=R+1 配对）；桥在跑则热切换。
  void setAsioOutPair(int ch) {
    if (config.asioOutPair == ch) return;
    config.asioOutPair = ch;
    ConfigManager.save(config);
    if (asioActive) _sendAsioRestart();
    _notifyUi();
  }

  /// 触发一次 ASIO 驱动清单刷新（设置页进入/下拉点开时调）。
  void refreshAsioDrivers() {
    _toIso?.send({'cmd': 'asiodetect'});
  }

  /// AuraVAIO 物理输出端点重选：落盘 + 通知；桥在跑则热切换。
  void setVaioOutputEndpoint(String endpoint) {
    if (config.vaioOutputEndpoint == endpoint) return;
    config.vaioOutputEndpoint = endpoint;
    ConfigManager.save(config);
    if (vaioActive) {
      _toIso?.send({
        'cmd': 'vaiorestart',
        'outputEndpoint': config.vaioOutputEndpoint,
      });
    }
    _notifyUi();
  }

  /// 触发一次 AuraVAIO 驱动与端点探测。
  void refreshVaioDetect() {
    _toIso?.send({'cmd': 'vaiodetect'});
  }

  void _sendAsioRestart() {
    _toIso?.send({
      'cmd': 'asiorestart',
      'driver': config.asioDriver,
      'bufSize': config.asioBufSize,
      'outPair': config.asioOutPair,
    });
  }
}
