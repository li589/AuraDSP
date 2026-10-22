// bridge_plugin_ffi.dart — 三桥共用插件槽 FFI 封装。
//
// 桥 DLL 各自导出 <prefix>_plugin_slot_*（prefix = vb / vaio / asio），
// 语义与引擎 auradsp_plugin_slot_* 完全一致：1=成功，0=失败。
// 桥模式下 Dart 必须把插件命令发给桥自己的引擎，否则插件挂在空闲的本地
// handle 上，编辑器能开但没有音频处理。
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _SlotLoadC = Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _SlotLoadDart = int Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef _SlotUnloadC = Int32 Function(Int32);
typedef _SlotUnloadDart = int Function(int);
typedef _SlotSetBypassC = Int32 Function(Int32, Int32);
typedef _SlotSetBypassDart = int Function(int, int);
typedef _SlotGetBypassC = Int32 Function(Int32);
typedef _SlotGetBypassDart = int Function(int);
typedef _SlotGetLatencyC = Uint32 Function(Int32);
typedef _SlotGetLatencyDart = int Function(int);
typedef _SlotGetStatusC = Int32 Function(Int32, Pointer<Utf8>, Int32);
typedef _SlotGetStatusDart = int Function(int, Pointer<Utf8>, int);
typedef _SlotShowEditorC = Int32 Function(Int32, Pointer<Utf8>);
typedef _SlotShowEditorDart = int Function(int, Pointer<Utf8>);
typedef _SlotCloseEditorC = Int32 Function(Int32);
typedef _SlotCloseEditorDart = int Function(int);
typedef _SlotIsEditorOpenC = Int32 Function(Int32);
typedef _SlotIsEditorOpenDart = int Function(int);
// 编辑器按路变体（v2，仅 VB 桥导出 _g 后缀；老桥 DLL 无此导出，
// 构造时 lookup 失败置 null，调用方以 group < 0 回落到单路绑定）。
typedef _SlotShowEditorGC = Int32 Function(Int32, Int32, Pointer<Utf8>);
typedef _SlotShowEditorGDart = int Function(int, int, Pointer<Utf8>);
typedef _SlotCloseEditorGC = Int32 Function(Int32, Int32);
typedef _SlotCloseEditorGDart = int Function(int, int);
typedef _SlotIsEditorOpenGC = Int32 Function(Int32, Int32);
typedef _SlotIsEditorOpenGDart = int Function(int, int);
typedef _SlotSetStageC = Int32 Function(Int32, Int32);
typedef _SlotSetStageDart = int Function(int, int);
typedef _SlotGetStageC = Int32 Function(Int32);
typedef _SlotGetStageDart = int Function(int);
typedef _SlotSetChannelsC = Int32 Function(Int32, Int32);
typedef _SlotSetChannelsDart = int Function(int, int);
typedef _SlotGetChannelsC = Int32 Function(Int32);
typedef _SlotGetChannelsDart = int Function(int);
// P1-3 per-group Ch 下发（仅新桥导出 _g 后缀）。
typedef _SlotSetChannelsGC = Int32 Function(Int32, Int32, Int32);
typedef _SlotSetChannelsGDart = int Function(int, int, int);
// P1-5 继承复制：srcGroup state → path → 其余组（桥内批处理）。
typedef _SlotSyncAllC = Int32 Function(Int32, Int32, Pointer<Utf8>);
typedef _SlotSyncAllDart = int Function(int, int, Pointer<Utf8>);
// P1-5「不继承」应用「全部」记忆（v1 全组扇出 loadPreset）。
typedef _SlotPresetC = Int32 Function(Int32, Pointer<Utf8>);
typedef _SlotPresetDart = int Function(int, Pointer<Utf8>);

class BridgePluginFfi {
  final DynamicLibrary dylib;
  final String prefix;
  late final _SlotLoadDart _load;
  late final _SlotUnloadDart _unload;
  late final _SlotSetBypassDart _setBypass;
  late final _SlotGetBypassDart _getBypass;
  late final _SlotGetLatencyDart _getLatency;
  late final _SlotGetStatusDart _getStatus;
  late final _SlotShowEditorDart _showEditor;
  late final _SlotCloseEditorDart _closeEditor;
  late final _SlotIsEditorOpenDart _isEditorOpen;
  late final _SlotShowEditorGDart? _showEditorG;
  late final _SlotCloseEditorGDart? _closeEditorG;
  late final _SlotIsEditorOpenGDart? _isEditorOpenG;
  late final _SlotSetStageDart _setStage;
  late final _SlotGetStageDart _getStage;
  late final _SlotSetChannelsDart _setChannels;
  late final _SlotGetChannelsDart _getChannels;
  late final _SlotPresetDart _loadPreset;
  late final _SlotSetChannelsGDart? _setChannelsG;
  late final _SlotSyncAllDart? _syncAll;

  BridgePluginFfi(this.dylib, this.prefix) {
    _load = dylib.lookupFunction<_SlotLoadC, _SlotLoadDart>(
        '${prefix}_plugin_slot_load');
    _unload = dylib.lookupFunction<_SlotUnloadC, _SlotUnloadDart>(
        '${prefix}_plugin_slot_unload');
    _setBypass = dylib.lookupFunction<_SlotSetBypassC, _SlotSetBypassDart>(
        '${prefix}_plugin_slot_set_bypass');
    _getBypass = dylib.lookupFunction<_SlotGetBypassC, _SlotGetBypassDart>(
        '${prefix}_plugin_slot_get_bypass');
    _getLatency = dylib.lookupFunction<_SlotGetLatencyC, _SlotGetLatencyDart>(
        '${prefix}_plugin_slot_get_latency');
    _getStatus = dylib.lookupFunction<_SlotGetStatusC, _SlotGetStatusDart>(
        '${prefix}_plugin_slot_get_status');
    _showEditor = dylib.lookupFunction<_SlotShowEditorC, _SlotShowEditorDart>(
        '${prefix}_plugin_slot_show_editor');
    _closeEditor = dylib.lookupFunction<_SlotCloseEditorC,
        _SlotCloseEditorDart>('${prefix}_plugin_slot_close_editor');
    _isEditorOpen = dylib.lookupFunction<_SlotIsEditorOpenC,
        _SlotIsEditorOpenDart>('${prefix}_plugin_slot_is_editor_open');
    _showEditorG = _lookupShowEditorG(
        '${prefix}_plugin_slot_show_editor_g');
    _closeEditorG = _lookupCloseEditorG(
        '${prefix}_plugin_slot_close_editor_g');
    _isEditorOpenG = _lookupIsEditorOpenG(
        '${prefix}_plugin_slot_is_editor_open_g');
    _setStage = dylib.lookupFunction<_SlotSetStageC, _SlotSetStageDart>(
        '${prefix}_plugin_slot_set_insert_stage');
    _getStage = dylib.lookupFunction<_SlotGetStageC, _SlotGetStageDart>(
        '${prefix}_plugin_slot_get_insert_stage');
    _setChannels = dylib.lookupFunction<_SlotSetChannelsC, _SlotSetChannelsDart>(
        '${prefix}_plugin_slot_set_channels');
    _getChannels = dylib.lookupFunction<_SlotGetChannelsC, _SlotGetChannelsDart>(
        '${prefix}_plugin_slot_get_channels');
    _loadPreset = dylib.lookupFunction<_SlotPresetC, _SlotPresetDart>(
        '${prefix}_plugin_slot_load_preset');
    _setChannelsG = _lookupSetChannelsG(
        '${prefix}_plugin_slot_set_channels_g');
    _syncAll = _lookupSyncAll('${prefix}_plugin_slot_sync_all');
  }

  // 老桥 DLL 没有 _g 导出时返回 null（ArgumentError），调用方自动回落。
  // 不能写泛型 helper：lookupFunction 的类型参数须为具体 dart:ffi 签名，
  // 泛型占位通不过静态检查，故三处各写具名绑定。
  _SlotShowEditorGDart? _lookupShowEditorG(String name) {
    try {
      return dylib.lookupFunction<_SlotShowEditorGC, _SlotShowEditorGDart>(name);
    } on ArgumentError {
      return null;
    }
  }

  _SlotCloseEditorGDart? _lookupCloseEditorG(String name) {
    try {
      return dylib.lookupFunction<_SlotCloseEditorGC, _SlotCloseEditorGDart>(name);
    } on ArgumentError {
      return null;
    }
  }

  _SlotIsEditorOpenGDart? _lookupIsEditorOpenG(String name) {
    try {
      return dylib
          .lookupFunction<_SlotIsEditorOpenGC, _SlotIsEditorOpenGDart>(name);
    } on ArgumentError {
      return null;
    }
  }

  _SlotSetChannelsGDart? _lookupSetChannelsG(String name) {
    try {
      return dylib.lookupFunction<_SlotSetChannelsGC, _SlotSetChannelsGDart>(name);
    } on ArgumentError {
      return null;
    }
  }

  _SlotSyncAllDart? _lookupSyncAll(String name) {
    try {
      return dylib.lookupFunction<_SlotSyncAllC, _SlotSyncAllDart>(name);
    } on ArgumentError {
      return null;
    }
  }

  int load(int slot, String path, {String id = ''}) {
    final pp = path.toNativeUtf8();
    final ip = id.toNativeUtf8();
    try {
      return _load(slot, pp.cast(), ip.cast());
    } finally {
      malloc.free(pp);
      malloc.free(ip);
    }
  }

  int unload(int slot) => _unload(slot);

  int setBypass(int slot, bool bypass) => _setBypass(slot, bypass ? 1 : 0);

  bool getBypass(int slot) => _getBypass(slot) == 1;

  int getLatency(int slot) => _getLatency(slot);

  String getStatus(int slot) {
    const cap = 4096;
    final buf = malloc<Uint8>(cap).cast<Utf8>();
    try {
      final n = _getStatus(slot, buf, cap);
      if (n <= 0) return '';
      return buf.toDartString(length: n);
    } finally {
      malloc.free(buf);
    }
  }

  // group >= 0 且桥支持 _g 导出时按路打开（VB 多总线）；否则回落单路
  // （非 VB 模式 / 老桥 DLL），语义与旧版一致。
  int showEditor(int slot, {int group = -1, String title = ''}) {
    final tp = title.toNativeUtf8();
    try {
      if (group >= 0) {
        final f = _showEditorG;
        if (f != null) return f(slot, group, tp.cast());
      }
      return _showEditor(slot, tp.cast());
    } finally {
      malloc.free(tp);
    }
  }

  int closeEditor(int slot, {int group = -1}) {
    if (group >= 0) {
      final f = _closeEditorG;
      if (f != null) return f(slot, group);
    }
    return _closeEditor(slot);
  }

  bool isEditorOpen(int slot, {int group = -1}) {
    if (group >= 0) {
      final f = _isEditorOpenG;
      if (f != null) return f(slot, group) == 1;
    }
    return _isEditorOpen(slot) == 1;
  }

  int setInsertStage(int slot, int stage) => _setStage(slot, stage);

  int getInsertStage(int slot) => _getStage(slot);

  int setChannels(int slot, int mask) {
    try {
      return _setChannels(slot, mask);
    } catch (_) {
      return 0;
    }
  }

  /// P1-3 per-group Ch 下发（group 越界/老桥无导出返回 0）。
  int setChannelsG(int slot, int group, int mask) {
    final f = _setChannelsG;
    if (f == null || group < 0) return 0;
    try {
      return f(slot, group, mask);
    } catch (_) {
      return 0;
    }
  }

  /// P1-5 继承复制：srcGroup state → [path] → 其余组（老桥无导出返回 0）。
  int syncAll(int slot, int srcGroup, String path) {
    final f = _syncAll;
    if (f == null) return 0;
    final pp = path.toNativeUtf8();
    try {
      return f(slot, srcGroup, pp.cast());
    } finally {
      malloc.free(pp);
    }
  }

  /// P1-5「不继承」：全组扇出载入「全部」记忆文件。
  int loadPreset(int slot, String path) {
    final pp = path.toNativeUtf8();
    try {
      return _loadPreset(slot, pp.cast());
    } finally {
      malloc.free(pp);
    }
  }

  int getChannels(int slot) {
    try {
      return _getChannels(slot);
    } catch (_) {
      return 0xFF;
    }
  }
}
