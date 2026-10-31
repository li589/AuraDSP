import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 通用氛围底层：低频光晕 + 微尘星点 + 地平线余晖
///
/// 供柱状谱 / 示波器 / 相位仪 / 网格 / 星云等 Canvas 风格共享，
/// 叠在画笔之下提升「空气感」。GPU 着色器与 MilkDrop 自带满屏输出，不叠加。
///
/// 性能要点（2026-10-31 内存优化）：实例由视口缓存、时间可变；光晕径向
/// 渐变按「尺寸 + 激活度量化档」缓存，避免每帧新建 Shader（Skia 原生对象
/// 只会随 GC finalizer 回收，逐帧新建会把进程内存推高）。
class AtmospherePainter extends CustomPainter implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  double animationTime;
  final double intensity;

  static const int _speckCount = 64;

  /// 星点种子：[u, v, 相位, 半径] × _speckCount
  static final List<double> _speckSeeds = _buildSpecks();

  final Paint _speckPaint = Paint()..style = PaintingStyle.fill;
  final Paint _haloPaint = Paint()..style = PaintingStyle.fill;
  final Paint _horizonPaint = Paint()..style = PaintingStyle.stroke;

  /// 光晕径向渐变缓存：单位圆 shader + 画布缩放，尺寸/半径变化都不重建。
  Shader? _haloShader;
  int _haloLevel = -1;

  AtmospherePainter({
    required this.bands,
    required this.palette,
    required this.animationTime,
    this.intensity = 0.6,
  });

  @override
  void setVisualizerTime(double time) => animationTime = time;

  static List<double> _buildSpecks() {
    final rnd = math.Random(1987);
    final out = List<double>.filled(_speckCount * 4, 0.0);
    for (var i = 0; i < _speckCount; i++) {
      final o = i * 4;
      out[o] = rnd.nextDouble();
      out[o + 1] = rnd.nextDouble();
      out[o + 2] = rnd.nextDouble() * math.pi * 2;
      out[o + 3] = 0.6 + rnd.nextDouble() * 1.4;
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final w = size.width;
    final h = size.height;
    final t = animationTime;
    final n = bands.length;
    final bass = n == 0 ? 0.0 : _avg(0, math.max(1, n ~/ 8));
    final activation = (0.35 + bass * 0.65) * intensity;

    // 低频呼吸光晕：从底部中央缓慢起伏（shader 按激活度 8 档缓存 + 单位圆缩放）
    final center = Offset(w * 0.5, h * (0.72 + 0.03 * math.sin(t * 0.4)));
    final radius = math.max(w, h) * (0.5 + bass * 0.3);
    final level = (activation * 8).floor().clamp(0, 8);
    if (_haloShader == null || _haloLevel != level) {
      _haloLevel = level;
      final a = level / 8.0;
      _haloShader = RadialGradient(
        colors: [
          palette.glow.withValues(alpha: 0.08 + a * 0.22),
          palette.secondary.withValues(alpha: 0.03 + a * 0.05),
          palette.glow.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(const Rect.fromLTRB(-1, -1, 1, 1));
    }
    _haloPaint.shader = _haloShader;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(radius, radius);
    canvas.drawCircle(Offset.zero, 1.0, _haloPaint);
    canvas.restore();

    // 漂浮微尘（确定位置 + 正弦漂移 + 闪烁）
    for (var i = 0; i < _speckCount; i++) {
      final o = i * 4;
      final u = _speckSeeds[o];
      final v = _speckSeeds[o + 1];
      final phase = _speckSeeds[o + 2];
      final baseSize = _speckSeeds[o + 3];

      final x = w * u + math.sin(t * 0.18 + phase) * w * 0.012;
      final y = h * v + math.cos(t * 0.24 + phase * 1.3) * h * 0.016;
      final twinkle = 0.5 + 0.5 * math.sin(t * 0.9 + phase * 2.0);

      _speckPaint.color = (i % 3 == 0 ? palette.secondary : palette.primary)
          .withValues(alpha: (0.06 + twinkle * 0.22) * activation);
      canvas.drawCircle(
        Offset(x, y),
        baseSize * (0.55 + twinkle * 0.45),
        _speckPaint,
      );
    }

    // 地平线余晖：低频能量越强越亮
    _horizonPaint
      ..color = palette.glow.withValues(alpha: 0.035 + activation * 0.1)
      ..strokeWidth = 1.0 + bass * 1.4;
    canvas.drawLine(
      Offset(0, h * 0.94),
      Offset(w, h * 0.94),
      _horizonPaint,
    );
  }

  double _avg(int from, int to) {
    if (bands.isEmpty) return 0.0;
    final start = from.clamp(0, bands.length - 1);
    final end = to.clamp(start + 1, bands.length);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += bands[i];
    }
    return sum / (end - start);
  }

  @override
  bool shouldRepaint(covariant AtmospherePainter oldDelegate) => true;
}
