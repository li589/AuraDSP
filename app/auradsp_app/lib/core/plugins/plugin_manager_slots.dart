// plugin_manager_slots.dart — 槽位生命周期/编辑器/阶段/声道控制（plugin_manager.dart 的 part，2026-10-28 拆分）。
part of 'plugin_manager.dart';

extension PluginManagerSlots on PluginManager {
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
      _notify();
      return;
    }
    // C3：乐观置忙（引擎回执 pluginSlotBusy 会再确认一次）。
    _slotBusy[s] = true;
    _slotBusyAction[s] = 'load';
    _notify();
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
    // 注意顺序：**先存预设、再置直通**——直通（bypass）不是调音内容，
    // 绝不能被记录进预设（预设仅 state+Ch）。
    autoSaveAb(s, group: _editorRoute[s] >= 0 ? _editorRoute[s] : -1);
    _slotBusy[s] = true;
    _slotBusyAction[s] = 'unload';
    // 卸载接管全部过渡（含其内部下发的一次 bypass:true），在途标记失效。
    _bypassPendingTimers.remove(s)?.cancel();
    _slotBypassPending.remove(s);
    _notify();
    // 优雅卸载（2026-10-22）：先内部直通（该槽 bypass，链早退）让音频
    // 平滑过渡，短延迟等音频回调走过几块后再真正卸载——大插件 teardown
    // 2-3s 的扰动不再影响音频流。重挂时引擎出厂 bypass=false，不残留。
    _commandSender?.call({
      'cmd': 'pluginSlotSetBypass',
      'slot': s,
      'bypass': true,
    });
    Timer(const Duration(milliseconds: 150), () {
      _commandSender?.call({'cmd': 'pluginSlotUnload', 'slot': s});
    });
  }

  /// 设置指定槽位旁路
  ///
  /// 置在途标记后立即通知（按钮转 spinner、防连点/防卸载竞态），引擎
  /// 状态回读确认到位后自动解除（见 [_parseStatusJsonForSlot]）。
  void setBypass(bool bypass, {int? slot}) {
    final s = slot ?? _selectedSlot;
    _slotBypassPending[s] = bypass;
    _bypassPendingTimers[s]?.cancel();
    _bypassPendingTimers[s] = Timer(const Duration(seconds: 10), () {
      if (_slotBypassPending.remove(s) != null) _notify();
    });
    _notify();
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
    _notify();
    _commandSender?.call({'cmd': 'pluginSetPdc', 'pdc': enable});
  }

  bool get pdcEnabled => _pdcEnabled;

  void onPluginPdc(bool pdc, int rc) {
    if (rc == 1) {
      _pdcEnabled = pdc;
    }
    _notify();
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
  }) {
    final s = slot ?? _selectedSlot;
    final meta = getSlotPlugin(s);
    if (meta != null && isEditorCrashKnown(meta)) {
      _lastNotice =
          '${meta.name}：该插件曾导致 AuraDSP 崩溃。已记录到隔离名单，'
          '关闭插件时将跳过其自身的 teardown（removed/release）以避免二次崩溃；'
          '插件仍会正常加载和运行，但可能残留少量资源。';
      _notify();
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

  /// 编辑器回执（P1-1）：更新打开态；关闭成功时把当前调音落盘到该路
  /// A/B 激活槽（与轮询解锁同口径，含非 VB 单路 group=-1）。
  void onPluginSlotEditorResult(int slot, String action, bool ok) {
    if (slot < 0 || slot >= PluginManager.kMaxSlots) return;
    if (action == 'show') {
      _slotEditorOpen[slot] = ok;
    } else if (action == 'close' && ok) {
      _slotEditorOpen[slot] = false;
      final r = _editorRoute[slot];
      _editorRoute[slot] = -1;
      // P2 自动记录：编辑器关闭即把当前调音落盘到激活 A/B 槽。
      autoSaveAb(slot, group: r >= 0 ? r : -1);
      _notify();
      return;
    }
    _notify();
  }

  /// status 轮询兜底（P1-1）：用户直接点插件自带关闭按钮时同步打开态。
  ///
  /// 落盘口径与 [onPluginSlotEditorResult] 的 close 回执**完全一致**：
  /// 含非 VB 单路（group=-1）。历史版本这里只处理 `_editorRoute >= 0`，
  /// 非 VB 用户点插件自带关闭按钮时轮询解锁不落盘——该次调音不进
  /// A/B 预设，重挂/模式切换后丢失（2026-10-22 审查 A2）。
  void onSlotEditorOpenPolled(int slot, bool open) {
    if (slot < 0 || slot >= PluginManager.kMaxSlots) return;
    if (_slotEditorOpen[slot] != open) {
      _slotEditorOpen[slot] = open;
      if (!open) {
        // 轮询解锁（用户点插件自带关闭按钮）也要落盘——与 close 回执同语义，
        // 否则该路径下调音不进 A/B 预设。
        final r = _editorRoute[slot];
        autoSaveAb(slot, group: r >= 0 ? r : -1);
        _editorRoute[slot] = -1;
      }
      _notify();
    }
  }

  /// 驱动模式切换（VB/ASIO/VAIO/WASAPI）前的插件状态收尾（P2 边界修复）：
  /// 全部活跃槽的各路由 A/B 激活槽落盘（引擎重建不丢调音）+ 编辑器状态
  /// 清理（重建后旧编辑器窗口已失效）。
  void onAudioModeSwitching() {
    for (var s = 0; s < PluginManager.kMaxSlots; s++) {
      if (!isSlotActive(s)) continue;
      // A3（2026-10-22 审查）：当前正开着编辑器的路——若该路从未落盘过
      // （新插件开界面调完直接切模式，未经关闭回执），旧实现只存 -1 路与
      // 「已有 meta 的路」，这次调音随引擎重建丢失。开过的路必存。
      if (_editorRoute[s] >= 0) autoSaveAb(s, group: _editorRoute[s]);
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
    }
    _notify();
  }

  /// 调整插件在处理链上的插入阶段。
  ///
  /// 保持乐观写入（UI 即时反馈），但记录下发前的值：引擎回执
  /// [onPluginSlotInsertStage] 若带回非 0 的 rc，会回滚到该值，
  /// 避免「引擎拒绝但 UI 显示成功」。
  void setInsertStage(int stage, {int? slot}) {
    final s = slot ?? _selectedSlot;
    _pendingStages[s] = _slotStages[s];
    _slotStages[s] = stage;
    _notify();
    _commandSender?.call({
      'cmd': 'pluginSlotSetInsertStage',
      'slot': s,
      'stage': stage,
    });
  }

  /// 设置 Ch 记忆并下发（P1-4 per-route；group 语义同 [getSlotChannels]）。
  /// VB 具体路 → set_channels_g 只发该组；非 VB → 单路。
  void setSlotChannels(int mask, {int? slot, int group = -1}) {
    final s = slot ?? _selectedSlot;
    if (s < 0 || s >= PluginManager.kMaxSlots) return;
    // F-3：VB 多总线模式下 -1 不是合法路（下发即写 eng[0]）——no-op，
    // 避免 UI 在「未选路」（editorGroup=-1）时误污染 route 0。
    if (group < 0 && _vbMultiBus) return;
    // F-8：group 合法域断言（-1 或 0..7；-2 等哨兵值属误用，直接拒）。
    if (!isValidPluginGroup(group)) return;
    // F-7：乐观写入前记录旧值，回执 rc!=1 时回滚（与阶段回滚同口径）。
    // 键含 group：同槽不同路可各挂一条待确认。
    _pendingChannels['$s|$group'] = getSlotChannels(s, group: group);
    if (group >= 0 && group < 8) {
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
    _notify();
  }

  void refreshStatus({int? slot}) {
    final s = slot ?? _selectedSlot;
    _commandSender?.call({'cmd': 'pluginSlotGetStatus', 'slot': s});
  }
}
