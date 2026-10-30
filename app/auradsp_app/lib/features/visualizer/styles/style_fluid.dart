import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';

/// 流体丝绸：低频驱动的流场丝带
///
/// 性能要点：
/// - 每帧只创建一个渐变 shader 与两个 Path（丝带路径复用 reset）；
/// - 辉光只对合并后的路径做一次模糊，避免逐丝带 blur；
/// - 不含任何平台相关 API，Android / iOS / macOS / Windows 通用。
class FluidSilkPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;
  final double lineWidth;

  static const int _ribbonCount = 7;
  static const int _samples = 30;
  static const int _dropletCount = 12;

  final Paint _silkPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _haloPaint = Paint()..style = PaintingStyle.fill;
  final Paint _dropletPaint = Paint()..style = PaintingStyle.fill;
  final Path _ribbonPath = Path();
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

    // 频段能量分解：低频决定呼吸，中频决定摆幅，高频决定细纹
    final bass = _avg(0, 4);
    final mid = _avg(n ~/ 4, n ~/ 2);
    final treble = _avg((n * 3) ~/ 4, n);

    _drawLiquidHalo(canvas, size, bass);

    // 单次渐变着色：左右横向流动的丝绸配色
    _silkPaint.shader = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        palette.primary.withValues(alpha: 0.8),
        palette.secondary.withValues(alpha: 0.92),
        palette.primary.withValues(alpha: 0.8),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(Offset.zero & size);

    // 第一遍：仅构建合并路径，让辉光落在丝带下方
    _glowPath.reset();
    for (var r = 0; r < _ribbonCount; r++) {
      _buildRibbon(r, w, h, t, n, bass);
      _glowPath.addPath(_ribbonPath, Offset.zero);
    }

    if (bloom > 0.05) {
      _glowPaint
        ..shader = null
        ..color = palette.glow.withValues(alpha: 0.16 + bloom * 0.3)
        ..strokeWidth = lineWidth * 2.6 + mid * 2.2
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(1.5, bloom * 5.0),
        );
      canvas.drawPath(_glowPath, _glowPaint);
    }

    // 第二遍：绘制清晰的丝绸主体
    for (var r = 0; r < _ribbonCount; r++) {
      _buildRibbon(r, w, h, t, n, bass);
      _silkPaint.strokeWidth =
          lineWidth * (0.8 + (r % 3) * 0.32) + mid * 1.6;
      canvas.drawPath(_ribbonPath, _silkPaint);
    }

    _drawDroplets(canvas, size, t, treble);
  }

  /// 构建第 [r] 条丝带：纵向分道铺开 + 低频呼吸 + 高频细纹。
  void _buildRibbon(
    int r,
    double w,
    double h,
    double t,
    int n,
    double bass,
  ) {
    final lane = (r - (_ribbonCount - 1) / 2.0) / _ribbonCount;
    final phase = t * (0.4 + r * 0.05) + r * 1.3;

    _ribbonPath.reset();
    for (var s = 0; s <= _samples; s++) {
      final u = s / _samples;
      final edge = math.sin(math.pi * u);
      final bandIdx = (u * (n - 1)).round().clamp(0, n - 1);
      final energy = bands[bandIdx];

      final x = w * (0.02 + 0.96 * u);
      final flow = math.sin(u * 3.4 + phase);
      final fine = math.sin(u * 10.5 - t * 1.5 + r * 2.1);

      // 分道基准线，避免所有丝带在左右两端收束成一团
      final baseY = h *
          (0.5 +
              lane * 0.56 +
              0.035 * math.sin(t * 0.35 + r * 0.9));
      final amplitude = h * (0.045 + 0.15 * energy + 0.05 * bass);

      final y = baseY +
          amplitude * flow +
          amplitude * 0.32 * fine * edge;

      if (s == 0) {
        _ribbonPath.moveTo(x, y.clamp(2.0, h - 2.0));
      } else {
        _ribbonPath.lineTo(x, y.clamp(2.0, h - 2.0));
      }
    }
  }

  void _drawLiquidHalo(Canvas canvas, Size size, double bass) {
    final center = Offset(size.width / 2.0, size.height * 0.56);
    final radius = math.max(size.width, size.height) * (0.55 + bass * 0.3);
    _haloPaint.shader = RadialGradient(
      colors: [
        palette.glow.withValues(alpha: 0.1 + bass * 0.28),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, _haloPaint);
  }

  void _drawDroplets(Canvas canvas, Size size, double t, double treble) {
    final w = size.width;
    final h = size.height;
    for (var i = 0; i < _dropletCount; i++) {
      // 沿丝带方向缓慢漂移的光点
      final u = (i / _dropletCount + t * 0.028) % 1.0;
      final edge = math.sin(math.pi * u);
      final lane = (i % 5 - 2) / 5.0;
      final x = w * (0.02 + 0.96 * u);
      final y = h * (0.5 + lane * 0.62 + 0.035 * math.sin(t * 0.35 + i)) +
          edge *
              h *
              (0.09 + 0.16 * treble) *
              math.sin(u * 3.4 + t * 0.45 + i * 0.9);

      _dropletPaint.color = (i.isEven ? palette.secondary : palette.primary)
          .withValues(alpha: 0.35 + 0.5 * (0.5 + 0.5 * math.sin(t * 2.2 + i)));
      canvas.drawCircle(
        Offset(x, y.clamp(2.0, h - 2.0)),
        1.2 + 1.6 * (0.5 + 0.5 * math.sin(t * 1.7 + i * 1.3)),
        _dropletPaint,
      );
    }
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
