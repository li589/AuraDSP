// audio_vbridge.dart — VB-Callback 常驻桥 FFI（bridge/vm_bridge/auravm_bridge.dll）。
//
// 与 AuraDspLib.load() 同候选策略：exe 旁 → engine/ 子目录 → 环境变量
// AURADSP_VB_BRIDGE_DLL。刻意不含硬编码开发机路径（产品铁律）。
// 所有调用均在 isolate 线程（控制面），RT 线程只跑 VB 回调本身。
//
// P1 收敛：公共导出（stop/status/set_param/viz_read/test_*/bypass/参数回读）
// 全部委托 AudioBridgeCore；本文件只保留 VB 专属面（start/总线掩码/插件掩码）。
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import '../platform/platform_profile.dart';
import 'bridge_manager.dart';
import 'bridge_plugin_ffi.dart';

typedef _StartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _BusMaskC = Int32 Function(Int32);
typedef _BusMaskDart = int Function(int);
typedef _PluginGroupEnableC = Int32 Function(Int32);
typedef _PluginGroupEnableDart = int Function(int);
typedef _AutoProtectC = Int32 Function(Int32);
typedef _AutoProtectDart = int Function(int);

class AuraVmBridge implements AudioBridgeCommon {
  final AudioBridgeCore core;

  AuraVmBridge._(DynamicLibrary dylib)
      : core = AudioBridgeCore(dylib, 'vb', logTag: 'vb-ffi');

  DynamicLibrary get dylib => core.dylib;

  @override
  BridgePluginFfi get plugin => core.plugin;

  late final _StartDart _start =
      dylib.lookupFunction<_StartC, _StartDart>('vb_start');
  late final _BusMaskDart _busMask =
      dylib.lookupFunction<_BusMaskC, _BusMaskDart>('vb_set_bus_mask');
  late final _PluginGroupEnableDart _pluginGroupEnable =
      dylib.lookupFunction<_PluginGroupEnableC, _PluginGroupEnableDart>(
          'vb_plugin_group_enable');
  // Z12（2026-10-23）：超预算自动保护开关。旧桥 DLL 无此导出——调用方
  // 必须 try/catch（isolate 侧已按 "old bridge dll?" 口径兜底）。
  late final _AutoProtectDart _autoProtect =
      dylib.lookupFunction<_AutoProtectC, _AutoProtectDart>(
          'vb_plugin_auto_protect');

  static AuraVmBridge? _cached;

  static AuraVmBridge load() {
    if (_cached != null) return _cached!;
    final candidates =
        List<String>.of(PlatformProfile.bridgeLibraryCandidates('vm'));
    final envPath = Platform.environment[PlatformProfile.bridgeEnvVar('vm')];
    if (envPath != null && envPath.isNotEmpty) candidates.add(envPath);
    Object? lastErr;
    for (final path in candidates) {
      try {
        _cached = AuraVmBridge._(DynamicLibrary.open(path));
      } catch (e) {
        lastErr = e;
        continue;
      }
      // §7-2（P-028）：桥 ABI 协商（老桥无导出→跳过；不符→抛错）
      BridgePluginFfi.assertBridgeAbi(_cached!.dylib, 'vb', path);
      return _cached!;
    }
    throw StateError(
        '${candidates.isEmpty ? 'auravm_bridge' : candidates.first} not found '
        '(tried: ${candidates.join(", ")}) — $lastErr');
  }

  Map<String, dynamic>? detect() => core.detectJson(2048);

  /// 启动常驻泵。engineDll 传引擎真相源绝对路径（AppModel 经 loadedPath 给）。
  int start(String engineDll, String params) {
    // P5：新桥走统一契约 ab_start（VM 无宿主参数，config 传空对象）。
    final ab = core.startUnified(engineDll, params, '{}');
    if (ab != null) return ab;
    final ep = engineDll.toNativeUtf8();
    final pp = params.toNativeUtf8();
    try {
      return _start(ep.cast(), pp.cast());
    } finally {
      malloc.free(ep);
      malloc.free(pp);
    }
  }

  @override
  int stop() => core.stop();

  @override
  Map<String, dynamic>? status() => core.statusJson(2048);

  @override
  int setParam(String id, {required bool isFloat, required double value}) =>
      core.setParam(id, isFloat: isFloat, value: value);

  @override
  Map<String, dynamic>? vizRead() => core.vizRead();

  @override
  int testStart(int kind,
          {Pointer<Float>? pcm, int frames = 0, int ch = 2, int rate = 0}) =>
      core.testStart(kind, pcm: pcm, frames: frames, ch: ch, rate: rate);

  @override
  int testStop() => core.testStop();

  @override
  int setBypass(bool on) => core.setBypass(on);

  /// 总线掩码：返回生效值，<0=失败。
  int setBusMask(int mask) => _busMask(mask & 0xFF);

  /// 按路插件处理掩码（bit g = 组 g 总线吃插件链）：返回生效值，0=桥未运行。
  int pluginGroupEnable(int mask) => _pluginGroupEnable(mask & 0xFF);

  /// Z12 超预算自动保护开关：on<0 查询，其余置位；返回生效值。
  /// 关闭时桥侧立即恢复用户掩码（若保护已激活）。
  int pluginAutoProtect(int on) => _autoProtect(on);

  @override
  int setParamStr(String id, String text) => core.setParamStr(id, text);

  @override
  int? getIntParam(String id) => core.getIntParam(id);

  @override
  String? getParamStr(String id) => core.getParamStr(id);
}
