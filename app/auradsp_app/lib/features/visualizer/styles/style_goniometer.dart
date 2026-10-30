import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 利萨如相位与立体声度极坐标仪 (Goniometer) 渲染画笔
class GoniometerPainter extends CustomPainter {
  final List<Offset> points;
  final VisualizerPalette palette;
  final bool showGrid;
  final double bloom;
  final double lineWidth;

  final Paint _gridPaint = Paint()..strokeWidth = 1;
  final Paint _axisPaint = Paint()..strokeWidth = 1;
  final Paint _tracePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _dotPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  GoniometerPainter({
    required this.points,
    required this.palette,
    required this.showGrid,
    required this.bloom,
    this.lineWidth = 1.5,
  }) {
    _gridPaint.color = palette.grid;
    _axisPaint.color = palette.grid.withValues(alpha: 0.4);

    _tracePaint
      ..color = palette.primary.withValues(alpha: 0.85)
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    _dotPaint.color = palette.secondary.withValues(alpha: 0.9);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final center = Offset(size.width / 2.0, size.height / 2.0);
    final radius = math.min(size.width, size.height) * 0.44;

    if (showGrid) {
      _drawPolarGrid(canvas, center, radius);
    }

    if (points.isEmpty) return;

    final path = Path();
    final screenPoints = <Offset>[
      for (final p in points)
        Offset(center.dx + p.dx * radius, center.dy + p.dy * radius),
    ];

    path.moveTo(screenPoints[0].dx, screenPoints[0].dy);
    for (var i = 1; i < screenPoints.length; i++) {
      final p0 = screenPoints[i - 1];
      final p1 = screenPoints[i];
      final midX = (p0.dx + p1.dx) / 2.0;
      final midY = (p0.dy + p1.dy) / 2.0;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);

      if (i % 8 == 0 && (points[i].dx.abs() > 0.1 || points[i].dy.abs() > 0.1)) {
        canvas.drawCircle(p1, math.max(1.5, lineWidth * 1.2), _dotPaint);
      }
    }

    // 荧光余辉
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.4).clamp(0.0, 0.7))
        ..strokeWidth = lineWidth * 2.0 + bloom * 3.5
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom * 4.0);
      canvas.drawPath(path, _glowPaint);
    }

    canvas.drawPath(path, _tracePaint);
  }

  void _drawPolarGrid(Canvas canvas, Offset center, double radius) {
    // 绘制 3 层同心圆
    canvas.drawCircle(center, radius * 0.33, _gridPaint);
    canvas.drawCircle(center, radius * 0.66, _gridPaint);
    canvas.drawCircle(center, radius, _gridPaint);

    // 绘制 45° 立体声交叉坐标轴 (L / R / M / S)
    canvas.drawLine(
      Offset(center.dx - radius * 0.707, center.dy - radius * 0.707),
      Offset(center.dx + radius * 0.707, center.dy + radius * 0.707),
      _axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx - radius * 0.707, center.dy + radius * 0.707),
      Offset(center.dx + radius * 0.707, center.dy - radius * 0.707),
      _axisPaint,
    );
  }

  @override
  bool shouldRepaint(covariant GoniometerPainter oldDelegate) => true;
}
