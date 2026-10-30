import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../engine/auradsp_ffi.dart' show VizBands;
import '../models/visualizer_themes.dart';

/// 柱状频谱渲染画笔（均匀宽频柱、防抖动弹道与清晰悬浮峰值线）
class SpectrumBarsPainter extends CustomPainter {
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

    // 绘制横纵参考网格
    if (showGrid) {
      _drawGrid(canvas, size);
    }

    final barCount = bands.length;
    if (barCount == 0) return;

    final hasPeaks = showPeaks && peaks.length >= barCount;

    // 整幅画布共用一个渐变 shader 与模糊滤镜：避免每根柱重复创建（32~64 次/帧）
    _barPaint.shader = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: palette.gradient,
    ).createShader(Offset.zero & size);

    final bool drawGlow = bloom > 0.1;
    if (drawGlow) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.4).clamp(0.0, 0.75))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom * 5.0);
    }

    // 均匀柱宽与对称边距排布，消除高低频宽窄不一致问题
    final double gap = barCount > 40 ? 2.0 : 3.0;
    final double totalGaps = (barCount - 1) * gap;
    final double barWidth = math.max(2.0, (size.width - totalGaps) / barCount);
    final double actualTotalSpan = barCount * barWidth + totalGaps;
    final double leftOffset = (size.width - actualTotalSpan) / 2.0;

    for (var i = 0; i < barCount; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = v * (size.height - 4.0); // 留出顶部峰值线物理间隙

      final left = leftOffset + i * (barWidth + gap);
      final top = size.height - h;

      if (h > 0.5) {
        final barRect = Rect.fromLTWH(left, top, barWidth, h);
        final rrect = RRect.fromRectAndRadius(barRect, const Radius.circular(2.0));

        canvas.drawRRect(rrect, _barPaint);

        // 辉光仿真（共用同一模糊滤镜，仅对可见高度柱生效）
        if (drawGlow && h > 4.0) {
          canvas.drawRRect(rrect, _glowPaint);
        }
      }

      // 绘制物理峰值保持小白条（清晰悬浮于柱顶，绝不淹没覆盖）
      if (hasPeaks) {
        final pkVal = peaks[i].clamp(0.0, 1.0);
        if (pkVal > 0.015) {
          final barTopY = size.height - h;
          final peakTargetY = size.height - pkVal * (size.height - 4.0);
          final pkY = math.min(barTopY - 2.5, peakTargetY - 2.5);

          if (pkY >= 0) {
            canvas.drawLine(
              Offset(left, pkY),
              Offset(left + barWidth, pkY),
              _peakPaint,
            );
          }
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
