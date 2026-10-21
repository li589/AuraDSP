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
typedef _SlotPresetC = Int32 Function(Int32, Pointer<Utf8>);
typedef _SlotPresetDart = int Function(int, Pointer<Utf8>);
typedef _SlotSetStageC = Int32 Function(Int32, Int32);
typedef _SlotSetStageDart = int Function(int, int);
typedef _SlotGetStageC = Int32 Function(Int32);
typedef _SlotGetStageDart = int Function(int);
typedef _SlotSetChannelsC = Int32 Function(Int32, Int32);
typedef _SlotSetChannelsDart = int Function(int, int);
typedef _SlotGetChannelsC = Int32 Function(Int32);
typedef _SlotGetChannelsDart = int Function(int);

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
  late final _SlotPresetDart _savePreset;
  late final _SlotPresetDart _loadPreset;
  late final _SlotSetStageDart _setStage;
  late final _SlotGetStageDart _getStage;
  late final _SlotSetChannelsDart _setChannels;
  late final _SlotGetChannelsDart _getChannels;

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
    _savePreset = dylib.lookupFunction<_SlotPresetC, _SlotPresetDart>(
        '${prefix}_plugin_slot_save_preset');
    _loadPreset = dylib.lookupFunction<_SlotPresetC, _SlotPresetDart>(
        '${prefix}_plugin_slot_load_preset');
    _setStage = dylib.lookupFunction<_SlotSetStageC, _SlotSetStageDart>(
        '${prefix}_plugin_slot_set_insert_stage');
    _getStage = dylib.lookupFunction<_SlotGetStageC, _SlotGetStageDart>(
        '${prefix}_plugin_slot_get_insert_stage');
    _setChannels = dylib.lookupFunction<_SlotSetChannelsC, _SlotSetChannelsDart>(
        '${prefix}_plugin_slot_set_channels');
    _getChannels = dylib.lookupFunction<_SlotGetChannelsC, _SlotGetChannelsDart>(
        '${prefix}_plugin_slot_get_channels');
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

  int showEditor(int slot, {String title = ''}) {
    final tp = title.toNativeUtf8();
    try {
      return _showEditor(slot, tp.cast());
    } finally {
      malloc.free(tp);
    }
  }

  int closeEditor(int slot) => _closeEditor(slot);

  bool isEditorOpen(int slot) => _isEditorOpen(slot) == 1;

  int savePreset(int slot, String path) {
    final pp = path.toNativeUtf8();
    try {
      return _savePreset(slot, pp.cast());
    } finally {
      malloc.free(pp);
    }
  }

  int loadPreset(int slot, String path) {
    final pp = path.toNativeUtf8();
    try {
      return _loadPreset(slot, pp.cast());
    } finally {
      malloc.free(pp);
    }
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

  int getChannels(int slot) {
    try {
      return _getChannels(slot);
    } catch (_) {
      return 0xFF;
    }
  }
}
