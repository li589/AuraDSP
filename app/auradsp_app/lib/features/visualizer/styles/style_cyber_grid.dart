import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 3D 透视赛博音频网格渲染画笔
class CyberGridPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;

  final Paint _wirePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _horizonPaint = Paint()..strokeWidth = 2.0;
  final Paint _sunPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  CyberGridPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
  }) {
    _wirePaint
      ..color = palette.primary.withValues(alpha: 0.8)
      ..strokeWidth = 1.4;
    _horizonPaint.color = palette.secondary;
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

    // 纵深网格参数
    const cols = 24;
    const rows = 14;
    final vanishingPoint = Offset(size.width / 2.0, horizonY);

    // 提取低频能量带动地面震荡
    final bassEnergy = bands.length > 5 ? (bands[0] + bands[1] + bands[2]) / 3.0 : 0.0;

    // 绘制横向起伏声波等高线
    for (var r = 1; r <= rows; r++) {
      // 深度透视缩放: z 从 0 (远) 到 1 (近)
      final z = math.pow(r / rows, 2.2).toDouble();
      final baseY = horizonY + z * (size.height - horizonY);

      final path = Path();
      for (var c = 0; c <= cols; c++) {
        final u = c / cols;
        final x = u * size.width;

        // 根据频段能量计算局部山峦凸起高度
        final bandIdx = (u * (bands.length - 1)).round().clamp(0, bands.length - 1);
        final energy = bands.isNotEmpty ? bands[bandIdx] : 0.0;
        final mountainFactor = math.sin(u * math.pi) * 0.4 + (u < 0.2 || u > 0.8 ? 1.0 : 0.2);
        final displacement = energy * mountainFactor * 55.0 * z + (r == rows ? bassEnergy * 8.0 : 0.0);

        final y = baseY - displacement;
        if (c == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      final alpha = (z * 0.85 + 0.15).clamp(0.0, 1.0);
      _wirePaint.color = palette.primary.withValues(alpha: alpha);
      canvas.drawPath(path, _wirePaint);
    }

    // 绘制辐射纵向透视网格线
    for (var c = 0; c <= cols; c += 2) {
      final bottomX = (c / cols) * size.width;
      canvas.drawLine(
        vanishingPoint,
        Offset(bottomX, size.height),
        _wirePaint..color = palette.primary.withValues(alpha: 0.35),
      );
    }

    // 辉光
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.35).clamp(0.0, 0.6))
        ..strokeWidth = 3.0
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom * 4.0);
      canvas.drawLine(Offset(0, horizonY), Offset(size.width, horizonY), _glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CyberGridPainter oldDelegate) => true;
}

