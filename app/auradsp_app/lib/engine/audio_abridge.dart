// audio_abridge.dart — ASIO 常驻桥 FFI（bridge/asio_bridge/auraasio_bridge.dll）。
//
// 加载策略与 VM 桥一致：exe 旁 → engine/ 子目录 → 环境变量
// AURADSP_ASIO_BRIDGE_DLL。控制面调用均在 isolate 线程；RT 由驱动回调驱动。
//
// P1 收敛：公共导出委托 AudioBridgeCore；本文件只保留 ASIO 专属面
// （asio_start_ex / 驱动清单 detect 形状）。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'bridge_manager.dart';
import 'bridge_plugin_ffi.dart';

typedef _StartExC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32);
typedef _StartExDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, int, int);

class AuraAsioBridge implements AudioBridgeCommon {
  final AudioBridgeCore core;

  AuraAsioBridge._(DynamicLibrary dylib)
      : core = AudioBridgeCore(dylib, 'asio', logTag: 'ab-ffi');

  DynamicLibrary get dylib => core.dylib;

  @override
  BridgePluginFfi get plugin => core.plugin;

  late final _StartExDart _startEx =
      dylib.lookupFunction<_StartExC, _StartExDart>('asio_start_ex');

  static AuraAsioBridge? _cached;

  static AuraAsioBridge load() {
    if (_cached != null) return _cached!;
    final candidates = <String>[
      'auraasio_bridge.dll',
      'engine\\auraasio_bridge.dll',
    ];
    final envPath = Platform.environment['AURADSP_ASIO_BRIDGE_DLL'];
    if (envPath != null && envPath.isNotEmpty) candidates.add(envPath);
    Object? lastErr;
    for (final path in candidates) {
      try {
        _cached = AuraAsioBridge._(DynamicLibrary.open(path));
      } catch (e) {
        lastErr = e;
        continue;
      }
      // §7-2（P-028）：桥 ABI 协商（老桥无导出→跳过；不符→抛错）
      BridgePluginFfi.assertBridgeAbi(_cached!.dylib, 'asio', path);
      return _cached!;
    }
    throw StateError(
        'auraasio_bridge.dll not found (tried: ${candidates.join(", ")}) — $lastErr');
  }

  /// 驱动清单（UTF-8 显示名列表；桥内持有 SDK load 键映射）。
  /// 返回 null = 桥加载失败/枚举失败；空 list = 注册表无 ASIO 驱动。
  List<Map<String, dynamic>>? detect() {
    final raw = core.detectJson(4096);
    final drivers = raw?['drivers'] as List?;
    if (drivers == null) return null;
    return [for (final d in drivers) Map<String, dynamic>.from(d as Map)];
  }

  /// 启动常驻桥。[driver] 为 detect 的 name（UTF-8 显示名）；[engineDll]
  /// 传引擎真相源绝对路径（空串=桥内自动搜索）；[paramsJson] 同 bridge 格式
  /// "id=f1.5;id2=i3"；[bufSize]<=0 用驱动 preferredSize；[outPair] 为
  /// 输出块起始声道，<0 按 0；[channels] ∈ {2,4,6,8} 为 io 声道数（B2c，桥按
  /// 驱动能力自动降级并把引擎 channels.count 对齐到此值）。
  int start(String driver,
      {String engineDll = '',
      String paramsJson = '',
      int bufSize = 0,
      int outPair = 0,
      int channels = 2}) {
    // P5：新桥走统一契约 ab_start（驱动名/缓冲档/输出声道对经 config_json 归一）。
    final ab = core.startUnified(
        engineDll,
        paramsJson,
        jsonEncode({
          'driver': driver,
          'bufSize': bufSize,
          'outPair': outPair,
          'channels': channels,
        }));
    if (ab != null) return ab;
    final dp = driver.toNativeUtf8();
    final ep = engineDll.toNativeUtf8();
    final pp = paramsJson.toNativeUtf8();
    try {
      return _startEx(dp.cast(), ep.cast(), pp.cast(), bufSize, outPair, channels);
    } finally {
      malloc.free(dp);
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

  @override
  int setParamStr(String id, String text) => core.setParamStr(id, text);

  @override
  int? getIntParam(String id) => core.getIntParam(id);

  @override
  String? getParamStr(String id) => core.getParamStr(id);
}
