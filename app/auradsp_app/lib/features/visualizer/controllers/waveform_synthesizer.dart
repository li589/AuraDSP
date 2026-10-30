import 'dart:math' as math;
import 'dart:ui' show Offset;

/// 真实感高刷时域波形与立体声利萨如相位序列合成器（带双向声学惯性平滑与软饱和防突变）
class WaveformSynthesizer {
  static const int pointCount = 384;

  final List<double> waveL = List.filled(pointCount, 0.0);
  final List<double> waveR = List.filled(pointCount, 0.0);
  final List<Offset> lissajousPoints = List.filled(pointCount, Offset.zero);

  double _phase = 0.0;
  double _smoothedAmpL = 0.0;
  double _smoothedAmpR = 0.0;
  double _smoothedBass = 0.0;
  double _smoothedMid = 0.0;
  double _smoothedTreble = 0.0;

  /// 根据实时频段与 L/R 电平合成高精平滑波形
  void update(
    List<double> spectrum, {
    required double levelLDbfs,
    required double levelRDbfs,
    double sensitivity = 1.0,
  }) {
    if (spectrum.isEmpty) {
      _smoothedAmpL = 0.0;
      _smoothedAmpR = 0.0;
      _smoothedBass = 0.0;
      _smoothedMid = 0.0;
      _smoothedTreble = 0.0;
      waveL.fillRange(0, pointCount, 0.0);
      waveR.fillRange(0, pointCount, 0.0);
      lissajousPoints.fillRange(0, pointCount, Offset.zero);
      return;
    }

    // 1. 幅度动态声学平滑（快冲慢放，消除摇滚乐鼓点/瞬变电平引起的整体波形撕裂突变）
    final targetAmpL = math.pow(10.0, (levelLDbfs + 3.0) / 20.0).clamp(0.0, 1.25).toDouble();
    final targetAmpR = math.pow(10.0, (levelRDbfs + 3.0) / 20.0).clamp(0.0, 1.25).toDouble();

    final alphaL = targetAmpL > _smoothedAmpL ? 0.38 : 0.16;
    final alphaR = targetAmpR > _smoothedAmpR ? 0.38 : 0.16;
    _smoothedAmpL += (targetAmpL - _smoothedAmpL) * alphaL;
    _smoothedAmpR += (targetAmpR - _smoothedAmpR) * alphaR;

    // 2. 泛音能量低通滤波（消除失真吉他与强打击乐瞬态谐波引发的剧烈形状骤变）
    final targetBass = ((_bandAt(spectrum, 1) + _bandAt(spectrum, 2) + _bandAt(spectrum, 3)) / 3.0 * sensitivity).clamp(0.0, 1.2);
    final targetMid = ((_bandAt(spectrum, 10) + _bandAt(spectrum, 12) + _bandAt(spectrum, 14)) / 3.0 * sensitivity).clamp(0.0, 1.2);
    final targetTreble = ((_bandAt(spectrum, 22) + _bandAt(spectrum, 24) + _bandAt(spectrum, 26)) / 3.0 * sensitivity).clamp(0.0, 1.2);

    _smoothedBass += (targetBass - _smoothedBass) * 0.28;
    _smoothedMid += (targetMid - _smoothedMid) * 0.28;
    _smoothedTreble += (targetTreble - _smoothedTreble) * 0.28;

    // 3. 连续平滑相位递增（基频跟随低音能量微调，避免相位突跳）
    _phase = (_phase + 0.06 + _smoothedBass * 0.03) % (2 * math.pi);

    // 左右声道动态微相位差
    final phaseDiff = (_smoothedAmpL - _smoothedAmpR) * 0.6;

    for (var i = 0; i < pointCount; i++) {
      final t = (i / pointCount) * 2 * math.pi;

      // 多谐波连续泛音合成
      final yRaw = math.sin(t * 1.0 + _phase) * _smoothedBass +
          math.sin(t * 3.0 + _phase * 1.3) * (_smoothedMid * 0.5) +
          math.sin(t * 7.0 + _phase * 1.8) * (_smoothedTreble * 0.22);

      // 4. 有机软饱和映射（Soft-Clipping）：杜绝硬截断导致的大面积方波拍平与生硬边缘
      final yL = _softClip(yRaw * _smoothedAmpL * 1.15);
      final yR = _softClip((yRaw + math.sin(t * 2.0 + phaseDiff) * 0.12) * _smoothedAmpR * 1.15);

      waveL[i] = yL;
      waveR[i] = yR;

      // Mid/Side 45° 旋转利萨如映射: M = (L+R)/sqrt(2), S = (L-R)/sqrt(2)
      final m = (yL + yR) * 0.7071;
      final s = (yL - yR) * 0.7071;
      lissajousPoints[i] = Offset(s, -m);
    }
  }

  /// 按需取频段值：频谱段数不足 27 时退化为最后一档，避免每帧绘制路径越界。
  static double _bandAt(List<double> spectrum, int index) {
    final i = index < spectrum.length ? index : spectrum.length - 1;
    return spectrum[i];
  }

  /// 代数软饱和曲线：y = x / sqrt(1 + x^2)
  static double _softClip(double x) {
    return x / math.sqrt(1.0 + x * x);
  }
}
