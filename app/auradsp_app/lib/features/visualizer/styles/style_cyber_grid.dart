import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 3D 透视赛博音频网格渲染画笔（高密度平滑地形样条与低频共振）
class CyberGridPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;
  final double lineWidth;

  final Paint _wirePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _horizonPaint = Paint()..strokeWidth = 2.0;
  final Paint _sunPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  CyberGridPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  }) {
    _wirePaint
      ..color = palette.primary.withValues(alpha: 0.8)
      ..strokeWidth = lineWidth * 0.9;
    _horizonPaint
      ..color = palette.secondary
      ..strokeWidth = lineWidth * 1.3;
    _sunPaint.color = palette.secondary.withValues(alpha: 0.25);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final horizonY = size.height * 0.42;

    // 绘制远景发光背景（赛博霓虹日落半圆）
    final sunRadius = math.min(size.width, size.height) * 0.35;
    canvas.drawCircle(Offset(size.width / 2.0, horizonY), sunRadius, _sunPaint);

    // 地平线分隔线
    canvas.drawLine(
      Offset(0, horizonY),
      Offset(size.width, horizonY),
      _horizonPaint,
    );

    // 纵深网格参数：高采样列消除折线感
    const cols = 64;
    const rows = 14;
    final vanishingPoint = Offset(size.width / 2.0, horizonY);

    // 提取低频能量带动地面震荡
    final bassEnergy = bands.length > 5 ? (bands[0] + bands[1] + bands[2]) / 3.0 : 0.0;

    // 绘制横向起伏声波等高线（贝塞尔样条连接，极度顺滑）
    for (var r = 1; r <= rows; r++) {
      final z = math.pow(r / rows, 2.2).toDouble();
      final baseY = horizonY + z * (size.height - horizonY);

      // 计算各列的原始位移
      final rawY = List<double>.filled(cols + 1, 0.0);
      for (var c = 0; c <= cols; c++) {
        final u = c / cols;
        final bandIdx = (u * (bands.length - 1)).round().clamp(0, bands.length - 1);
        final energy = bands.isNotEmpty ? bands[bandIdx] : 0.0;
        final mountainFactor = math.sin(u * math.pi) * 0.45 + (u < 0.2 || u > 0.8 ? 0.95 : 0.25);
        final displacement = energy * mountainFactor * 52.0 * z + (r == rows ? bassEnergy * 8.0 : 0.0);
        rawY[c] = baseY - displacement;
      }

      // 3点邻近空间滤波柔化局部尖刺
      final pts = <Offset>[];
      for (var c = 0; c <= cols; c++) {
        final x = (c / cols) * size.width;
        double y;
        if (c == 0 || c == cols) {
          y = rawY[c];
        } else {
          y = 0.25 * rawY[c - 1] + 0.5 * rawY[c] + 0.25 * rawY[c + 1];
        }
        pts.add(Offset(x, y));
      }

      // 二次贝塞尔光滑曲线连接，彻底根除硬折角
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (var c = 1; c < pts.length; c++) {
        final midX = (pts[c - 1].dx + pts[c].dx) / 2.0;
        final midY = (pts[c - 1].dy + pts[c].dy) / 2.0;
        path.quadraticBezierTo(pts[c - 1].dx, pts[c - 1].dy, midX, midY);
      }
      path.lineTo(pts.last.dx, pts.last.dy);

      final alpha = (z * 0.85 + 0.15).clamp(0.0, 1.0);
      _wirePaint.color = palette.primary.withValues(alpha: alpha);
      canvas.drawPath(path, _wirePaint);
    }

    // 绘制辐射纵向透视网格线
    const perspectiveCols = 24;
    for (var c = 0; c <= perspectiveCols; c += 2) {
      final bottomX = (c / perspectiveCols) * size.width;
      canvas.drawLine(
        vanishingPoint,
        Offset(bottomX, size.height),
        _wirePaint..color = palette.primary.withValues(alpha: 0.35),
      );
    }

    // 辉光：加宽低透地平线替代每帧模糊图层
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.18).clamp(0.0, 0.32))
        ..strokeWidth = lineWidth * 1.8 + bloom * 3.5
        ..maskFilter = null;
      canvas.drawLine(
        Offset(0, horizonY),
        Offset(size.width, horizonY),
        _glowPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CyberGridPainter oldDelegate) => true;
}
