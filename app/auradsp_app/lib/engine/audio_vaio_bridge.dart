// audio_vaio_bridge.dart — AuraVAIO 虚拟声卡模式持久桥 FFI（bridge/vaio_bridge/auravaio_bridge.dll）。
//
// 契约镜像 audio_vbridge.dart 与 audio_abridge.dart：
// 候选加载路径：exe 旁 → engine/ 子目录 → 环境变量 AURADSP_VAIO_BRIDGE_DLL。
// 控制面调用均在 isolate 线程，RT 线程专职负责环形缓冲到 WASAPI 物理输出的实时音频泵。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'auradsp_ffi.dart' show VizFrame;
import 'bridge_plugin_ffi.dart';

typedef _DetectC = Int32 Function(Pointer<Utf8>, Int32);
typedef _DetectDart = int Function(Pointer<Utf8>, int);
typedef _StartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _StartDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
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
typedef _SetParamStrC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetParamStrDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _GetParamC = Int32 Function(Pointer<Utf8>, Int32, Pointer<Void>);
typedef _GetParamDart = int Function(Pointer<Utf8>, int, Pointer<Void>);
typedef _GetParamStrC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _GetParamStrDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);

class AuraVaioBridge {
  final DynamicLibrary dylib;
  late final BridgePluginFfi plugin = BridgePluginFfi(dylib, 'vaio');
  late final _DetectDart _detect =
      dylib.lookupFunction<_DetectC, _DetectDart>('vaio_detect');
  late final _StartDart _start =
      dylib.lookupFunction<_StartC, _StartDart>('vaio_start');
  late final _StopDart _stop =
      dylib.lookupFunction<_StopC, _StopDart>('vaio_stop');
  late final _StatusDart _status =
      dylib.lookupFunction<_StatusC, _StatusDart>('vaio_status');
  late final _SetParamDart _setParam =
      dylib.lookupFunction<_SetParamC, _SetParamDart>('vaio_set_param');
  late final _VizReadDart _vizRead =
      dylib.lookupFunction<_VizReadC, _VizReadDart>('vaio_viz_read');
  late final _TestStartDart _testStart =
      dylib.lookupFunction<_TestStartC, _TestStartDart>('vaio_test_start');
  late final _TestStopDart _testStop =
      dylib.lookupFunction<_TestStopC, _TestStopDart>('vaio_test_stop');
  late final _BypassDart _bypass =
      dylib.lookupFunction<_BypassC, _BypassDart>('vaio_bypass');
  late final _SetParamStrDart _setParamStr =
      dylib.lookupFunction<_SetParamStrC, _SetParamStrDart>('vaio_set_param_str');
  late final _GetParamDart _getParam =
      dylib.lookupFunction<_GetParamC, _GetParamDart>('vaio_get_param');
  late final _GetParamStrDart _getParamStr =
      dylib.lookupFunction<_GetParamStrC, _GetParamStrDart>('vaio_get_param_str');

  AuraVaioBridge._(this.dylib);

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
        return _cached!;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError(
        'auravaio_bridge.dll not found (tried: ${candidates.join(", ")}) — $lastErr');
  }

  /// 检测驱动存在性并获取物理端点列表。
  Map<String, dynamic>? detect() {
    final buf = malloc<Uint8>(8192).cast<Utf8>();
    try {
      final n = _detect(buf, 8192);
      if (n <= 0) return null;
      return jsonDecode(buf.toDartString(length: n)) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  /// 启动常驻泵。engineDll 传引擎绝对路径；outputEndpointSubstr 为目标物理输出设备子串。
  int start(String engineDll, String params, {String outputEndpointSubstr = ''}) {
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

  int stop() => _stop();

  Map<String, dynamic>? status() {
    final buf = malloc<Uint8>(4096).cast<Utf8>();
    try {
      final n = _status(buf, 4096);
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

  /// 读取可视化帧（与 isolate viz 事件同形 map）。
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
        // [Phase B 多声道电平] per-channel 遥测（与 isolate 主路径同形）
        'chCount': fr.channelCount,
        'chLevels': fr.channelLevelsToList(),
        'stageCh': fr.stageChLevelsTelemetry(),
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
  int testStart(int kind,
      {Pointer<Float>? pcm, int frames = 0, int ch = 2, int rate = 0}) {
    final p = pcm ?? nullptr;
    return _testStart(kind, p, frames, ch, rate);
  }

  int testStop() => _testStop();

  int setBypass(bool on) => _bypass(on ? 1 : 0);

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
