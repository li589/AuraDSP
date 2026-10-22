// part of state.dart —— P6 按区拆分，extension 包装零逻辑改动。
part of '../state.dart';

/// Voicemeeter 桥总线/插件组 + ASIO 驱动选择 + VAIO 输出端点。
///
/// 方法体逐字保留自 AppModel 类体（notifyListeners() 按 P2 约定改调
/// _notifyUi()）。

extension VbAsioState on AppModel {

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
