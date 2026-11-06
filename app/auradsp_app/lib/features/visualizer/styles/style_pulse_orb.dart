import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;
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
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;

  /// 谐振环 Path 跨帧复用；粒子色在构造时预计算（整场播放零逐帧 Color 分配）。
  final Path _path = Path();
  final Color _particleA;
  final Color _particleB;
  final Color _glowColor;

  /// 粒子按 (奇偶色 × i%4 半径档) 分成 8 组，每组共享同一半径与颜色，
  /// 坐标累计进复用缓冲后一次 `drawRawPoints` 提交，消除每帧 36 个 Offset。
  static final List<List<int>> _particleGroups = _buildGroups();
  static const int _particleCount = 36;
  final List<Float32List> _groupPoints = List.generate(8, (_) => Float32List(0));
  final List<Paint> _groupPaints = List.generate(
    8,
    (_) => Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round,
  );
  bool _groupsReady = false;

  static List<List<int>> _buildGroups() {
    final groups = List.generate(8, (_) => <int>[]);
    for (var i = 0; i < _particleCount; i++) {
      groups[(i % 2) * 4 + (i % 4)].add(i);
    }
    return groups;
  }

  PulseOrbPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  })  : _particleA = palette.primary.withValues(alpha: 0.75),
        _particleB = palette.secondary.withValues(alpha: 0.75),
        _glowColor = palette.glow.withValues(alpha: (bloom * 0.2).clamp(0.0, 0.34)) {
    _ringPaint
      ..strokeWidth = lineWidth
      ..color = palette.primary;
    _corePaint.color = palette.secondary.withValues(alpha: 0.85);
  }

  @override
  void setVisualizerTime(double time) => animationTime = time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final centerX = size.width / 2.0;
    final centerY = size.height / 2.0;
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
    canvas.drawCircle(Offset(centerX, centerY), coreR, _corePaint);

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
      final x = centerX + math.cos(angle) * r;
      final y = centerY + math.sin(angle) * r;
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

    canvas.drawPath(path, _ringPaint);

    // 辉光扩散（加宽低透地平描，避免每帧模糊图层）
    if (bloom > 0.1) {
      _glowPaint
        ..color = _glowColor
        ..strokeWidth = 3.5 + bloom * 4.0
        ..maskFilter = null;
      canvas.drawPath(path, _glowPaint);
    }

    // 外部发散粒子轨道：按颜色 × 半径档分组批量提交
    _ensureGroups();
    for (var g = 0; g < _particleGroups.length; g++) {
      final indices = _particleGroups[g];
      final buf = _groupPoints[g];
      final mod = g % 4;
      for (var k = 0; k < indices.length; k++) {
        final i = indices[k];
        final pAngle = (i / _particleCount) * 2 * math.pi +
            animationTime * (0.3 + (i % 3) * 0.1);
        final dist = baseRadius * (1.6 + math.sin(i * 1.7) * 0.35 + treble * 0.5);
        buf[k * 2] = centerX + math.cos(pAngle) * dist;
        buf[k * 2 + 1] = centerY + math.sin(pAngle) * dist;
      }
      final pr = (1.5 + mod * 0.8 + treble * 2.0).clamp(1.0, 5.0);
      _groupPaints[g]
        ..strokeWidth = pr * 2.0
        ..color = (g < 4 ? _particleA : _particleB);
      canvas.drawRawPoints(PointMode.points, buf, _groupPaints[g]);
    }
  }

  void _ensureGroups() {
    if (_groupsReady) return;
    for (var g = 0; g < _particleGroups.length; g++) {
      _groupPoints[g] = Float32List(_particleGroups[g].length * 2);
    }
    _groupsReady = true;
  }

  @override
  bool shouldRepaint(covariant PulseOrbPainter oldDelegate) => true;
}
