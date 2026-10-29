import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 利萨如相位与立体声度极坐标仪 (Goniometer) 渲染画笔
class GoniometerPainter extends CustomPainter {
  final List<Offset> points;
  final VisualizerPalette palette;
  final bool showGrid;
  final double bloom;

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
  }) {
    _gridPaint.color = palette.grid;
    _axisPaint.color = palette.grid.withValues(alpha: 0.4);

    _tracePaint
      ..color = palette.primary.withValues(alpha: 0.85)
      ..strokeWidth = 1.8
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
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final screenPt = Offset(
        center.dx + p.dx * radius,
        center.dy + p.dy * radius,
      );

      if (i == 0) {
        path.moveTo(screenPt.dx, screenPt.dy);
      } else {
        path.lineTo(screenPt.dx, screenPt.dy);
      }

      // 在高拐点处绘制光斑
      if (i % 6 == 0 && (p.dx.abs() > 0.1 || p.dy.abs() > 0.1)) {
        canvas.drawCircle(screenPt, 2.2, _dotPaint);
      }
    }

    // 荧光余辉
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.4).clamp(0.0, 0.7))
        ..strokeWidth = 3.0 + bloom * 3.5
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

    // 绘制 45° Mid/Side 对角轴线
    final cos45 = radius * 0.7071;
    canvas.drawLine(
      Offset(center.dx - cos45, center.dy - cos45),
      Offset(center.dx + cos45, center.dy + cos45),
      _axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx - cos45, center.dy + cos45),
      Offset(center.dx + cos45, center.dy - cos45),
      _axisPaint,
    );

    // 正交中心轴线
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      _axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      _axisPaint,
    );
  }

  @override
  bool shouldRepaint(covariant GoniometerPainter oldDelegate) => true;
}

