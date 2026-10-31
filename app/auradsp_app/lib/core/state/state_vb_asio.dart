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
  void setVbBus(int group, bool on) {
    if (group < 0 || group > 7) return;
    final next = on ? (vbBusMask | (1 << group)) : (vbBusMask & ~(1 << group));
    if (next == vbBusMask) return;
    vbBusMask = next & 0xFF;
    config.vbBusMask = vbBusMask;
    ConfigManager.save(config);
    _toIso?.send({'cmd': 'setBusMask', 'mask': vbBusMask});
    // 关掉当前编辑器所在总线后，目标路会脱离有效掩码 → 与按路插件开关
    // 走同一回落逻辑（否则 UI 下拉指向不存在的 items）。
    _fallbackVbPluginEditorGroup();
    _notifyUi();
  }

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
    // 全关在 UI 语义 = 「全部不勾」；落盘仍用原值（0 回全开口径只影响加载），
    // 这里直接保存 0xFF/0x00 原值：全关是用户显式选择。
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
