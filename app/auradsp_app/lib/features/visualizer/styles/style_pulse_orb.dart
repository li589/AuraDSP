import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 反应式音频光环与星云粒子渲染画笔
class PulseOrbPainter extends CustomPainter implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  final Paint _ringPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _corePaint = Paint()..style = PaintingStyle.fill;
  final Paint _particlePaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  /// 谐振环 Path 跨帧复用；粒子色在构造时预计算（整场播放零逐帧 Color 分配）。
  final Path _path = Path();
  final Color _particleA;
  final Color _particleB;

  PulseOrbPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  })  : _particleA = palette.primary.withValues(alpha: 0.75),
        _particleB = palette.secondary.withValues(alpha: 0.75) {
    _ringPaint.strokeWidth = lineWidth;
    _corePaint.color = palette.secondary.withValues(alpha: 0.85);
    _particlePaint.color = palette.primary;
  }

  @override
  void setVisualizerTime(double time) => animationTime = time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final center = Offset(size.width / 2.0, size.height / 2.0);
    final minDim = math.min(size.width, size.height);
    final baseRadius = minDim * 0.22;

    // 提取频段能量
    var bass = 0.0, mid = 0.0, treble = 0.0;
    if (bands.length >= 16) {
      bass = (bands[0] + bands[1] + bands[2] + bands[3]) / 4.0;
      mid = (bands[8] + bands[10] + bands[12]) / 3.0;
      treble = (bands[20] + bands[24] + bands[28]) / 3.0;
    }

    // 核心受低音与中频能量冲击扩张
    final coreR = baseRadius * (0.8 + bass * 0.45 + mid * 0.15);
    canvas.drawCircle(center, coreR, _corePaint);

    // 环绕谐振声波环（对称镜像频段映射与贝塞尔圆弧闭合，消除接缝突变）
    const vertexCount = 64;
    final path = _path..reset();
    var firstX = 0.0, firstY = 0.0, prevX = 0.0, prevY = 0.0;
    for (var i = 0; i < vertexCount; i++) {
      final angle = (i / vertexCount) * 2 * math.pi;
      final u = i / vertexCount;
      final mirrorU = 1.0 - (2.0 * u - 1.0).abs();
      final bandIndex = (mirrorU * (bands.length - 1)).round().clamp(0, bands.length - 1);
      final energy = bands.isNotEmpty ? bands[bandIndex] : 0.0;

      final r = baseRadius * (1.15 + energy * 0.55 + math.sin(angle * 6 + animationTime * 2) * 0.06);
      final x = center.dx + math.cos(angle) * r;
      final y = center.dy + math.sin(angle) * r;
      if (i == 0) {
        path.moveTo(x, y);
        firstX = x;
        firstY = y;
      } else {
        final midX = (prevX + x) / 2.0;
        final midY = (prevY + y) / 2.0;
        path.quadraticBezierTo(prevX, prevY, midX, midY);
      }
      prevX = x;
      prevY = y;
    }
    path.quadraticBezierTo(prevX, prevY, firstX, firstY);
    path.close();

    _ringPaint.color = palette.primary;
    canvas.drawPath(path, _ringPaint);

    // 辉光扩散（加宽低透地平描，避免每帧模糊图层）
    if (bloom > 0.1) {
      _glowPaint
        ..color = palette.glow.withValues(alpha: (bloom * 0.2).clamp(0.0, 0.34))
        ..strokeWidth = 3.5 + bloom * 4.0
        ..maskFilter = null;
      canvas.drawPath(path, _glowPaint);
    }

    // 外部发散粒子轨道
    const particleCount = 36;
    for (var i = 0; i < particleCount; i++) {
      final pAngle = (i / particleCount) * 2 * math.pi + animationTime * (0.3 + (i % 3) * 0.1);
      final dist = baseRadius * (1.6 + math.sin(i * 1.7) * 0.35 + treble * 0.5);
      final px = center.dx + math.cos(pAngle) * dist;
      final py = center.dy + math.sin(pAngle) * dist;
      final pr = (1.5 + (i % 4) * 0.8 + treble * 2.0).clamp(1.0, 5.0);

      _particlePaint.color = (i % 2 == 0 ? _particleA : _particleB);
      canvas.drawCircle(Offset(px, py), pr, _particlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant PulseOrbPainter oldDelegate) => true;
}
