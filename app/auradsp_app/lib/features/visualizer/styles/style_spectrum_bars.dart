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

  /// 渐变 shader 按画布尺寸缓存：画笔实例由视口缓存复用，窗口不变时
  /// 整场播放只创建一次（旧实现每帧新建 Skia Shader，原生内存靠 finalizer 回收）。
  Shader? _barShader;
  Size _barShaderSize = Size.zero;

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

    // 整幅画布共用一个渐变 shader：按尺寸缓存，仅在窗口尺寸变化时重建
    if (_barShader == null || _barShaderSize != size) {
      _barShaderSize = size;
      _barShader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: palette.gradient,
      ).createShader(Offset.zero & size);
    }
    _barPaint.shader = _barShader;

    final bool drawGlow = bloom > 0.1;
    if (drawGlow) {
      // 不再使用 MaskFilter.blur：每帧对几十根柱各做一次模糊会反复分配整屏图层，
      // 长时间播放会把进程内存推到 GB 级并拖慢光栅线程。改用加宽底衬模拟辉光。
      _glowPaint
        ..shader = null
        ..color = palette.glow.withValues(alpha: (bloom * 0.16).clamp(0.0, 0.32));
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

        // 辉光底衬（加宽矩形，无模糊图层）
        if (drawGlow && h > 4.0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(left - 1.0, top - 1.5, barWidth + 2.0, h + 2.0),
              const Radius.circular(3.0),
            ),
            _glowPaint,
          );
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
