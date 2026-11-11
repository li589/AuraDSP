import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_static_grid.dart';

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

  /// 全部柱体合并到两条 Path（实心 + 辉光衬底）一次性提交：把每帧 2×N
  /// 次 drawRRect 降到 2 次 drawPath，路径对象跨帧复用。
  final Path _barPath = Path();
  final Path _glowPath = Path();

  /// 峰值悬浮线合并为一条 Path（纯水平线段，与逐条 drawLine 视觉等价）。
  final Path _peakPath = Path();

  /// dB 网格线坐标缓冲：3 横 + 3 纵，原地覆写后一次批量提交。
  final Float32List _gridLines = Float32List(6 * 4);

  static const Radius _barRadius = Radius.circular(2.0);
  static const Radius _glowRadius = Radius.circular(3.0);

  /// 辉光色只取决于 bloom（画笔实例跨帧复用），构造时算好。
  final Color _glowColor;

  SpectrumBarsPainter({
    required this.bands,
    required this.peaks,
    required this.palette,
    required this.showGrid,
    required this.showPeaks,
    required this.bloom,
  }) : _glowColor =
            palette.glow.withValues(alpha: (bloom * 0.16).clamp(0.0, 0.32)) {
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
        ..color = _glowColor;
    }

    // 均匀柱宽与对称边距排布，消除高低频宽窄不一致问题
    final double gap = barCount > 40 ? 2.0 : 3.0;
    final double totalGaps = (barCount - 1) * gap;
    final double barWidth = math.max(2.0, (size.width - totalGaps) / barCount);
    final double actualTotalSpan = barCount * barWidth + totalGaps;
    final double leftOffset = (size.width - actualTotalSpan) / 2.0;

    _barPath.reset();
    if (drawGlow) _glowPath.reset();
    if (hasPeaks) _peakPath.reset();

    for (var i = 0; i < barCount; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = v * (size.height - 4.0); // 留出顶部峰值线物理间隙

      final left = leftOffset + i * (barWidth + gap);
      final top = size.height - h;

      if (h > 0.5) {
        // 直接用 LTRB 构造圆角矩形，省掉中间 Rect 对象
        _barPath.addRRect(RRect.fromLTRBAndCorners(
          left,
          top,
          left + barWidth,
          size.height,
          topLeft: _barRadius,
          topRight: _barRadius,
        ));

        // 辉光底衬（加宽矩形，无模糊图层）
        if (drawGlow && h > 4.0) {
          _glowPath.addRRect(RRect.fromLTRBAndCorners(
            left - 1.0,
            top - 1.5,
            left + barWidth + 1.0,
            size.height + 0.5,
            topLeft: _glowRadius,
            topRight: _glowRadius,
          ));
        }
      }

      // 物理峰值保持小白条（清晰悬浮于柱顶，绝不淹没覆盖）
      if (hasPeaks) {
        final pkVal = peaks[i].clamp(0.0, 1.0);
        if (pkVal > 0.015) {
          final barTopY = size.height - h;
          final peakTargetY = size.height - pkVal * (size.height - 4.0);
          final pkY = math.min(barTopY - 2.5, peakTargetY - 2.5);

          if (pkY >= 0) {
            _peakPath
              ..moveTo(left, pkY)
              ..lineTo(left + barWidth, pkY);
          }
        }
      }
    }

    if (drawGlow) canvas.drawPath(_glowPath, _glowPaint);
    canvas.drawPath(_barPath, _barPaint);
    if (hasPeaks) canvas.drawPath(_peakPath, _peakPaint);
  }

  void _drawGrid(Canvas canvas, Size size) =>
      paintBarsGrid(canvas, size, _gridPaint, _gridLines);

  @override
  bool shouldRepaint(covariant SpectrumBarsPainter oldDelegate) => true;
}
