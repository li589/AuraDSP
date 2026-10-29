// audio_vaio_bridge.dart — AuraVAIO 常驻桥 FFI（bridge/vaio_bridge/auravaio_bridge.dll）。
//
// 加载策略与 VM/ASIO 桥一致：exe 旁 → engine/ 子目录 → 环境变量
// AURADSP_VAIO_BRIDGE_DLL。控制面调用均在 isolate 线程；RT 由 WASAPI 回调驱动。
//
// P1 收敛：公共导出委托 AudioBridgeCore；本文件只保留 VAIO 专属面
// （vaio_start 的输出设备子串参数）。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'bridge_manager.dart';
import 'bridge_plugin_ffi.dart';

typedef _StartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

class AuraVaioBridge implements AudioBridgeCommon {
  final AudioBridgeCore core;

  AuraVaioBridge._(DynamicLibrary dylib)
      : core = AudioBridgeCore(dylib, 'vaio', logTag: 'vaio-ffi');

  DynamicLibrary get dylib => core.dylib;

  @override
  BridgePluginFfi get plugin => core.plugin;

  late final _StartDart _start =
      dylib.lookupFunction<_StartC, _StartDart>('vaio_start');

  static AuraVaioBridge? _cached;

  static AuraVaioBridge load() {
    if (_cached != null) return _cached!;
    final candidates = <String>[
      'auravaio_bridge.dll',
      'engine\\auravaio_bridge.dll',
    ];
    final envPath = Platform.environment['AURADSP_VAIO_BRIDGE_DLL'];
    if (envPath != null && envPath.isNotEmpty) candidates.add(envPath);
    Object? lastErr;
    for (final path in candidates) {
      try {
        _cached = AuraVaioBridge._(DynamicLibrary.open(path));
      } catch (e) {
        lastErr = e;
        continue;
      }
      // §7-2（P-028）：桥 ABI 协商（老桥无导出→跳过；不符→抛错）
      BridgePluginFfi.assertBridgeAbi(_cached!.dylib, 'vaio', path);
      return _cached!;
    }
    throw StateError(
        'auravaio_bridge.dll not found (tried: ${candidates.join(", ")}) — $lastErr');
  }

  /// 检测驱动存在性并获取物理端点列表。
  Map<String, dynamic>? detect() => core.detectJson(8192);

  /// 启动常驻泵。engineDll 传引擎绝对路径；outputEndpointSubstr 为目标物理输出设备子串。
  int start(String engineDll, String params, {String outputEndpointSubstr = ''}) {
    // P5：新桥走统一契约 ab_start（端点子串经 config_json 归一）。
    final ab = core.startUnified(
        engineDll, params, jsonEncode({'endpoint': outputEndpointSubstr}));
    if (ab != null) return ab;
    final ep = engineDll.toNativeUtf8();
    final pp = params.toNativeUtf8();
    final op = outputEndpointSubstr.toNativeUtf8();
    try {
      return _start(ep.cast(), pp.cast(), op.cast());
    } finally {
      malloc.free(ep);
      malloc.free(pp);
      malloc.free(op);
    }
  }

  @override
  int stop() => core.stop();

  @override
  Map<String, dynamic>? status() => core.statusJson(4096);

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

  @override
  int setParamStr(String id, String text) => core.setParamStr(id, text);

  @override
  int? getIntParam(String id) => core.getIntParam(id);

  @override
  String? getParamStr(String id) => core.getParamStr(id);
}
