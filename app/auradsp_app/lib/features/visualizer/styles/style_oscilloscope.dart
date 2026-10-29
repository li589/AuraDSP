import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 实时双通道示波器渲染画笔
class OscilloscopePainter extends CustomPainter {
  final List<double> waveL;
  final List<double> waveR;
  final VisualizerPalette palette;
  final bool showGrid;
  final double bloom;

  final Paint _gridPaint = Paint()..strokeWidth = 1;
  final Paint _zeroLinePaint = Paint()..strokeWidth = 1;
  final Paint _waveLPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _waveRPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  OscilloscopePainter({
    required this.waveL,
    required this.waveR,
    required this.palette,
    required this.showGrid,
    required this.bloom,
  }) {
    _gridPaint.color = palette.grid;
    _zeroLinePaint.color = palette.grid.withValues(alpha: 0.35);

    _waveLPaint
      ..color = palette.primary
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    _waveRPaint
      ..color = palette.secondary.withValues(alpha: 0.85)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final centerY = size.height / 2.0;

    // 绘制示波器网格
    if (showGrid) {
      _drawOscilloscopeGrid(canvas, size, centerY);
    }

    final n = waveL.length;
    if (n < 2) return;

    final pathL = Path();
    final pathR = Path();
    final stepX = size.width / (n - 1);
    final amp = size.height * 0.42;

    for (var i = 0; i < n; i++) {
      final x = i * stepX;
      final yL = centerY - waveL[i] * amp;
      final yR = centerY - waveR[i] * amp;

      if (i == 0) {
        pathL.moveTo(x, yL);
        pathR.moveTo(x, yR);
      } else {
        pathL.lineTo(x, yL);
        pathR.lineTo(x, yR);
      }
    }

    // 荧光余辉 Glow 模拟
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.5).clamp(0.0, 0.75))
        ..strokeWidth = 3.5 + bloom * 4.0
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom * 5.0);
      canvas.drawPath(pathL, _glowPaint);
      canvas.drawPath(pathR, _glowPaint);
    }

    // 绘制清晰主迹线
    canvas.drawPath(pathR, _waveRPaint);
    canvas.drawPath(pathL, _waveLPaint);
  }

  void _drawOscilloscopeGrid(Canvas canvas, Size size, double centerY) {
    // 零电平中心实线
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), _zeroLinePaint);

    // 8 格分度网格
    const divX = 8;
    const divY = 6;
    for (var i = 1; i < divX; i++) {
      final x = size.width * i / divX;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), _gridPaint);
    }
    for (var j = 1; j < divY; j++) {
      final y = size.height * j / divY;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant OscilloscopePainter oldDelegate) => true;
}

