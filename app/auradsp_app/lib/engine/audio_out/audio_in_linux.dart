// audio_in_linux.dart —— Linux PulseAudio 设备采集（simple API / FFI 直绑）。
//
// audio_out_linux.dart 的录音半边（ADR-012 D-5/D-6）：virtual 模式采集
// null-sink 的 monitor 源、driver 模式采集 snd-aloop 的 PA 源，统一以
// pa_simple 的 PA_STREAM_RECORD 流实现——不 fork 外部命令、不用异步 API。
//
// 契约：
//   - 打开即按设备名绑定源（monitor 源名 = "<sink>.monitor"）；
//   - read 阻塞至采满请求帧数（fragsize 钳制单次等待，泵由采集驱动）；
//   - 失败抛 StateError（pa_strerror 文案），由上层 PulseCaptureSource
//     吞掉转静音并标记失效（采集断了不该掀翻整个泵，与输出侧降级同口径）；
//   - 采样率/声道与输出侧同口径：FLOAT32LE / 2 声道 / 流率协商。
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../debug_log.dart';
import '../native_library_loader.dart';
import 'pulse_simple_ffi.dart';

class PulseAudioIn {
  /// 采集分片帧数：512 帧 @48k ≈ 10.7ms，钳制 read 的单次阻塞时长。
  static const int fragmentFrames = 512;

  DynamicLibrary? _simple;
  DynamicLibrary? _pulse;
  late final _new = _simple!
      .lookupFunction<PaSimpleNewNative, PaSimpleNewDart>('pa_simple_new');
  late final _read = _simple!
      .lookupFunction<PaSimpleReadNative, PaSimpleIoDart>('pa_simple_read');
  late final _free = _simple!
      .lookupFunction<PaSimpleFreeNative, void Function(Pointer<Void>)>(
          'pa_simple_free');
  late final _strerror =
      _pulse!.lookupFunction<PaStrerrorNative, Pointer<Utf8> Function(int)>(
          'pa_strerror');

  Pointer<Void> _stream = nullptr;
  Pointer<Float>? _stage;
  int _stageFrames = 0;

  String device = '';
  int sampleRate = 0;

  bool get isOpen => _stream != nullptr;

  void _loadLibs() {
    if (_simple != null) return;
    _simple = NativeLibraryLoader.openFirst(
        const ['libpulse-simple.so.0', 'libpulse-simple.so'],
        what: 'PulseAudio library');
    _pulse = NativeLibraryLoader.openFirst(
        const ['libpulse.so.0', 'libpulse.so'],
        what: 'PulseAudio library');
  }

  String _errorText(int code) {
    try {
      return _strerror(code).toDartString();
    } catch (_) {
      return 'pa error $code';
    }
  }

  /// 打开对 [device] 源的采集流（device 为 PA 源名，如
  /// `auradsp_virtual.monitor` 或 snd-aloop 的 alsa_input 源名）。
  void open({required String device, int rate = 48000}) {
    close();
    _loadLibs();
    final spec = malloc<PaSampleSpec>();
    spec.ref.format = paSampleFloat32Le;
    spec.ref.rate = rate;
    spec.ref.channels = 2;
    final attr = malloc<PaBufferAttr>();
    attr.ref.maxlength = 0xFFFFFFFF;
    attr.ref.tlength = 0xFFFFFFFF;
    attr.ref.prebuf = 0xFFFFFFFF;
    attr.ref.minreq = 0xFFFFFFFF;
    attr.ref.fragsize = fragmentFrames * 2 * 4;
    final name = 'AuraDSP'.toNativeUtf8();
    final streamName = 'Effects Capture'.toNativeUtf8();
    final dev = device.toNativeUtf8();
    final pErr = malloc<Int32>();
    try {
      final s = _new(nullptr, name, paStreamRecord, dev, streamName, spec,
          nullptr, attr, pErr);
      if (s == nullptr) {
        throw StateError(
            'pa_simple_new(record $device) failed: ${_errorText(pErr.value)}');
      }
      _stream = s;
    } finally {
      malloc.free(spec);
      malloc.free(attr);
      malloc.free(name);
      malloc.free(streamName);
      malloc.free(dev);
      malloc.free(pErr);
    }
    this.device = device;
    sampleRate = rate;
    dbgLog('PULSE-IN open: device=$device rate=$rate');
  }

  /// 阻塞读满 [frames] 帧交织立体声到 [out]（长度至少 frames*2）。
  void read(Float32List out, int frames) {
    if (_stream == nullptr) throw StateError('PulseAudioIn.read before open');
    if (frames <= 0) return;
    if (_stage == null || _stageFrames < frames) {
      if (_stage != null) malloc.free(_stage!);
      _stage = malloc<Float>(frames * 2);
      _stageFrames = frames;
    }
    final stage = _stage!;
    final pErr = malloc<Int32>();
    try {
      final rc = _read(_stream, stage.cast(), frames * 2 * 4, pErr);
      if (rc < 0) {
        throw StateError('pa_simple_read failed: ${_errorText(pErr.value)}');
      }
    } finally {
      malloc.free(pErr);
    }
    for (var i = 0; i < frames * 2; i++) {
      out[i] = stage[i];
    }
  }

  void close() {
    if (_stream != nullptr) {
      try {
        _free(_stream);
      } catch (_) {
        // 释放路径尽力而为。
      }
      _stream = nullptr;
    }
    if (_stage != null) {
      malloc.free(_stage!);
      _stage = null;
      _stageFrames = 0;
    }
    device = '';
  }
}
