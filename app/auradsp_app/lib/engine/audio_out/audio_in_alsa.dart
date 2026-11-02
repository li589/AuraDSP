// audio_in_alsa.dart —— Linux ALSA 直连采集（专家模式，A2）。
//
// 与 PulseAudioIn 同构的鸭子口：open/read/close + device/sampleRate，
// 供 audio_isolate_linux 的采集 Source 适配层 interchangeable 使用。
//
// 语义：
//   - 阻塞 readi 读满请求帧数（泵的 fill 契约）；
//   - 溢出（-EPIPE，采集端来不及读）走 prepare 自恢复并计数——
//     溢出意味着已丢一小段输入，恢复后继续读满本块（时间轴有
//     一次小跳变，优于整源失效；与 PulseCaptureSource 的「失败
//     即静音」不同，ALSA 溢出是常态可恢复事件）；
//   - 其余错误抛 StateError，由 Source 适配层置 failed 静音
//     （与 PA 采集同口径）；
//   - 格式按协商结果解释缓冲（float32 直读 / s16 反量化），
//     这是 A0 探针的明确教训（按错格式读会得到垃圾值）。
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../debug_log.dart';
import 'alsa_ffi.dart';

class AlsaAudioIn {
  AlsaLib? _lib;
  Pointer<Void> _pcm = nullptr;
  Pointer<Uint8>? _stage;
  int _stageFrames = 0;
  int _format = alsaFormatFloatLe;
  int _overrunCount = 0;

  String device = '';
  int sampleRate = 0;

  int get overrunCount => _overrunCount;

  int get _bytesPerFrame => _format == alsaFormatFloatLe ? 8 : 4;

  /// 打开对 [device] 的采集（ALSA PCM 名，如 hw:Loopback）。
  void open({required String device, int rate = 48000}) {
    close();
    final lib = _lib ??= AlsaLib.load();
    final neg = alsaOpenNegotiated(
      lib,
      device: resolveAlsaDevice(device),
      stream: alsaStreamCapture,
      requestedRate: rate,
      wantPeriod: 256,
      formatPreference: const [alsaFormatFloatLe, alsaFormatS16Le],
    );
    _pcm = neg.pcm;
    _format = neg.format;
    this.device = device;
    sampleRate = neg.rate;
    final prc = lib.prepare(_pcm);
    if (prc < 0) {
      throw StateError(
          'snd_pcm_prepare($device): ${lib.errorText(prc)}');
    }
    dbgLog('ALSA-IN open: device=$device rate=${neg.rate} '
        'period=${neg.period} buffer=${neg.buffer} '
        'format=${_format == alsaFormatFloatLe ? "float32" : "s16"}');
  }

  /// 阻塞读满 [frames] 帧交织立体声到 [out]（长度至少 frames*2）。
  void read(Float32List out, int frames) {
    final lib = _lib;
    if (lib == null || _pcm == nullptr) {
      throw StateError('AlsaAudioIn.read before open');
    }
    if (frames <= 0) return;
    if (_stage == null || _stageFrames < frames) {
      if (_stage != null) malloc.free(_stage!);
      _stage = malloc<Uint8>(frames * _bytesPerFrame);
      _stageFrames = frames;
    }
    final stage = _stage!;
    var offset = 0;
    while (offset < frames) {
      final r = lib.readi(
          _pcm,
          Pointer<Void>.fromAddress(
              stage.address + offset * _bytesPerFrame),
          frames - offset);
      if (r >= 0) {
        offset += r;
        continue;
      }
      if (r == alsaErrPipe) {
        _overrunCount++;
        if (_overrunCount == 1 || _overrunCount % 100 == 0) {
          dbgLog('ALSA-IN overrun count=$_overrunCount');
        }
        final prc = lib.prepare(_pcm);
        if (prc < 0) {
          throw StateError(
              'snd_pcm_prepare after overrun: ${lib.errorText(prc)}');
        }
        continue;
      }
      throw StateError('snd_pcm_readi failed: ${lib.errorText(r)}');
    }
    if (_format == alsaFormatFloatLe) {
      final f = stage.cast<Float>();
      for (var i = 0; i < frames * 2; i++) {
        out[i] = f[i];
      }
    } else {
      final s = stage.cast<Int16>();
      for (var i = 0; i < frames * 2; i++) {
        out[i] = s[i] / 32768.0;
      }
    }
  }

  void close() {
    if (_pcm != nullptr && _lib != null) {
      try {
        _lib!.close(_pcm);
      } catch (_) {
        // 释放路径尽力而为。
      }
      _pcm = nullptr;
    }
    if (_stage != null) {
      malloc.free(_stage!);
      _stage = null;
      _stageFrames = 0;
    }
    device = '';
    sampleRate = 0;
  }
}
