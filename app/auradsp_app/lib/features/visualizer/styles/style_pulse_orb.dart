import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 反应式音频光环与星云粒子渲染画笔
class PulseOrbPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;

  final Paint _ringPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _corePaint = Paint()..style = PaintingStyle.fill;
  final Paint _particlePaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  PulseOrbPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
  }) {
    _ringPaint.strokeWidth = 2.0;
    _corePaint.color = palette.secondary.withValues(alpha: 0.85);
    _particlePaint.color = palette.primary;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final center = Offset(size.width / 2.0, size.height / 2.0);
    final minDim = math.min(size.width, size.height);
    final baseRadius = minDim * 0.22;

    // 提取频段能量
    var bass = 0.0, mid = 0.0, treble = 0.0;
    if (bands.length >= 16) {
      bass = (bands[0] + bands[1] + bands[2] + bands[3]) / 4.0;
      mid = (bands[8] + bands[10] + bands[12]) / 3.0;
      treble = (bands[20] + bands[24] + bands[28]) / 3.0;
    }

    // 核心受低音与中频能量冲击扩张
    final coreR = baseRadius * (0.8 + bass * 0.45 + mid * 0.15);
    canvas.drawCircle(center, coreR, _corePaint);

    // 环绕多边形谐振声波环（根据中高频能量变形）
    const vertexCount = 48;
    final path = Path();
    for (var i = 0; i < vertexCount; i++) {
      final angle = (i / vertexCount) * 2 * math.pi;
      final bandIndex = (i % bands.length);
      final energy = bands.isNotEmpty ? bands[bandIndex] : 0.0;

      final r = baseRadius * (1.15 + energy * 0.55 + math.sin(angle * 6 + animationTime * 2) * 0.06);
      final x = center.dx + math.cos(angle) * r;
      final y = center.dy + math.sin(angle) * r;

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    _ringPaint.color = palette.primary;
    canvas.drawPath(path, _ringPaint);

    // 辉光扩散
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.45).clamp(0.0, 0.75))
        ..strokeWidth = 3.5 + bloom * 4.0
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom * 6.0);
      canvas.drawPath(path, _glowPaint);
    }

    // 外部发散粒子轨道
    const particleCount = 36;
    for (var i = 0; i < particleCount; i++) {
      final pAngle = (i / particleCount) * 2 * math.pi + animationTime * (0.3 + (i % 3) * 0.1);
      final dist = baseRadius * (1.6 + math.sin(i * 1.7) * 0.35 + treble * 0.5);
      final px = center.dx + math.cos(pAngle) * dist;
      final py = center.dy + math.sin(pAngle) * dist;
      final pr = (1.5 + (i % 4) * 0.8 + treble * 2.0).clamp(1.0, 5.0);

      _particlePaint.color = (i % 2 == 0 ? palette.primary : palette.secondary).withValues(alpha: 0.75);
      canvas.drawCircle(Offset(px, py), pr, _particlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant PulseOrbPainter oldDelegate) => true;
}
