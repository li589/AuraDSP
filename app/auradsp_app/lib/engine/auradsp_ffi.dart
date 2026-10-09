/*
 * auradsp_ffi.dart — AuraDSP engine_api C ABI 的 dart:ffi 绑定
 *
 * 真相源：core/desktop/engine_api/auradsp_engine.h（v1.0，11 个导出符号）
 * 仅在音频 isolate 内使用：auradsp_process 契约要求单音频线程独占 handle。
 * 绑定全部显式 Dart 侧签名（Int32/Uint32→int，Double/Float→double）。
 */
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart' show malloc, Utf8;

/// 参数 ID 常量（engine_api 参数模型 v1 + v1.1 liveprog 增量）
abstract final class ParamId {
  static const bassEnable = 'bass.enable';
  static const bassGain = 'bass.gain';
  static const reverbPreset = 'reverb.preset';
  static const stereoMix = 'stereo.mix';
  static const eqEnable = 'eq.enable';
  static const postGain = 'post.gain';
  static const limiterEnable = 'limiter.enable';
  static const modeLatency = 'mode.latency';
  static const channelsMode = 'channels.mode';
  // v1.1：Liveprog（EEL2 实时可编程 DSP）
  static const lpEnable = 'liveprog.enable';
  static const lpCode = 'liveprog.code';
  static const lpUnload = 'liveprog.unload';
  static const lpStatus = 'liveprog.status';
  static List<String> lpParams() => List.generate(8, (i) => 'liveprog.param${i + 1}');
  // v1.1：卷积 / 脉冲响应（M4）
  static const convEnable = 'convolver.enable';
  static const convIrPath = 'convolver.ir.path';
  static const convClear = 'convolver.clear';
  static const convReady = 'convolver.ready';
  static const convFrames = 'convolver.ir.frames';
  static const convChannels = 'convolver.ir.channels';
  static const convSrcRate = 'convolver.ir.srcRate';
  static const convPeak = 'convolver.ir.peak';
  // M3-a：轻量效果开关
  static const tubeEnable = 'tube.enable';
  static const xfeedEnable = 'crossfeed.enable';
  // M5/P-002：声场分带
  static String stereoBand(int i) => 'stereo.band${i + 1}'; // i: 0..4
  static const stereoBandUsed = 'stereo.bandUsed';
  // M5-b：低频搁架（low-shelf，engine wrapper 自研 biquad）
  static const shelfEnable = 'shelf.enable';
  static const shelfFreq = 'shelf.freq';
  static const shelfGain = 'shelf.gain';
}

/// auradsp_status（engine_api 枚举）
abstract final class Status {
  static const ok = 0;
  static const eParam = -1;
  static const eUnsupported = -2;
  static const eLatencyGuard = -3;
  static const eState = -4;
  static const eIo = -5;
}

/// auradsp_state
abstract final class EngineState {
  static const bypass = 0;
  static const processing = 1;
  static const error = 2;
}

/// auradsp_viz_frame（152 字节：8+8+128+4+4）
final class VizFrame extends Struct {
  @Uint64()
  external int seq;
  @Double()
  external double timestampMs;

  @Array(32)
  external Array<Float> spectrum;

  @Float()
  external double levelLDbfs;
  @Float()
  external double levelRDbfs;

  List<double> spectrumToList() =>
      List<double>.generate(32, (i) => spectrum[i]);
}

/// auradsp_engine.dll 符号绑定（加载成功后不可变）
final class AuraDspLib {
  final DynamicLibrary dylib;

  late final Pointer<Void> Function(double, int) create = dylib
      .lookup<NativeFunction<Pointer<Void> Function(Float, Int32)>>(
          'auradsp_create')
      .asFunction<Pointer<Void> Function(double, int)>();

  late final void Function(Pointer<Void>) destroy = dylib
      .lookup<NativeFunction<Void Function(Pointer<Void>)>>('auradsp_destroy')
      .asFunction();

  late final void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, int)
      process = dylib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>,
                      Int32)>>('auradsp_process')
          .asFunction();

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>, int)
      setParam = dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>,
                      Uint32)>>('auradsp_set_param')
          .asFunction();

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>, int)
      getParam = dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>,
                      Uint32)>>('auradsp_get_param')
          .asFunction();

  late final int Function(Pointer<Void>) getState = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'auradsp_get_state')
      .asFunction();

  late final double Function(Pointer<Void>) getLatencyMs = dylib
      .lookup<NativeFunction<Double Function(Pointer<Void>)>>(
          'auradsp_get_latency_ms')
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Void>) lastError = dylib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Void>)>>(
          'auradsp_last_error')
      .asFunction();

  late final int Function(Pointer<Void>, Pointer<VizFrame>, int) vizRead =
      dylib
          .lookup<
              NativeFunction<
                  Uint32 Function(Pointer<Void>, Pointer<VizFrame>,
                      Uint32)>>('auradsp_viz_read')
          .asFunction();

  late final Pointer<Utf8> Function() version = dylib
      .lookup<NativeFunction<Pointer<Utf8> Function()>>('auradsp_version')
      .asFunction();

  late final int Function() abi = dylib
      .lookup<NativeFunction<Uint32 Function()>>('auradsp_abi')
      .asFunction();

  AuraDspLib._(this.dylib);

  static AuraDspLib? _cached;

  /// 尝试加载引擎 DLL；找不到时抛 [StateError]（路径清单供 UI 提示）。
  static AuraDspLib load() {
    if (_cached != null) return _cached!;
    const candidates = [
      'auradsp_engine.dll', // exe 旁（bundle root）
      'engine\\auradsp_engine.dll', // engine/ 子目录
      r'D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release\auradsp_engine.dll', // 仓库开发路径兜底
    ];
    Object? lastErr;
    for (final path in candidates) {
      try {
        _cached = AuraDspLib._(DynamicLibrary.open(path));
        return _cached!;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError(
        'auradsp_engine.dll not found (tried: ${candidates.join(", ")}) — $lastErr');
  }

  /// 便捷：字符串参数 ID → 原生 buffer
  static Pointer<Uint8> idBytes(String id) {
    final units = utf8.encode(id);
    final p = malloc<Uint8>(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      p[i] = units[i];
    }
    p[units.length] = 0;
    return p;
  }

  /// set_param 包装：int 值按 i32 传，double 值按 f32 传
  static int setValue(AuraDspLib lib, Pointer<Void> handle, String id,
      {required bool isFloat, required double value}) {
    final idp = idBytes(id);
    try {
      if (isFloat) {
        final vp = malloc<Float>()..value = value;
        try {
          return lib.setParam(handle, idp, vp.cast(), 4);
        } finally {
          malloc.free(vp);
        }
      } else {
        final vp = malloc<Int32>()..value = value.toInt();
        try {
          return lib.setParam(handle, idp, vp.cast(), 4);
        } finally {
          malloc.free(vp);
        }
      }
    } finally {
      malloc.free(idp);
    }
  }

  /// set_param 包装：UTF-8 字符串值（bytes = 字节数，不含 NUL）。
  /// 用于 liveprog.code 等字符串参数（engine_api v1.1）。
  static int setString(AuraDspLib lib, Pointer<Void> handle, String id, String text) {
    final idp = idBytes(id);
    final units = utf8.encode(text);
    final vp = malloc<Uint8>(units.length + 1);
    try {
      for (var i = 0; i < units.length; i++) {
        vp[i] = units[i];
      }
      vp[units.length] = 0;
      return lib.setParam(handle, idp, vp.cast(), units.length);
    } finally {
      malloc.free(vp);
      malloc.free(idp);
    }
  }

  /// get_param 包装：i32
  static int getInt(AuraDspLib lib, Pointer<Void> handle, String id) {
    final idp = idBytes(id);
    final vp = malloc<Int32>();
    try {
      final rc = lib.getParam(handle, idp, vp.cast(), 4);
      return rc == 0 ? vp.value : -999999;
    } finally {
      malloc.free(vp);
      malloc.free(idp);
    }
  }
}
