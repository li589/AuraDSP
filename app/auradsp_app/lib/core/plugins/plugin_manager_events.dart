// plugin_manager_events.dart — 引擎事件回调与 JSON 解析（plugin_manager.dart 的 part，2026-10-28 拆分）。
part of 'plugin_manager.dart';

extension PluginManagerEvents on PluginManager {
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

  /// 扫描完成。`aborted` = 中途失败（深扫插件挂死/IPC 超时等）：此时
  /// 引擎可能只回传了残缺列表甚至空表，**保留上一次成功结果**并提示，
  /// 避免「一次坏插件把整个插件库清空」的观感事故。
  void onPluginScanned(int count, dynamic rawJson, {bool aborted = false}) {
    _isScanning = false;
    _scanDone = _scanTotal; // 收尾：进度条走满（避免停在 99% 的观感）
    if (aborted) {
      _lastScanCount = _plugins.length;
      _lastNotice = '扫描中断：有插件在读取元数据时无响应（已超时跳过），'
          '已保留上次扫描结果。可取消「深度遍历」后重试。';
      _notify();
      return;
    }
    _lastScanCount = count;
    _parsePluginsJson(rawJson);
    saveCache();
    _notify();
  }

  void onPluginList(dynamic rawJson) {
    _parsePluginsJson(rawJson);
    _notify();
  }

  void onPluginSlotLoaded(
    int slot,
    String path,
    int rc,
    dynamic rawStatus,
    int stage,
  ) {
    if (slot >= 0 && slot < PluginManager.kMaxSlots) {
      _slotBusy[slot] = false; // C3：任务终态，忙态清除
      _slotBusyAction.remove(slot);
      _bypassPendingTimers.remove(slot)?.cancel();
      _slotBypassPending.remove(slot); // 挂载即出厂旁路语义，在途标记不残留
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
        // 挂载即旁路（P-041，2026-10-28）：引擎 commitInstanceLocked 现在
        // 挂载时恒置旁路（本处旧的 bypass:true 冗余下发已删——它会在会话
        // 回放恢复 bypass=false 的槽之后到达，把用户保存的激活态覆盖成
        // 旁路）。UI 状态直接跟随引擎回读：挂载后 isSlotBypassed==true，
        // 用户手动取消旁路才生效。
      }
      _slotStages[slot] = stage;
      _parseStatusJsonForSlot(slot, rawStatus);
      _notify();
    }
  }

  void onPluginSlotUnloaded(int slot, int rc, dynamic rawStatus) {
    if (slot >= 0 && slot < PluginManager.kMaxSlots) {
      _slotBusy[slot] = false; // C3：任务终态，忙态清除
      _slotBusyAction.remove(slot);
      _bypassPendingTimers.remove(slot)?.cancel();
      _slotBypassPending.remove(slot);
      _parseStatusJsonForSlot(slot, rawStatus);
      _notify();
    }
  }

  void onPluginSlotBypass(int slot, bool bypass, dynamic rawStatus) {
    if (slot >= 0 && slot < PluginManager.kMaxSlots) {
      _parseStatusJsonForSlot(slot, rawStatus);
      _notify();
    }
  }

  void onPluginSlotStatus(int slot, dynamic rawStatus, int stage) {
    if (slot >= 0 && slot < PluginManager.kMaxSlots) {
      _slotStages[slot] = stage;
      _parseStatusJsonForSlot(slot, rawStatus);
      _notify();
    }
  }

  /// 处理引擎对插入阶段的回执。
  /// 引擎契约：rc=1 成功，rc=0 拒绝；拒绝时回滚到下发前的值，
  /// 避免「引擎拒绝但 UI 显示成功」。
  void onPluginSlotInsertStage(int slot, int stage, int rc) {
    if (slot < 0 || slot >= PluginManager.kMaxSlots) return;
    if (rc != 1) {
      _slotStages[slot] = _pendingStages.remove(slot) ?? _slotStages[slot];
    } else {
      _pendingStages.remove(slot);
      _slotStages[slot] = stage;
    }
    _notify();
  }

  /// Ch 回执（A4：携带下发路由 [group]，按路归位——旧版恒写
  /// [_slotChannels]，VB 下任一路的 Ch 回执都会污染 -1 路记忆）。
  /// rc != 1 时不改记忆（保留 setSlotChannels 的乐观值）。
  void onPluginSlotChannels(int slot, int mask, int rc, {int group = -1}) {
    if (slot < 0 || slot >= PluginManager.kMaxSlots) return;
    final key = '$slot|$group';
    final prev = _pendingChannels.remove(key);
    if (rc == 1) {
      if (group >= 0 && group < 8) {
        _routeChannels[slot][group] = mask;
      } else {
        _slotChannels[slot] = mask;
      }
    } else if (prev != null) {
      // F-7：引擎拒收 → 回滚乐观写入（否则 UI 显示的 Ch 与实际生效不一致）。
      if (group >= 0 && group < 8) {
        _routeChannels[slot][group] = prev;
      } else {
        _slotChannels[slot] = prev;
      }
    }
    _notify();
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
      // 引擎回读确认旁路到位 → 解除在途标记（与请求值一致才算到位）。
      // 调用方（onPluginSlotBypass/onPluginSlotStatus 等）随后 notifyListeners。
      final pending = _slotBypassPending[slot];
      if (pending != null && status.bypassed == pending) {
        _bypassPendingTimers.remove(slot)?.cancel();
        _slotBypassPending.remove(slot);
      }
      if (map.containsKey('channels')) {
        _slotChannels[slot] = (map['channels'] as num?)?.toInt() ?? 0xFF;
      }
    } catch (e) {
      debugPrint(
        '[PluginManager] Error parsing status JSON for slot $slot: $e',
      );
    }
  }
}
