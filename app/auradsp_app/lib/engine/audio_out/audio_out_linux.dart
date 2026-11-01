// audio_out_linux.dart —— Linux PulseAudio 设备输出（simple API / FFI 直绑）。
//
// 方案：ADR-012 D-6 —— 一期用 PulseAudio simple API（pa_simple_*），不引入
// 异步 mainloop API；D-5 虚拟模式下输出端即真实设备 sink，捕获端
// （null-sink monitor）随 S5 接入，本文件只负责播放半边。
//
// 与 WASAPI 实现的契约对齐（audio_out.dart 端口）：
//   - init 协商采样率：PulseAudio 服务端按流采样率重采样到设备率，
//     sampleRate 报流采样率（requested ?? 48000），声道固定 2；
//   - currentPadding 以 pa_simple_get_latency 估算在途帧数（偏保守，
//     泵循环据此少写不会溢出）；
//   - write 阻塞至数据被服务端接收 —— 即泵的节流点（与 WASAPI 轮询推
//     模型等价：padding 估算保守时不会长阻塞）；
//   - 失败一律抛 StateError（pa_strerror 文案），由 audio_isolate 的
//     降级通道兜底（引擎照跑、无声不红屏），与 WASAPI 的 _hr 风格一致；
//   - stop 用 pa_simple_flush 丢弃在途音频（真的静音），失败保持
//     started=true 并抛错（同 WASAPI D4-a 口径，防双路出声）。
//
// FFI 说明：libpulse-simple 只在 init 时打开（构造零副作用），符号按
// pulse/simple.h 原型手写；pa_strerror 在 libpulse 中，单独打开。
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../debug_log.dart';
import 'audio_out.dart';

/* ---------------- PulseAudio simple API 绑定 ---------------- */

const _paStreamPlayback = 1; // PA_STREAM_PLAYBACK
const _paSampleFloat32Le = 5; // PA_SAMPLE_FLOAT32LE
const _paUsecPerSec = 1000000;

final class _PaSampleSpec extends Struct {
  @Int32()
  external int format;
  @Uint32()
  external int rate;
  @Uint8()
  external int channels;
}

final class _PaBufferAttr extends Struct {
  @Uint32()
  external int maxlength;
  @Uint32()
  external int tlength;
  @Uint32()
  external int prebuf;
  @Uint32()
  external int minreq;
  @Uint32()
  external int fragsize;
}

typedef _PaSimpleNewNative = Pointer<Void> Function(
    Pointer<Utf8>, // server (NULL = default)
    Pointer<Utf8>, // name (application name)
    Int32, // dir
    Pointer<Utf8>, // dev (NULL = default sink)
    Pointer<Utf8>, // stream_name
    Pointer<_PaSampleSpec>,
    Pointer<Void>, // channel map (NULL)
    Pointer<_PaBufferAttr>,
    Pointer<Int32>); // error
typedef _PaSimpleWriteNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Size, Pointer<Int32>);
typedef _PaSimpleSimpleNative = Int32 Function(Pointer<Void>, Pointer<Int32>);
typedef _PaSimpleFreeNative = Void Function(Pointer<Void>);
typedef _PaSimpleGetLatencyNative = Uint64 Function(
    Pointer<Void>, Pointer<Int32>);
typedef _PaStrerrorNative = Pointer<Utf8> Function(Int32);

class _PulseLib {
  _PulseLib._(this._simple, this._pulse);

  final DynamicLibrary _simple;
  final DynamicLibrary _pulse;

  late final _new = _simple.lookupFunction<_PaSimpleNewNative,
      Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>,
          Pointer<Utf8>, Pointer<_PaSampleSpec>, Pointer<Void>,
          Pointer<_PaBufferAttr>, Pointer<Int32>)>('pa_simple_new');
  late final _write = _simple.lookupFunction<_PaSimpleWriteNative,
      int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Int32>)>(
      'pa_simple_write');
  late final _drain =
      _simple.lookupFunction<_PaSimpleSimpleNative, int Function(Pointer<Void>, Pointer<Int32>)>(
          'pa_simple_drain');
  late final _flush =
      _simple.lookupFunction<_PaSimpleSimpleNative, int Function(Pointer<Void>, Pointer<Int32>)>(
          'pa_simple_flush');
  late final _free =
      _simple.lookupFunction<_PaSimpleFreeNative, void Function(Pointer<Void>)>(
          'pa_simple_free');
  late final _getLatency = _simple.lookupFunction<_PaSimpleGetLatencyNative,
      int Function(Pointer<Void>, Pointer<Int32>)>('pa_simple_get_latency');
  late final _strerror =
      _pulse.lookupFunction<_PaStrerrorNative, Pointer<Utf8> Function(int)>(
          'pa_strerror');

  static _PulseLib load() {
    DynamicLibrary openFirst(List<String> names) {
      Object? last;
      for (final n in names) {
        try {
          return DynamicLibrary.open(n);
        } catch (e) {
          last = e;
        }
      }
      throw StateError('PulseAudio library not found (${names.join(", ")}): $last');
    }

    return _PulseLib._(
      openFirst(const ['libpulse-simple.so.0', 'libpulse-simple.so']),
      openFirst(const ['libpulse.so.0', 'libpulse.so']),
    );
  }

  String errorText(int code) {
    try {
      return _strerror(code).toDartString();
    } catch (_) {
      return 'pa error $code';
    }
  }
}

/* ---------------- 实现 ---------------- */

class PulseAudioOut implements AudioOut {
  /// 目标缓冲帧数（tlength）：2048 帧 @48k ≈ 43ms。与 WASAPI 的 20ms
  /// 相比偏大，是 simple API 阻塞写模型的稳妥值；低延迟调优留 S5。
  static const int targetBufferFrames = 2048;

  _PulseLib? _lib;
  Pointer<Void> _stream = nullptr;
  Pointer<Float>? _stage;
  int _stageFrames = 0;

  @override
  bool started = false;

  int _sampleRate = 0;
  @override
  int get sampleRate => _sampleRate;

  @override
  int get channels => 2;

  int _bufferFrames = 0;
  @override
  int get bufferFrames => _bufferFrames;

  @override
  void init({int? requestedSampleRate}) {
    if (_stream != nullptr) return; // 重复 init 幂等（同 WASAPI 字段复用）
    final lib = _lib ??= _PulseLib.load();
    final rate = (requestedSampleRate != null && requestedSampleRate > 0)
        ? requestedSampleRate
        : 48000;
    dbgLog('PULSE init: begin rate=$rate');
    final spec = malloc<_PaSampleSpec>();
    spec.ref.format = _paSampleFloat32Le;
    spec.ref.rate = rate;
    spec.ref.channels = 2;
    final attr = malloc<_PaBufferAttr>();
    attr.ref.maxlength = 0xFFFFFFFF; // -1：服务端默认
    attr.ref.tlength = targetBufferFrames * 2 * 4; // frames * ch * sizeof(f32)
    attr.ref.prebuf = 0xFFFFFFFF;
    attr.ref.minreq = 0xFFFFFFFF;
    attr.ref.fragsize = 0xFFFFFFFF;
    final name = 'AuraDSP'.toNativeUtf8();
    final streamName = 'Audio Effects'.toNativeUtf8();
    final pErr = malloc<Int32>();
    try {
      final s = lib._new(nullptr, name, _paStreamPlayback, nullptr,
          streamName, spec, nullptr, attr, pErr);
      if (s == nullptr) {
        throw StateError(
            'pa_simple_new failed: ${lib.errorText(pErr.value)}');
      }
      _stream = s;
    } finally {
      malloc.free(spec);
      malloc.free(attr);
      malloc.free(name);
      malloc.free(streamName);
      malloc.free(pErr);
    }
    _sampleRate = rate;
    _bufferFrames = targetBufferFrames;
    dbgLog('PULSE init: stream open rate=$rate bufferFrames=$_bufferFrames');
  }

  @override
  int currentPadding() {
    final lib = _lib;
    if (lib == null || _stream == nullptr || _sampleRate <= 0) return 0;
    final pErr = malloc<Int32>();
    try {
      final usec = lib._getLatency(_stream, pErr);
      if (pErr.value < 0) return 0;
      final frames = (usec * _sampleRate) ~/ _paUsecPerSec;
      // 在途量上界钳制到 2 倍缓冲，避免异常延迟值让泵误判写满。
      return frames > _bufferFrames * 2 ? _bufferFrames * 2 : frames;
    } finally {
      malloc.free(pErr);
    }
  }

  @override
  void write(Float32List src, {required int frames, int srcCh = 2}) {
    final lib = _lib;
    if (lib == null || _stream == nullptr) {
      throw StateError('PulseAudioOut.write before init');
    }
    if (frames <= 0) return;
    if (_stage == null || _stageFrames < frames) {
      if (_stage != null) malloc.free(_stage!);
      _stage = malloc<Float>(frames * 2);
      _stageFrames = frames;
    }
    final stage = _stage!;
    if (srcCh == 2) {
      for (var i = 0; i < frames * 2; i++) {
        stage[i] = src[i];
      }
    } else if (srcCh == 1) {
      for (var i = 0; i < frames; i++) {
        stage[i * 2] = src[i];
        stage[i * 2 + 1] = src[i];
      }
    } else {
      // 多声道只取前两声道（与引擎立体声主链口径一致；多声道设备泵
      // 在 Windows 走桥链路，Linux 多声道留 S5 专项）。
      for (var i = 0; i < frames; i++) {
        stage[i * 2] = src[i * srcCh];
        stage[i * 2 + 1] = src[i * srcCh + 1];
      }
    }
    final pErr = malloc<Int32>();
    try {
      final rc = lib._write(_stream, stage.cast(), frames * 2 * 4, pErr);
      if (rc < 0) {
        throw StateError(
            'pa_simple_write failed: ${lib.errorText(pErr.value)}');
      }
    } finally {
      malloc.free(pErr);
    }
  }

  @override
  void start() {
    if (_stream == nullptr) {
      throw StateError('PulseAudioOut.start before init');
    }
    // simple API 无 start/stop 语义：流在 new 时即运行，start 只置位。
    started = true;
    dbgLog('PULSE start');
  }

  @override
  void stop() {
    if (!started) return;
    final lib = _lib!;
    final pErr = malloc<Int32>();
    try {
      // flush 丢弃已排队未播数据 —— stop 必须真的静音（D4-a 口径）。
      final rc = lib._flush(_stream, pErr);
      if (rc < 0) {
        throw StateError(
            'pa_simple_flush failed: ${lib.errorText(pErr.value)}');
      }
    } finally {
      malloc.free(pErr);
    }
    started = false;
    dbgLog('PULSE stop (flushed)');
  }

  /// 释放流与暂存缓冲（端口之外附加；isolate 退出时可选调用）。
  void dispose() {
    if (_stream != nullptr && _lib != null) {
      try {
        final pErr = malloc<Int32>();
        _lib!._drain(_stream, pErr);
        malloc.free(pErr);
      } catch (_) {
        // 释放路径尽力而为，异常不外抛。
      }
      _lib!._free(_stream);
      _stream = nullptr;
    }
    if (_stage != null) {
      malloc.free(_stage!);
      _stage = null;
      _stageFrames = 0;
    }
    started = false;
  }
}
