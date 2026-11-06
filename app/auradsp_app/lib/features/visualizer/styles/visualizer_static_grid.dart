import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../../../engine/auradsp_ffi.dart' show VizBands;
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';

/// 静态网格层：频谱柱 dB 网格 / 示波器分度网格 / 相位仪极坐标网格。
///
/// 2026-11-06（P2-1）：这些内容只随「风格 / 调色板 / 画布尺寸」变化，与音频帧
/// 和时间轴无关。此前它们被画在动态画笔内部，30 Hz 每帧重绘；现在抽成独立的
/// 静态画笔，由视口放进自己的 `RepaintBoundary`（`willChange: false`，允许
/// 光栅缓存保留），动态层继续 `willChange: true`。两侧互不干扰——动态层每帧
/// 变化不会让静态层的缓存失效，静态层也不会因为动态内容而重绘。
///
/// 绘制函数同时被各动态画笔复用（它们不再自己实现一份网格），保证「分层后的
/// 静态层」与「不分层时的内联网格」像素一致。
class StaticGridPainter extends CustomPainter {
  final VisualizerStyle style;
  final VisualizerPalette palette;

  final Paint _gridPaint = Paint()..strokeWidth = 1;
  final Paint _axisPaint = Paint()..strokeWidth = 1;

  /// 逐点缓冲跨帧复用（静态层只在参数变化时重绘，这里仅避免每次重绘分配）。
  final Float32List _gridLines = Float32List(16 * 4);

  StaticGridPainter({required this.style, required this.palette}) {
    _gridPaint.color = palette.grid;
    _axisPaint.color = palette.grid.withValues(alpha: 0.4);
  }

  /// 只有这三种风格的网格是纯静态的；其余风格的「网格」本身就是动态地形。
  static bool supports(VisualizerStyle style) => switch (style) {
        VisualizerStyle.bars ||
        VisualizerStyle.oscilloscope ||
        VisualizerStyle.goniometer =>
          true,
        _ => false,
      };

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    switch (style) {
      case VisualizerStyle.bars:
        paintBarsGrid(canvas, size, _gridPaint, _gridLines);
      case VisualizerStyle.oscilloscope:
        paintOscilloscopeGrid(canvas, size, _gridPaint, _gridLines);
      case VisualizerStyle.goniometer:
        paintPolarGrid(
          canvas,
          Offset(size.width / 2.0, size.height / 2.0),
          _radius(size),
          _gridPaint,
          _axisPaint,
          _gridLines,
        );
      default:
        break;
    }
  }

  static double _radius(Size size) =>
      (size.width < size.height ? size.width : size.height) * 0.44;

  @override
  bool shouldRepaint(covariant StaticGridPainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.palette != palette;
}

/// 频谱柱 dB 网格：4 等分横线（0/-15/-30/-45 dBFS）+ 100Hz/1kHz/10kHz 参考线。
void paintBarsGrid(
  Canvas canvas,
  Size size,
  Paint gridPaint,
  Float32List lines,
) {
  var o = 0;
  for (var i = 1; i < 4; i++) {
    final y = size.height * i / 4.0;
    lines[o++] = 0;
    lines[o++] = y;
    lines[o++] = size.width;
    lines[o++] = y;
  }
  for (final hz in const [100.0, 1000.0, 10000.0]) {
    final x = _logX(hz) * size.width;
    lines[o++] = x;
    lines[o++] = 0;
    lines[o++] = x;
    lines[o++] = size.height;
  }
  canvas.drawRawPoints(PointMode.lines, lines, gridPaint);
}

/// 示波器网格：零电平中心实线 + 8/6 分度。
void paintOscilloscopeGrid(
  Canvas canvas,
  Size size,
  Paint gridPaint,
  Float32List lines,
) {
  final centerY = size.height / 2.0;
  var o = 0;
  lines[o++] = 0;
  lines[o++] = centerY;
  lines[o++] = size.width;
  lines[o++] = centerY;

  const divX = 8;
  const divY = 6;
  for (var i = 1; i < divX; i++) {
    final x = size.width * i / divX;
    lines[o++] = x;
    lines[o++] = 0;
    lines[o++] = x;
    lines[o++] = size.height;
  }
  for (var j = 1; j < divY; j++) {
    final y = size.height * j / divY;
    lines[o++] = 0;
    lines[o++] = y;
    lines[o++] = size.width;
    lines[o++] = y;
  }
  canvas.drawRawPoints(PointMode.lines, lines, gridPaint);
}

/// 相位仪极坐标网格：3 层同心圆 + 45° 交叉轴。
void paintPolarGrid(
  Canvas canvas,
  Offset center,
  double radius,
  Paint gridPaint,
  Paint axisPaint,
  Float32List lines,
) {
  canvas.drawCircle(center, radius * 0.33, gridPaint);
  canvas.drawCircle(center, radius * 0.66, gridPaint);
  canvas.drawCircle(center, radius, gridPaint);

  final dx = radius * 0.707;
  final dy = radius * 0.707;
  lines[0] = center.dx - dx;
  lines[1] = center.dy - dy;
  lines[2] = center.dx + dx;
  lines[3] = center.dy + dy;
  lines[4] = center.dx - dx;
  lines[5] = center.dy + dy;
  lines[6] = center.dx + dx;
  lines[7] = center.dy - dy;
  canvas.drawRawPoints(PointMode.lines, lines, axisPaint);
}

/// 对数频率轴坐标：复用引擎侧同一映射，保证与动态画笔内的网格像素一致。
double _logX(double hz) => VizBands.logX(hz);
