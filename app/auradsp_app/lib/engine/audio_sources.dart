// part of audio_isolate.dart —— P1 按区拆分，纯搬运零改行。
part of 'audio_isolate.dart';
/* ---------------- 信号源 ---------------- */

abstract class Source {
  /// 填充 frames×2 交织帧
  void fill(Float32List out, int frames, int deviceRate);
}

class ToneSource implements Source {
  final double freq;
  double _phase = 0;
  ToneSource(this.freq);

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    final d = 2 * math.pi * freq / deviceRate;
    for (var i = 0; i < frames; i++) {
      final v = math.sin(_phase) * 0.3;
      _phase += d;
      if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
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

class FileSource implements Source {
  final Float32List data;
  final int srcRate;
  double _pos = 0;
  bool loop = true;
  FileSource(this.data, this.srcRate);

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
}
