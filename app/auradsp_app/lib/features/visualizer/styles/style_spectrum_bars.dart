import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../engine/auradsp_ffi.dart' show VizBands;
import '../models/visualizer_themes.dart';

/// 柱状频谱渲染画笔
class SpectrumBarsPainter extends CustomPainter {
  static const double _minBarWidth = 2.5;

  final List<double> bands;
  final List<double> peaks;
  final VisualizerPalette palette;
  final bool showGrid;
  final bool showPeaks;
  final double bloom;

  final Paint _gridPaint = Paint()..strokeWidth = 1;
  final Paint _barPaint = Paint();
  final Paint _peakPaint = Paint()..strokeWidth = 2.0;
  final Paint _glowPaint = Paint();

  SpectrumBarsPainter({
    required this.bands,
    required this.peaks,
    required this.palette,
    required this.showGrid,
    required this.showPeaks,
    required this.bloom,
  }) {
    _gridPaint.color = palette.grid;
    _peakPaint.color = palette.peak;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // 绘制横纵网格
    if (showGrid) {
      _drawGrid(canvas, size);
    }

    final n = math.max(1, bands.length);
    final hasPeaks = showPeaks && peaks.length >= n;

    for (var i = 0; i < n; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = v * size.height;

      // 对数坐标跨度与居中对齐
      final double x0, x1;
      if (n == VizBands.count) {
        x0 = VizBands.edgeX(i) * size.width;
        x1 = VizBands.edgeX(i + 1) * size.width;
      } else {
        x0 = (i / n) * size.width;
        x1 = ((i + 1) / n) * size.width;
      }

      final span = x1 - x0;
      final bw = math.max(_minBarWidth, span - 2.5);
      final left = x0 + (span - bw) / 2.0;
      final top = size.height - h;

      if (h > 0.5) {
        final barRect = Rect.fromLTWH(left, top, bw, h);
        final rrect = RRect.fromRectAndRadius(barRect, const Radius.circular(2.0));

        // 垂直渐变着色
        _barPaint.shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: palette.gradient,
        ).createShader(barRect);

        canvas.drawRRect(rrect, _barPaint);

        // 辉光模拟
        if (bloom > 0.1 && h > 4.0) {
          _glowPaint
            ..color = palette.glow.withValues(alpha: (bloom * 0.45).clamp(0.0, 0.8))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom * 6.0);
          canvas.drawRRect(rrect, _glowPaint);
        }
      }

      // 绘制峰值保持线
      if (hasPeaks) {
        final pkVal = peaks[i].clamp(0.0, 1.0);
        if (pkVal > 0.02) {
          final pkY = size.height - pkVal * size.height;
          canvas.drawLine(
            Offset(left, pkY),
            Offset(left + bw, pkY),
            _peakPaint,
          );
        }
      }
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    // 横向 dB 网格线（4 等分：0, -15, -30, -45 dBFS）
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4.0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _gridPaint);
    }

    // 纵向对数频率参考线（100Hz, 1kHz, 10kHz）
    for (final hz in const [100.0, 1000.0, 10000.0]) {
      final x = VizBands.logX(hz) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), _gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumBarsPainter oldDelegate) => true;
}

