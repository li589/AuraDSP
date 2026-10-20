// audio_abridge.dart — ASIO-Client 常驻桥 FFI（bridge/asio_bridge/auraasio_bridge.dll）。
// Client 线：打开第三方 ASIO 驱动。未来的 Driver 线（自身作为驱动）另起炉灶，
// 不共用本绑定。
//
// 与 AuraVmBridge 同候选策略：exe 旁 → engine/ 子目录 → 环境变量
// AURADSP_ASIO_BRIDGE_DLL。刻意不含硬编码开发机路径（产品铁律）。
// 所有调用均在 isolate 线程（控制面），RT 线程只跑驱动 bufferSwitch 本身。
//
// 与 VB 桥的两处契约差异（见 AsioBridge.h）：
//   1. start 多两个宿主参数 buf_size / out_pair（C long = Win64 下 32 位，
//      FFI 侧用 Int32——ctypes.c_long 同口径）；
//   2. detect 输出驱动清单（{"count":N,"drivers":[{name,dll,clsid}]}），
//      name 为 UTF-8 显示名，start 原样传回即可（桥内做注册表名映射）。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'auradsp_ffi.dart' show VizFrame;
import 'bridge_plugin_ffi.dart';

typedef _DetectC = Int32 Function(Pointer<Utf8>, Int32);
typedef _DetectDart = int Function(Pointer<Utf8>, int);
typedef _StartExC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32);
typedef _StartExDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, int, int);
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

class AuraAsioBridge {
  final DynamicLibrary dylib;
  late final BridgePluginFfi plugin = BridgePluginFfi(dylib, 'asio');
  late final _DetectDart _detect =
      dylib.lookupFunction<_DetectC, _DetectDart>('asio_detect');
  late final _StartExDart _startEx =
      dylib.lookupFunction<_StartExC, _StartExDart>('asio_start_ex');
  late final _StopDart _stop =
      dylib.lookupFunction<_StopC, _StopDart>('asio_stop');
  late final _StatusDart _status =
      dylib.lookupFunction<_StatusC, _StatusDart>('asio_status');
  late final _SetParamDart _setParam =
      dylib.lookupFunction<_SetParamC, _SetParamDart>('asio_set_param');
  late final _VizReadDart _vizRead =
      dylib.lookupFunction<_VizReadC, _VizReadDart>('asio_viz_read');
  late final _TestStartDart _testStart =
      dylib.lookupFunction<_TestStartC, _TestStartDart>('asio_test_start');
  late final _TestStopDart _testStop =
      dylib.lookupFunction<_TestStopC, _TestStopDart>('asio_test_stop');
  late final _BypassDart _bypass =
      dylib.lookupFunction<_BypassC, _BypassDart>('asio_bypass');
  late final _SetParamStrDart _setParamStr = dylib.lookupFunction<
      _SetParamStrC, _SetParamStrDart>('asio_set_param_str');
  late final _GetParamDart _getParam =
      dylib.lookupFunction<_GetParamC, _GetParamDart>('asio_get_param');
  late final _GetParamStrDart _getParamStr = dylib.lookupFunction<
      _GetParamStrC, _GetParamStrDart>('asio_get_param_str');

  AuraAsioBridge._(this.dylib);

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
        return _cached!;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError(
        'auraasio_bridge.dll not found (tried: ${candidates.join(", ")}) — $lastErr');
  }

  /// 驱动清单（UTF-8 显示名列表；桥内持有 SDK load 键映射）。
  /// 返回 null = 桥加载失败/枚举失败；空 list = 注册表无 ASIO 驱动。
  List<Map<String, dynamic>>? detect() {
    final buf = malloc<Uint8>(4096).cast<Utf8>();
    try {
      final n = _detect(buf, 4096);
      if (n <= 0) return null;
      final raw = jsonDecode(buf.toDartString(length: n)) as Map<String, dynamic>?;
      final drivers = raw?['drivers'] as List?;
      if (drivers == null) return null;
      return [for (final d in drivers) Map<String, dynamic>.from(d as Map)];
    } catch (_) {
      return null;
    } finally {
      malloc.free(buf);
    }
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

  /// 读可视化帧，返回与 isolate viz 事件同形 map（调用方节流）。
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

  /// 字符串参数（liveprog.code / arbmag.string）：返回 0=ok，<0=失败。
  /// ASIO 重建一律走 Dart 侧 stop+start（isolate 回放 paramStrMirror）。
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

  /// int 参数回读，失败返回 null。
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

  /// 字符串参数回读，失败返回 null。
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
