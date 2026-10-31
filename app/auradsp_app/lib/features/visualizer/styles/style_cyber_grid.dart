import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 3D 透视赛博音频网格渲染画笔（高密度平滑地形样条与低频共振）
class CyberGridPainter extends CustomPainter implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  static const int _cols = 64;
  static const int _rows = 14;

  final Paint _wirePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _horizonPaint = Paint()..strokeWidth = 2.0;
  final Paint _sunPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  /// 每帧的列位移缓冲与 Path 全部复用（画笔实例由视口缓存）：
  /// 旧实现每帧分配 14 份 `List<double>` + 14 条 Path，Skia 原生内存
  /// 只能等 GC finalizer 回收，长时间播放会持续抬高进程内存。
  final Float32List _raw = Float32List(_cols + 1);
  final Float32List _smooth = Float32List(_cols + 1);
  final Path _path = Path();

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
  void setVisualizerTime(double time) => animationTime = time;

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
    final vanishingPoint = Offset(size.width / 2.0, horizonY);

    // 提取低频能量带动地面震荡
    final bassEnergy = bands.length > 5 ? (bands[0] + bands[1] + bands[2]) / 3.0 : 0.0;

    // 绘制横向起伏声波等高线（贝塞尔样条连接，极度顺滑）
    for (var r = 1; r <= _rows; r++) {
      final z = math.pow(r / _rows, 2.2).toDouble();
      final baseY = horizonY + z * (size.height - horizonY);

      // 计算各列的原始位移（复用缓冲）
      for (var c = 0; c <= _cols; c++) {
        final u = c / _cols;
        final bandIdx = (u * (bands.length - 1)).round().clamp(0, bands.length - 1);
        final energy = bands.isNotEmpty ? bands[bandIdx] : 0.0;
        final mountainFactor = math.sin(u * math.pi) * 0.45 + (u < 0.2 || u > 0.8 ? 0.95 : 0.25);
        final displacement = energy * mountainFactor * 52.0 * z + (r == _rows ? bassEnergy * 8.0 : 0.0);
        _raw[c] = baseY - displacement;
      }

      // 3点邻近空间滤波柔化局部尖刺（就地写入平滑缓冲）
      for (var c = 0; c <= _cols; c++) {
        if (c == 0 || c == _cols) {
          _smooth[c] = _raw[c];
        } else {
          _smooth[c] = 0.25 * _raw[c - 1] + 0.5 * _raw[c] + 0.25 * _raw[c + 1];
        }
      }

      // 二次贝塞尔光滑曲线连接，彻底根除硬折角（单条 Path 复位复用）
      final path = _path..reset();
      path.moveTo(0, _smooth[0]);
      for (var c = 1; c <= _cols; c++) {
        final x = (c / _cols) * size.width;
        final prevX = ((c - 1) / _cols) * size.width;
        final midX = (prevX + x) / 2.0;
        final midY = (_smooth[c - 1] + _smooth[c]) / 2.0;
        path.quadraticBezierTo(prevX, _smooth[c - 1], midX, midY);
      }
      path.lineTo(size.width, _smooth[_cols]);

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
