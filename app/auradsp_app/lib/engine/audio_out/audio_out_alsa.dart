// audio_out_alsa.dart —— Linux ALSA 直连设备输出（专家模式）。
//
// 依据：ADR-012 D-6 二期立项（2026-11-02）——ALSA 直连作为低延迟
// 专家模式与 PulseAudio 并存，由设置项 linuxAudioBackend 选择，
// 默认仍为 PulseAudio。本实现直接对 libasound 的 PCM 设备
// （hw:/plughw:/default 等）做阻塞交错读写：
//
//   - period 目标 256 帧（48k ≈ 5.3ms）、buffer 为 4 个 period，
//     相比 PA simple 的 tlength 2048（≈43ms）显著降低输出延迟；
//   - currentPadding 用 snd_pcm_delay（设备真实排队帧数，上限即
//     buffer 大小，不存在 PA 那种设备侧延迟虚高问题，不需钳制
//     ——只做 [0, bufferFrames] 卫生夹取）；
//   - write 循环 writei 直至整块写完；欠载（-EPIPE）走 prepare
//     自恢复并计数（日志节流），其余错误抛 StateError 交 isolate
//     降级通道（与 PA/WASAPI 同口径：无声不红屏）；
//   - stop 用 snd_pcm_drop 立即丢弃排队音频（真的静音，同 PA 的
//     flush 口径）；drop 失败保持 started=true 并抛错（D4-a）。
//
// 已知边界（专家模式语义，设置页有注记）：
//   - 设备在 init 时定死，无热插拔跟随（ALSA 无设备事件）；
//   - PipeWire 系统上 hw: 设备可能被会话管理器占用（open 失败
//     会以 EBUSY 文案明确呈现，不做静默回退——专家模式要的就是
//     确定性，失败原因必须可见）。
import '../../core/error_sink.dart';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../debug_log.dart';
import 'alsa_ffi.dart';
import 'audio_out.dart';

class AlsaAudioOut implements AudioOut {
  AlsaAudioOut({required String device}) : _device = resolveAlsaDevice(device);

  /// 目标 period 帧数：256 @48k ≈ 5.3ms。buffer 取 4 period。
  static const int targetPeriodFrames = 256;

  final String _device;

  AlsaLib? _lib;
  Pointer<Void> _pcm = nullptr;
  int _format = alsaFormatFloatLe;
  Pointer<Uint8>? _stage;
  int _stageFrames = 0;
  int _xrunCount = 0;

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

  int get xrunCount => _xrunCount;
  String get device => _device;

  int get _bytesPerFrame => _format == alsaFormatFloatLe ? 8 : 4;

  @override
  void init({int? requestedSampleRate}) {
    if (_pcm != nullptr) return; // 重复 init 幂等（同 PA/WASAPI）
    final lib = _lib ??= AlsaLib.load();
    final rate = (requestedSampleRate != null && requestedSampleRate > 0)
        ? requestedSampleRate
        : 48000;
    dbgLog('ALSA init: begin device=$_device rate=$rate');
    final neg = alsaOpenNegotiated(
      lib,
      device: _device,
      stream: alsaStreamPlayback,
      requestedRate: rate,
      wantPeriod: targetPeriodFrames,
      formatPreference: const [alsaFormatFloatLe, alsaFormatS16Le],
    );
    _pcm = neg.pcm;
    _format = neg.format;
    _sampleRate = neg.rate;
    _bufferFrames = neg.buffer;
    final prc = lib.prepare(_pcm);
    if (prc < 0) {
      throw StateError(
          'snd_pcm_prepare($_device): ${lib.errorText(prc)}');
    }
    dbgLog('ALSA init: open device=$_device rate=${neg.rate} '
        'period=${neg.period} buffer=${neg.buffer} '
        'format=${_format == alsaFormatFloatLe ? "float32" : "s16"}');
  }

  @override
  int currentPadding() {
    final lib = _lib;
    if (lib == null || _pcm == nullptr) return 0;
    final pDelay = malloc<Int64>();
    try {
      final rc = lib.delay(_pcm, pDelay);
      if (rc < 0) return 0;
      final frames = pDelay.value;
      if (frames < 0) return 0;
      return frames > _bufferFrames ? _bufferFrames : frames;
    } finally {
      malloc.free(pDelay);
    }
  }

  @override
  void write(Float32List src, {required int frames, int srcCh = 2}) {
    final lib = _lib;
    if (lib == null || _pcm == nullptr) {
      throw StateError('AlsaAudioOut.write before init');
    }
    if (frames <= 0) return;
    if (_stage == null || _stageFrames < frames) {
      if (_stage != null) malloc.free(_stage!);
      _stage = malloc<Uint8>(frames * _bytesPerFrame);
      _stageFrames = frames;
    }
    final stage = _stage!;
    // 按协商格式落盘暂存：float32 直拷贝（立体声）/单声道展开；
    // s16 做 [-1,1] 钳位量化。多声道取前两声道（同 PA 口径）。
    if (_format == alsaFormatFloatLe) {
      final f = stage.cast<Float>();
      if (srcCh == 2) {
        for (var i = 0; i < frames * 2; i++) {
          f[i] = src[i];
        }
      } else if (srcCh == 1) {
        for (var i = 0; i < frames; i++) {
          f[i * 2] = src[i];
          f[i * 2 + 1] = src[i];
        }
      } else {
        for (var i = 0; i < frames; i++) {
          f[i * 2] = src[i * srcCh];
          f[i * 2 + 1] = src[i * srcCh + 1];
        }
      }
    } else {
      final s = stage.cast<Int16>();
      double q(double v) =>
          v < -1.0 ? -1.0 : (v > 1.0 ? 1.0 : v);
      void put(int idx, double v) => s[idx] = (q(v) * 32767.0).round();
      if (srcCh == 2) {
        for (var i = 0; i < frames * 2; i++) {
          put(i, src[i]);
        }
      } else if (srcCh == 1) {
        for (var i = 0; i < frames; i++) {
          put(i * 2, src[i]);
          put(i * 2 + 1, src[i]);
        }
      } else {
        for (var i = 0; i < frames; i++) {
          put(i * 2, src[i * srcCh]);
          put(i * 2 + 1, src[i * srcCh + 1]);
        }
      }
    }
    var offset = 0;
    while (offset < frames) {
      // Pointer 算术：按字节地址偏移重建（dart:ffi 无指针偏移
      // 运算符的通用形式）。
      final w = lib.writei(
          _pcm,
          Pointer<Void>.fromAddress(stage.address + offset * _bytesPerFrame),
          frames - offset);
      if (w >= 0) {
        offset += w;
        continue;
      }
      if (w == alsaErrPipe) {
        // 欠载：prepare 后续写本块剩余部分（数据不丢，只补静默缺口
        // 由设备侧承担）。计数 + 节流日志。
        _xrunCount++;
        if (_xrunCount == 1 || _xrunCount % 100 == 0) {
          dbgLog('ALSA xrun (playback) count=$_xrunCount');
        }
        final prc = lib.prepare(_pcm);
        if (prc < 0) {
          throw StateError(
              'snd_pcm_prepare after xrun: ${lib.errorText(prc)}');
        }
        continue;
      }
      throw StateError('snd_pcm_writei failed: ${lib.errorText(w)}');
    }
  }

  @override
  void start() {
    if (_pcm == nullptr) {
      throw StateError('AlsaAudioOut.start before init');
    }
    started = true;
    dbgLog('ALSA start padding=${currentPadding()} buffer=$_bufferFrames');
  }

  @override
  void stop() {
    if (!started) return;
    final lib = _lib!;
    final rc = lib.drop(_pcm);
    if (rc < 0) {
      throw StateError('snd_pcm_drop failed: ${lib.errorText(rc)}');
    }
    started = false;
    dbgLog('ALSA stop (dropped)');
  }

  /// 释放 PCM 与暂存缓冲（isolate 退出时可选调用）。
  void dispose() {
    if (_pcm != nullptr && _lib != null) {
      try {
        _lib!.drop(_pcm);
      } catch (e, st) {
        // swallow: 释放路径尽力而为。
        swallow(e, st);
      }
      _lib!.close(_pcm);
      _pcm = nullptr;
    }
    if (_stage != null) {
      malloc.free(_stage!);
      _stage = null;
      _stageFrames = 0;
    }
    started = false;
  }
}
