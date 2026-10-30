import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';

/// 流体丝绸：三层宽幅半透明绸带 + 中央高光
///
/// 设计要点：
/// - 只用 3 条大面积绸带，层间相位错开，形成前后景深而不是满屏平行线；
/// - 绸带厚度向两端收窄并横向淡出，避免左右边界被硬切；
/// - 低频驱动呼吸（厚度/亮度），中频驱动横向摆动，高频只点亮中央细高光；
/// - 每帧仅 3 条填充路径 + 一次合并辉光模糊，无散点粒子。
class FluidSilkPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;
  final double lineWidth;

  static const int _bandCount = 3;
  static const int _samples = 44;

  /// 三条绸带的垂直基准线（画面高度比例）
  static const List<double> _lanes = [0.37, 0.5, 0.63];

  /// 层间相位错开，避免三条带同相位重叠
  static const List<double> _phaseOffsets = [0.0, 2.1, 4.2];

  final Paint _fillPaint = Paint()..style = PaintingStyle.fill;
  final Paint _corePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _glowPaint = Paint()..style = PaintingStyle.fill;
  final Paint _haloPaint = Paint()..style = PaintingStyle.fill;
  final Path _bandPath = Path();
  final Path _corePath = Path();
  final Path _glowPath = Path();

  FluidSilkPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final w = size.width;
    final h = size.height;
    final t = animationTime;
    final n = bands.length;
    if (n == 0) return;

    final bass = _avg(0, math.max(1, n ~/ 8));
    final mid = _avg(n ~/ 4, n ~/ 2);
    final treble = _avg((n * 3) ~/ 4, n);
    final amp = h * (0.03 + 0.10 * mid + 0.05 * bass);

    _drawBackdrop(canvas, size, bass);

    // 第一遍：合并三条填充带，让辉光整体模糊一次
    _glowPath.reset();
    for (var i = 0; i < _bandCount; i++) {
      _buildBand(i, w, h, t, n, bass, amp);
      _glowPath.addPath(_bandPath, Offset.zero);
    }

    if (bloom > 0.05) {
      _glowPaint
        ..shader = null
        ..color = palette.glow.withValues(alpha: 0.10 + bloom * 0.2)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(2.0, bloom * 6.0),
        );
      canvas.drawPath(_glowPath, _glowPaint);
    }

    // 第二遍：逐层绘制绸带本体与中央高光
    for (var i = 0; i < _bandCount; i++) {
      _buildBand(i, w, h, t, n, bass, amp);

      final color = Color.lerp(
        palette.primary,
        palette.secondary,
        i / (_bandCount - 1),
      )!;
      final alpha = 0.13 + 0.10 * bass + (i == 1 ? 0.04 : 0.0);

      _fillPaint.shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          color.withValues(alpha: 0.0),
          color.withValues(alpha: alpha),
          color.withValues(alpha: alpha * 0.82),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.18, 0.8, 1.0],
      ).createShader(Offset.zero & size);
      canvas.drawPath(_bandPath, _fillPaint);

      // 中央细高光：高频只提亮线条，不增加图形数量
      _buildCore(i, w, h, t, amp, n);
      _corePaint
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            color.withValues(alpha: 0.0),
            palette.peak.withValues(alpha: 0.22 + treble * 0.3),
            color.withValues(alpha: 0.5 + bass * 0.2),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.3, 0.72, 1.0],
        ).createShader(Offset.zero & size)
        ..strokeWidth = lineWidth * 1.1 + treble * 0.7;
      canvas.drawPath(_corePath, _corePaint);
    }
  }

  /// 极简背景：中央低频呼吸光晕 + 顶部微弱冷光
  void _drawBackdrop(Canvas canvas, Size size, double bass) {
    final center = Offset(size.width / 2.0, size.height * 0.52);
    final radius = math.max(size.width, size.height) * (0.5 + bass * 0.2);
    _haloPaint.shader = RadialGradient(
      colors: [
        palette.primary.withValues(alpha: 0.06 + bass * 0.12),
        palette.secondary.withValues(alpha: 0.02 + bass * 0.04),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.55, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, _haloPaint);
  }

  /// 构建第 [index] 条绸带的填充轮廓（上缘正向 + 下缘反向）。
  void _buildBand(
    int index,
    double w,
    double h,
    double t,
    int n,
    double bass,
    double amp,
  ) {
    final thickness = h * (0.045 + 0.055 * bass) * (0.85 + index * 0.08);

    _bandPath.reset();
    for (var s = 0; s <= _samples; s++) {
      final u = s / _samples;
      final centerY = _centerY(index, u, t, h, amp, n);
      final half = thickness * _taper(u) * 0.5;
      final x = w * (0.02 + 0.96 * u);
      final y = (centerY - half).clamp(1.0, h - 1.0);

      if (s == 0) {
        _bandPath.moveTo(x, y);
      } else {
        _bandPath.lineTo(x, y);
      }
    }
    for (var s = _samples; s >= 0; s--) {
      final u = s / _samples;
      final centerY = _centerY(index, u, t, h, amp, n);
      final half = thickness * _taper(u) * 0.5;
      final x = w * (0.02 + 0.96 * u);
      final y = (centerY + half).clamp(1.0, h - 1.0);
      _bandPath.lineTo(x, y);
    }
    _bandPath.close();
  }

  /// 构建绸带中央高光曲线
  void _buildCore(int index, double w, double h, double t, double amp, int n) {
    _corePath.reset();
    for (var s = 0; s <= _samples; s++) {
      final u = s / _samples;
      final y = _centerY(index, u, t, h, amp, n).clamp(1.0, h - 1.0);
      final x = w * (0.02 + 0.96 * u);
      if (s == 0) {
        _corePath.moveTo(x, y);
      } else {
        _corePath.lineTo(x, y);
      }
    }
  }

  /// 绸带两端收窄系数（0.2 → 1 → 0.2）
  double _taper(double u) =>
      0.2 + 0.8 * math.pow(math.sin(math.pi * u), 0.7).toDouble();

  /// 绸带中心线的垂直位移（轮廓与高光共用，保证贴合）
  double _centerY(int index, double u, double t, double h, double amp, int n) {
    final bandIdx = (u * (n - 1)).round().clamp(0, n - 1);
    final energy = bands[bandIdx];
    final phase = _phaseOffsets[index];
    final envelope = 0.25 + 0.75 * math.sin(math.pi * u);

    return _lanes[index] * h +
        h * 0.012 * math.sin(t * 0.22 + phase) +
        amp * (1.0 + energy * 0.35) *
            (0.65 * math.sin(u * math.pi * 2.0 * 1.05 + t * 0.42 + phase) +
                0.35 *
                    math.sin(
                      u * math.pi * 2.0 * 2.35 - t * 0.3 + phase * 1.6,
                    )) *
            envelope;
  }

  double _avg(int from, int to) {
    if (bands.isEmpty) return 0.0;
    final start = from.clamp(0, bands.length - 1);
    final end = to.clamp(start + 1, bands.length);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += bands[i];
    }
    return sum / (end - start);
  }

  @override
  bool shouldRepaint(covariant FluidSilkPainter oldDelegate) => true;
}
