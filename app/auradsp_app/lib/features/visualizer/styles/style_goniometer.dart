import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 利萨如相位与立体声度极坐标仪 (Goniometer) 渲染画笔
class GoniometerPainter extends CustomPainter {
  /// 利萨如坐标（x,y 交错，由 WaveformSynthesizer 原地复用）。
  final Float32List points;
  final VisualizerPalette palette;
  final bool showGrid;
  final double bloom;
  final double lineWidth;

  final Paint _gridPaint = Paint()..strokeWidth = 1;
  final Paint _axisPaint = Paint()..strokeWidth = 1;
  final Paint _tracePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _dotPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  /// 李萨如轨迹 Path 跨帧复用；点列直接流式计算，不再分配 `List<Offset>`。
  final Path _path = Path();

  /// 网格线坐标缓冲（3 条同心圆 + 4 条交叉轴的轴线部分，原地覆写）。
  final Float32List _gridLines = Float32List(4 * 4);

  /// 辉光色只取决于 bloom（画笔实例跨帧复用），构造时算好。
  final Color _glowColor;

  GoniometerPainter({
    required this.points,
    required this.palette,
    required this.showGrid,
    required this.bloom,
    this.lineWidth = 1.5,
  }) : _glowColor = palette.glow.withValues(alpha: (bloom * 0.18).clamp(0.0, 0.32)) {
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

    final n = points.length ~/ 2;
    if (n == 0) return;

    final path = _path..reset();
    final sx = center.dx + points[0] * radius;
    final sy = center.dy + points[1] * radius;
    path.moveTo(sx, sy);
    var prevX = sx;
    var prevY = sy;
    for (var i = 1; i < n; i++) {
      final ox = points[i * 2];
      final oy = points[i * 2 + 1];
      final p1x = center.dx + ox * radius;
      final p1y = center.dy + oy * radius;
      final midX = (prevX + p1x) / 2.0;
      final midY = (prevY + p1y) / 2.0;
      path.quadraticBezierTo(prevX, prevY, midX, midY);

      if (i % 8 == 0 && (ox.abs() > 0.1 || oy.abs() > 0.1)) {
        canvas.drawCircle(Offset(p1x, p1y), math.max(1.5, lineWidth * 1.2), _dotPaint);
      }
      prevX = p1x;
      prevY = p1y;
    }

    // 荧光余辉（加宽低透地平描，避免每帧模糊图层）
    if (bloom > 0.1) {
      _glowPaint
        ..color = _glowColor
        ..strokeWidth = lineWidth * 2.0 + bloom * 3.5
        ..maskFilter = null;
      canvas.drawPath(path, _glowPaint);
    }

    canvas.drawPath(path, _tracePaint);
  }

  void _drawPolarGrid(Canvas canvas, Offset center, double radius) {
    // 绘制 3 层同心圆
    canvas.drawCircle(center, radius * 0.33, _gridPaint);
    canvas.drawCircle(center, radius * 0.66, _gridPaint);
    canvas.drawCircle(center, radius, _gridPaint);

    // 绘制 45° 立体声交叉坐标轴 (L / R / M / S)：四条线段一次性批量提交
    final g = _gridLines;
    final dx = radius * 0.707;
    final dy = radius * 0.707;
    g[0] = center.dx - dx;
    g[1] = center.dy - dy;
    g[2] = center.dx + dx;
    g[3] = center.dy + dy;
    g[4] = center.dx - dx;
    g[5] = center.dy + dy;
    g[6] = center.dx + dx;
    g[7] = center.dy - dy;
    canvas.drawRawPoints(PointMode.lines, g, _axisPaint);
  }

  @override
  bool shouldRepaint(covariant GoniometerPainter oldDelegate) => true;
}
