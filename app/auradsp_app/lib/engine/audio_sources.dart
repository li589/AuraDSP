// part of audio_isolate.dart —— P1 按区拆分，纯搬运零改行。
part of 'audio_isolate.dart';
/* ---------------- 信号源 ---------------- */

abstract class Source {
  /// 填充 frames×2 交织帧
  void fill(Float32List out, int frames, int deviceRate);
}

/// 支持向多声道引擎提供原始 Nch 数据的源契约
abstract interface class RawMultichannelSource {
  int get rawCh;
  bool get hasRaw;
  void fillRaw(Float32List out, int frames, int deviceRate);
}

/// 通用波形发生源（第四十四轮 S4，取代原固定 440Hz 正弦
/// 源）：正弦/方波/三角，频率可热改（相位连续、无爆音跳
/// 变），可选对数扫频（20→20000 Hz、20 秒循环，频响测试
/// 用）。字段可变——isolate 的 sourceparam 命令直接改本
/// 对象，播放中调频/换波形不重启。
class WaveSource implements Source {
  String shape; // 'sine' | 'square' | 'triangle'
  double freq;
  bool sweep;
  double _phase = 0;
  double _sweepT = 0; // 扫频周期内秒数

  static const double sweepSeconds = 20;
  static const double sweepLo = 20;
  static const double sweepHi = 20000;

  WaveSource({this.shape = 'sine', this.freq = 440, this.sweep = false});

  /// 当前瞬时频率（扫频时按对数律随周期推进）。
  double get instFreq => sweep
      ? sweepLo * math.pow(sweepHi / sweepLo, _sweepT / sweepSeconds)
      : freq;

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    for (var i = 0; i < frames; i++) {
      final d = 2 * math.pi * instFreq / deviceRate;
      _phase += d;
      if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
      if (sweep) {
        _sweepT += 1 / deviceRate;
        if (_sweepT >= sweepSeconds) _sweepT -= sweepSeconds;
      }
      final ph = _phase / (2 * math.pi); // 0..1
      final double v;
      switch (shape) {
        case 'square':
          v = ph < 0.5 ? 0.3 : -0.3;
        case 'triangle':
          v = (ph < 0.5 ? (4 * ph - 1) : (3 - 4 * ph)) * 0.3;
        default:
          v = math.sin(_phase) * 0.3;
      }
      out[i * 2] = v;
      out[i * 2 + 1] = v;
    }
  }
}

class PinkSource implements Source {
  double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
  final math.Random _rng = math.Random();

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    for (var i = 0; i < frames; i++) {
      final w = _rng.nextDouble() * 2 - 1;
      b0 = 0.99886 * b0 + w * 0.0555179;
      b1 = 0.99332 * b1 + w * 0.0750759;
      b2 = 0.96900 * b2 + w * 0.1538520;
      b3 = 0.86650 * b3 + w * 0.3104856;
      b4 = 0.55000 * b4 + w * 0.5329522;
      b5 = -0.7616 * b5 - w * 0.0168980;
      final v = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.05;
      b6 = w * 0.115926;
      out[i * 2] = v;
      out[i * 2 + 1] = v;
    }
  }
}

class FileSource implements Source, RawMultichannelSource {
  final Float32List data; // stereo（fold 版：引擎/viz/桥统一入口）
  final int srcRate;

  /// 多声道 raw（直通用，Nch 交织；无则 null）与声道数。
  final Float32List? raw;
  @override
  final int rawCh;
  double _pos = 0;
  double _posRaw = 0;
  bool loop = true;
  FileSource(this.data, this.srcRate, {this.raw, this.rawCh = 2});

  @override
  bool get hasRaw => raw != null && rawCh > 2;

  /// 源文件声道数（fold 后恒 2 compass；直通判断用 fileCh）。
  int fileCh = 2;

  /// 播放传输面（第四十四轮 S4）：总帧数（fold 立体声口径）、
  /// 当前位置比、按比定位（fold 与 raw 双游标同比例推进）。
  int get totalFrames => data.length ~/ 2;

  double get positionRatio {
    final t = totalFrames;
    if (t <= 0) return 0;
    return (_pos / t).clamp(0.0, 1.0).toDouble();
  }

  void seekRatio(double r) {
    final t = totalFrames;
    if (t <= 0) return;
    final c = r.clamp(0.0, 1.0).toDouble();
    _pos = c * (t - 1);
    final rt = raw == null ? 0 : raw!.length ~/ rawCh;
    if (rt > 0) _posRaw = c * (rt - 1);
  }

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    final ratio = srcRate / deviceRate;
    final total = data.length ~/ 2;
    for (var i = 0; i < frames; i++) {
      if (_pos >= total - 1) {
        if (!loop) {
          for (var k = i; k < frames; k++) {
            out[k * 2] = 0;
            out[k * 2 + 1] = 0;
          }
          return;
        }
        _pos = 0;
      }
      final i0 = _pos.floor();
      final frac = _pos - i0;
      final i1 = math.min(i0 + 1, total - 1);
      out[i * 2] = data[i0 * 2] * (1 - frac) + data[i1 * 2] * frac;
      out[i * 2 + 1] = data[i0 * 2 + 1] * (1 - frac) + data[i1 * 2 + 1] * frac;
      _pos += ratio;
    }
  }

  /// 直通填充：raw Nch 交织 + 同式线性重采样（与 fill 独立游标；切换模式
  /// 不追求采样级连续，追求不断尾不崩溃）。
  @override
  void fillRaw(Float32List out, int frames, int deviceRate) {
    final r = raw;
    if (r == null || rawCh < 3) {
      for (var i = 0; i < frames * 2 && i < out.length; i++) {
        out[i] = 0;
      }
      return;
    }
    final ratio = srcRate / deviceRate;
    final total = r.length ~/ rawCh;
    for (var i = 0; i < frames; i++) {
      if (_posRaw >= total - 1) {
        if (!loop) {
          for (var k = i; k < frames; k++) {
            for (var c = 0; c < rawCh; c++) {
              out[k * rawCh + c] = 0;
            }
          }
          return;
        }
        _posRaw = 0;
      }
      final i0 = _posRaw.floor();
      final frac = _posRaw - i0;
      final i1 = math.min(i0 + 1, total - 1);
      for (var c = 0; c < rawCh; c++) {
        out[i * rawCh + c] =
            r[i0 * rawCh + c] * (1 - frac) + r[i1 * rawCh + c] * frac;
      }
      _posRaw += ratio;
    }
  }
}
