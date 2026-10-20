// audio_vbridge.dart — VB-Callback 常驻桥 FFI（bridge/vm_bridge/auravm_bridge.dll）。
//
// 与 AuraDspLib.load() 同候选策略：exe 旁 → engine/ 子目录 → 环境变量
// AURADSP_VB_BRIDGE_DLL。刻意不含硬编码开发机路径（产品铁律）。
// 所有调用均在 isolate 线程（控制面），RT 线程只跑 VB 回调本身。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'auradsp_ffi.dart' show VizFrame;
import 'bridge_plugin_ffi.dart';

typedef _DetectC = Int32 Function(Pointer<Utf8>, Int32);
typedef _DetectDart = int Function(Pointer<Utf8>, int);
typedef _StartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _StopC = Int32 Function();
typedef _StopDart = int Function();
typedef _StatusC = Int32 Function(Pointer<Utf8>, Int32);
typedef _StatusDart = int Function(Pointer<Utf8>, int);
typedef _SetParamC = Int32 Function(Pointer<Utf8>, Int32, Pointer<Void>);
typedef _SetParamDart = int Function(Pointer<Utf8>, int, Pointer<Void>);
typedef _VizReadC = Int32 Function(Pointer<Void>, Int32);
typedef _VizReadDart = int Function(Pointer<Void>, int);
typedef _TestStartC = Int32 Function(Int32, Pointer<Float>, Int32, Int32, Int32);
typedef _TestStartDart = int Function(int, Pointer<Float>, int, int, int);
typedef _TestStopC = Int32 Function();
typedef _TestStopDart = int Function();
typedef _BypassC = Int32 Function(Int32);
typedef _BypassDart = int Function(int);
typedef _BusMaskC = Int32 Function(Int32);
typedef _BusMaskDart = int Function(int);
typedef _SetParamStrC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetParamStrDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _GetParamC = Int32 Function(Pointer<Utf8>, Int32, Pointer<Void>);
typedef _GetParamDart = int Function(Pointer<Utf8>, int, Pointer<Void>);
typedef _GetParamStrC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _GetParamStrDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);

class AuraVmBridge {
  final DynamicLibrary dylib;
  late final BridgePluginFfi plugin = BridgePluginFfi(dylib, 'vb');
  late final _StatusDart _detect =
      dylib.lookupFunction<_DetectC, _DetectDart>('vb_detect');
  late final _StartDart _start =
      dylib.lookupFunction<_StartC, _StartDart>('vb_start');
  late final _StopDart _stop =
      dylib.lookupFunction<_StopC, _StopDart>('vb_stop');
  late final _StatusDart _status =
      dylib.lookupFunction<_StatusC, _StatusDart>('vb_status');
  late final _SetParamDart _setParam =
      dylib.lookupFunction<_SetParamC, _SetParamDart>('vb_set_param');
  late final _VizReadDart _vizRead =
      dylib.lookupFunction<_VizReadC, _VizReadDart>('vb_viz_read');
  late final _TestStartDart _testStart =
      dylib.lookupFunction<_TestStartC, _TestStartDart>('vb_test_start');
  late final _TestStopDart _testStop =
      dylib.lookupFunction<_TestStopC, _TestStopDart>('vb_test_stop');
  late final _BypassDart _bypass =
      dylib.lookupFunction<_BypassC, _BypassDart>('vb_bypass');
  late final _BusMaskDart _busMask =
      dylib.lookupFunction<_BusMaskC, _BusMaskDart>('vb_set_bus_mask');
  late final _SetParamStrDart _setParamStr =
      dylib.lookupFunction<_SetParamStrC, _SetParamStrDart>('vb_set_param_str');
  late final _GetParamDart _getParam =
      dylib.lookupFunction<_GetParamC, _GetParamDart>('vb_get_param');
  late final _GetParamStrDart _getParamStr = dylib.lookupFunction<
      _GetParamStrC, _GetParamStrDart>('vb_get_param_str');

  AuraVmBridge._(this.dylib);

  static AuraVmBridge? _cached;

  static AuraVmBridge load() {
    if (_cached != null) return _cached!;
    final candidates = <String>[
      'auravm_bridge.dll',
      'engine\\auravm_bridge.dll',
    ];
    final envPath = Platform.environment['AURADSP_VB_BRIDGE_DLL'];
    if (envPath != null && envPath.isNotEmpty) candidates.add(envPath);
    Object? lastErr;
    for (final path in candidates) {
      try {
        _cached = AuraVmBridge._(DynamicLibrary.open(path));
        return _cached!;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError(
        'auravm_bridge.dll not found (tried: ${candidates.join(", ")}) — $lastErr');
  }

  Map<String, dynamic>? detect() {
    final buf = malloc<Uint8>(2048).cast<Utf8>();
    try {
      final n = _detect(buf, 2048);
      if (n <= 0) return null;
      return jsonDecode(buf.toDartString(length: n)) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  /// 启动常驻泵。engineDll 传引擎真相源绝对路径（AppModel 经 loadedPath 给）。
  int start(String engineDll, String params) {
    final ep = engineDll.toNativeUtf8();
    final pp = params.toNativeUtf8();
    try {
      return _start(ep.cast(), pp.cast());
    } finally {
      malloc.free(ep);
      malloc.free(pp);
    }
  }

  int stop() => _stop();

  Map<String, dynamic>? status() {
    final buf = malloc<Uint8>(2048).cast<Utf8>();
    try {
      final n = _status(buf, 2048);
      if (n <= 0) return null;
      return jsonDecode(buf.toDartString(length: n)) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  int setParam(String id, {required bool isFloat, required double value}) {
    final idp = id.toNativeUtf8();
    try {
      if (isFloat) {
        final vp = malloc<Float>();
        try {
          vp.value = value;
          return _setParam(idp.cast(), 1, vp.cast());
        } finally {
          malloc.free(vp);
        }
      } else {
        final vp = malloc<Int32>();
        try {
          vp.value = value.toInt();
          return _setParam(idp.cast(), 0, vp.cast());
        } finally {
          malloc.free(vp);
        }
      }
    } finally {
      malloc.free(idp);
    }
  }

  /// 从 group0 读可视化帧，返回与 isolate viz 事件同形 map（调用方节流）。
  Map<String, dynamic>? vizRead() {
    final buf = malloc<VizFrame>(4);
    try {
      final n = _vizRead(buf.cast(), 4);
      if (n <= 0) return null;
      final fr = (buf + (n - 1)).ref;
      return {
        'spectrum': fr.spectrumToList(),
        'eqIn': fr.eqInSpectrumToList(),
        'l': fr.levelLDbfs,
        'r': fr.levelRDbfs,
        'stageL': fr.stageLevelsLToList(),
        'stageR': fr.stageLevelsRToList(),
        'inputInL': fr.inputLevelInL,
        'inputInR': fr.inputLevelInR,
        'inputOutL': fr.inputLevelOutL,
        'inputOutR': fr.inputLevelOutR,
        'ts': fr.timestampMs,
        'seq': fr.seq,
      };
    } catch (_) {
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  /// 测试注入：kind 1=正弦440 2=粉噪 3=文件（pcm 交织立体声 float32）。
  /// bridge 内拷贝，返回后调用方可释放。
  int testStart(int kind,
      {Pointer<Float>? pcm, int frames = 0, int ch = 2, int rate = 0}) {
    final p = pcm ?? nullptr;
    return _testStart(kind, p, frames, ch, rate);
  }

  int testStop() => _testStop();

  int setBypass(bool on) => _bypass(on ? 1 : 0);

  /// 总线掩码：返回生效值，<0=失败。
  int setBusMask(int mask) => _busMask(mask & 0xFF);

  /// 字符串参数（liveprog.code / arbmag.string）：返回成功 handle 数，
  /// <0=失败。桥内记镜像，CHANGE 重建后自动回放。
  int setParamStr(String id, String text) {
    final idp = id.toNativeUtf8();
    final tp = text.toNativeUtf8();
    try {
      return _setParamStr(idp.cast(), tp.cast(), tp.length);
    } finally {
      malloc.free(idp);
      malloc.free(tp);
    }
  }

  /// int 参数回读（group0），失败返回 null。
  int? getIntParam(String id) {
    final idp = id.toNativeUtf8();
    final vp = malloc<Int32>();
    try {
      final rc = _getParam(idp.cast(), 0, vp.cast());
      return rc == 0 ? vp.value : null;
    } catch (_) {
      return null;
    } finally {
      malloc.free(idp);
      malloc.free(vp);
    }
  }

  /// 字符串参数回读（group0），失败返回 null。
  String? getParamStr(String id) {
    final idp = id.toNativeUtf8();
    final buf = malloc<Uint8>(256 * 1024 + 1).cast<Utf8>();
    try {
      final n = _getParamStr(idp.cast(), buf, 256 * 1024 + 1);
      if (n <= 0) return null;
      return buf.toDartString(length: n);
    } catch (_) {
      return null;
    } finally {
      malloc.free(idp);
      malloc.free(buf);
    }
  }
}
