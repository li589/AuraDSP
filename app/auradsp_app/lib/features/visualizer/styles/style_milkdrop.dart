import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import '../plugins/milkdrop_preset.dart';

/// Winamp MilkDrop 2 经典算法模拟与自适应画布绘制器
class MilkdropPainter extends CustomPainter {
  final MilkdropPreset preset;
  final List<double> bands;
  final VisualizerPalette palette;
  final double time;
  final double sensitivity;
  final double lineWidth;

  MilkdropPainter({
    required this.preset,
    required this.bands,
    required this.palette,
    required this.time,
    required this.sensitivity,
    this.lineWidth = 1.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final cx = size.width / 2.0;
    final cy = size.height / 2.0;
    final baseRadius = math.min(cx, cy);

    // 提取三频能量 (Bass, Mid, Treble)
    var bass = 0.0, mid = 0.0, treble = 0.0;
    if (bands.length >= 16) {
      bass = ((bands[0] + bands[1] + bands[2] + bands[3]) / 4.0 * sensitivity).clamp(0.0, 2.0);
      mid = ((bands[8] + bands[10] + bands[12]) / 3.0 * sensitivity).clamp(0.0, 2.0);
      treble = ((bands[20] + bands[24] + bands[28]) / 3.0 * sensitivity).clamp(0.0, 2.0);
    }

    // 1. 模拟 MilkDrop Decay / Zoom 背景衰减映射
    final zoomFactor = preset.zoom.clamp(0.8, 1.4) + bass * 0.08;
    final bgPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.9 * zoomFactor,
        colors: [
          palette.secondary.withValues(alpha: (0.12 * preset.decay + bass * 0.18).clamp(0.0, 0.6)),
          palette.primary.withValues(alpha: (0.05 * preset.decay).clamp(0.0, 0.4)),
          const Color(0x00000000),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // 2. 根据 Preset WaveMode 呈现不同 MilkDrop 经典拓扑
    switch (preset.waveMode % 3) {
      case 0:
        _paintConcentricVortex(canvas, cx, cy, baseRadius, bass, mid, treble);
        break;
      case 1:
        _paintPolarSpiral(canvas, cx, cy, baseRadius, bass, mid, treble);
        break;
      case 2:
      default:
        _paintStarburstWarp(canvas, cx, cy, baseRadius, bass, mid, treble);
        break;
    }
  }

  void _paintConcentricVortex(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double bass,
    double mid,
    double treble,
  ) {
    final ringCount = 8;
    for (var i = 0; i < ringCount; i++) {
      final frac = (i + 1) / ringCount;
      final currentR = r * frac * (0.6 + bass * 0.35);
      final alpha = (0.2 + (1.0 - frac) * 0.6 * (0.5 + mid * 0.5)).clamp(0.0, 1.0);
      final color = Color.lerp(palette.primary, palette.secondary, frac)!;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = lineWidth + bass * 2.0
        ..color = color.withValues(alpha: alpha);

      canvas.drawCircle(Offset(cx, cy), currentR, paint);
    }
  }

  void _paintPolarSpiral(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double bass,
    double mid,
    double treble,
  ) {
    final path = Path();
    const points = 72;
    var first = true;

    for (var i = 0; i < points; i++) {
      final theta = (i / points) * 4.0 * math.pi + time * 1.5;
      final bandIdx = (i % (bands.isEmpty ? 1 : bands.length));
      final energy = bands.isNotEmpty ? bands[bandIdx] * sensitivity : 0.0;
      final dist = (i / points) * r * 0.85 + energy * 25.0 * (1.0 + bass);

      final x = cx + dist * math.cos(theta);
      final y = cy + dist * math.sin(theta);

      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth * 1.1 + treble * 1.8
      ..color = palette.primary.withValues(alpha: 0.85);
    canvas.drawPath(path, paint);
  }

  void _paintStarburstWarp(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double bass,
    double mid,
    double treble,
  ) {
    const rays = 24;
    final rayPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth * 1.1
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < rays; i++) {
      final angle = (i / rays) * 2.0 * math.pi + time * 0.6;
      final bandIdx = (i % (bands.isEmpty ? 1 : bands.length));
      final amp = bands.isNotEmpty ? bands[bandIdx] * sensitivity : 0.0;

      final inner = r * 0.2 * (1.0 + mid * 0.4);
      final outer = r * (0.35 + amp * 0.5 + bass * 0.25);

      final x1 = cx + inner * math.cos(angle);
      final y1 = cy + inner * math.sin(angle);
      final x2 = cx + outer * math.cos(angle);
      final y2 = cy + outer * math.sin(angle);

      final color = Color.lerp(palette.primary, palette.secondary, i / rays)!;
      rayPaint.color = color.withValues(alpha: (0.4 + amp * 0.6).clamp(0.0, 1.0));
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), rayPaint);
    }
  }

  @override
  bool shouldRepaint(covariant MilkdropPainter oldDelegate) {
    return true;
  }
}

