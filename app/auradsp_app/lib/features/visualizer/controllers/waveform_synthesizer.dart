import 'dart:math' as math;
import 'dart:ui' show Offset;

/// 真实感高刷时域波形与立体声利萨如相位序列合成器
class WaveformSynthesizer {
  static const int pointCount = 128;

  final List<double> waveL = List.filled(pointCount, 0.0);
  final List<double> waveR = List.filled(pointCount, 0.0);
  final List<Offset> lissajousPoints = List.filled(pointCount, Offset.zero);

  double _phase = 0.0;

  /// 根据实时频段与 L/R 电平合成高精平滑波形
  void update(
    List<double> spectrum, {
    required double levelLDbfs,
    required double levelRDbfs,
    double sensitivity = 1.0,
  }) {
    if (spectrum.isEmpty) {
      waveL.fillRange(0, pointCount, 0.0);
      waveR.fillRange(0, pointCount, 0.0);
      lissajousPoints.fillRange(0, pointCount, Offset.zero);
      return;
    }

    _phase = (_phase + 0.08) % (2 * math.pi);

    // 线性幅度与通道不平衡度提取
    final ampL = math.pow(10.0, (levelLDbfs + 3.0) / 20.0).clamp(0.0, 1.5).toDouble();
    final ampR = math.pow(10.0, (levelRDbfs + 3.0) / 20.0).clamp(0.0, 1.5).toDouble();

    // 提取主要泛音谐波权重（低频、中频、高频分段能量）
    final bass = (spectrum[1] + spectrum[2] + spectrum[3]) / 3.0 * sensitivity;
    final mid = (spectrum[10] + spectrum[12] + spectrum[14]) / 3.0 * sensitivity;
    final treble = (spectrum[22] + spectrum[24] + spectrum[26]) / 3.0 * sensitivity;

    // 左右声道微相位差（根据声道差异动态变化）
    final phaseDiff = (ampL - ampR) * 0.75;

    for (var i = 0; i < pointCount; i++) {
      final t = (i / pointCount) * 2 * math.pi;

      // 泛音合成模拟
      final yBase = math.sin(t * 1.0 + _phase) * bass +
          math.sin(t * 3.0 + _phase * 1.4) * (mid * 0.55) +
          math.sin(t * 7.0 + _phase * 2.1) * (treble * 0.28);

      final yL = (yBase * ampL).clamp(-1.0, 1.0);
      final yR = ((yBase + math.sin(t * 2.0 + phaseDiff) * 0.15) * ampR).clamp(-1.0, 1.0);

      waveL[i] = yL;
      waveR[i] = yR;

      // Mid/Side 45° 旋转利萨如映射: M = (L+R)/sqrt(2), S = (L-R)/sqrt(2)
      final m = (yL + yR) * 0.7071;
      final s = (yL - yR) * 0.7071;
      lissajousPoints[i] = Offset(s, -m); // 纵轴为单声道 M，横轴为立体声差 S
    }
  }
}
