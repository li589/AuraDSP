import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';

/// 实时双通道示波器渲染画笔（支持光滑曲线样条与动态微调线宽）
class OscilloscopePainter extends CustomPainter {
  final List<double> waveL;
  final List<double> waveR;
  final VisualizerPalette palette;
  final bool showGrid;
  final double bloom;
  final double lineWidth;

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
    this.lineWidth = 1.5,
  }) {
    _gridPaint.color = palette.grid;
    _zeroLinePaint.color = palette.grid.withValues(alpha: 0.35);

    _waveLPaint
      ..color = palette.primary
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    _waveRPaint
      ..color = palette.secondary.withValues(alpha: 0.85)
      ..strokeWidth = mathMax(0.7, lineWidth * 0.85)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
  }

  static double mathMax(double a, double b) => a > b ? a : b;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final centerY = size.height / 2.0;

    // 绘制示波器参考网格
    if (showGrid) {
      _drawOscilloscopeGrid(canvas, size, centerY);
    }

    final n = waveL.length;
    if (n < 2) return;

    final pathL = Path();
    final pathR = Path();
    final stepX = size.width / (n - 1);
    final amp = size.height * 0.42;

    pathL.moveTo(0, centerY - waveL[0] * amp);
    pathR.moveTo(0, centerY - waveR[0] * amp);

    // 二次贝塞尔光滑样条曲线插值，彻底消除生硬折线
    for (var i = 1; i < n; i++) {
      final prevX = (i - 1) * stepX;
      final curX = i * stepX;
      final prevYL = centerY - waveL[i - 1] * amp;
      final curYL = centerY - waveL[i] * amp;
      final prevYR = centerY - waveR[i - 1] * amp;
      final curYR = centerY - waveR[i] * amp;

      final midXL = (prevX + curX) / 2.0;
      final midYL = (prevYL + curYL) / 2.0;
      final midYR = (prevYR + curYR) / 2.0;

      pathL.quadraticBezierTo(prevX, prevYL, midXL, midYL);
      pathR.quadraticBezierTo(prevX, prevYR, midXL, midYR);
    }
    pathL.lineTo(size.width, centerY - waveL[n - 1] * amp);
    pathR.lineTo(size.width, centerY - waveR[n - 1] * amp);

    // 荧光余辉 Glow 模拟
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.5).clamp(0.0, 0.75))
        ..strokeWidth = lineWidth * 2.0 + bloom * 4.0
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
