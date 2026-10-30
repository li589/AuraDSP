import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';

/// 粒子龙卷风：确定性螺旋粒子风暴
///
/// 性能要点：
/// - 粒子与尘埃参数为进程级静态种子表（固定随机源），每帧零随机、零列表分配；
/// - 螺旋股复用同一条 Path（逐股 reset），辉光合并后仅模糊一次；
/// - 纯 Canvas 2D，不依赖 dart:io / 窗口 API，全平台一致。
class ParticleTornadoPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;
  final double lineWidth;

  static const int _strandCount = 5;
  static const int _nodes = 44;
  static const int _dustCount = 48;

  /// 螺旋股相位（固定，保证姿态稳定）
  static const List<double> _strandPhase = [0.0, 1.26, 2.52, 3.78, 5.04];

  /// 尘埃种子：[相位, 轨道速度, 抖动, 尺寸] × _dustCount
  static final List<double> _dustSeeds = _buildDustSeeds();

  final Paint _filamentPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _glowPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _dotPaintA = Paint()..style = PaintingStyle.fill;
  final Paint _dotPaintB = Paint()..style = PaintingStyle.fill;
  final Paint _sparkPaint = Paint()..style = PaintingStyle.fill;
  final Paint _dustPaint = Paint()..style = PaintingStyle.fill;
  final Paint _capPaint = Paint()..style = PaintingStyle.fill;
  final Path _strandPath = Path();
  final Path _glowPath = Path();

  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  });

  static List<double> _buildDustSeeds() {
    final rnd = math.Random(20251030);
    final out = List<double>.filled(_dustCount * 4, 0.0);
    for (var i = 0; i < _dustCount; i++) {
      final o = i * 4;
      out[o] = rnd.nextDouble() * math.pi * 2; // 初始相位
      out[o + 1] = 0.35 + rnd.nextDouble() * 0.9; // 角速度
      out[o + 2] = rnd.nextDouble() * math.pi * 2; // 抖动相位
      out[o + 3] = 0.6 + rnd.nextDouble() * 1.4; // 尺寸
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
    if (n == 0) return;

    final bass = _avg(0, math.max(1, n ~/ 8));
    final mid = _avg(n ~/ 4, n ~/ 2);
    final minDim = math.min(w, h);

    final cx = w / 2.0;
    final baseY = h * 0.9;
    final maxR = minDim * (0.22 + bass * 0.12);
    final funnelH = h * (0.68 + bass * 0.08);
    final sway = w * 0.03 * math.sin(t * 0.35);
    final spin = t * (0.9 + bass * 1.1);

    // 底部低频冲击光池（径向渐变收边，避免出现实心圆盘）
    final capCenter = Offset(cx + sway * 0.2, baseY);
    final capRadius = maxR * (1.0 + bass * 0.5);
    _capPaint.shader = RadialGradient(
      colors: [
        palette.glow.withValues(alpha: 0.1 + bass * 0.22),
        palette.glow.withValues(alpha: 0.0),
      ],
    ).createShader(
      Rect.fromCenter(
        center: capCenter,
        width: capRadius * 2.2,
        height: minDim * 0.22,
      ),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: capCenter,
        width: capRadius * 2.2,
        height: minDim * 0.11,
      ),
      _capPaint,
    );

    // 第一遍：合并螺旋路径，让辉光铺在粒子下方
    _glowPath.reset();
    for (var sIdx = 0; sIdx < _strandCount; sIdx++) {
      _buildStrand(sIdx, cx, baseY, maxR, funnelH, sway, spin, t, n, mid);
      _glowPath.addPath(_strandPath, Offset.zero);
    }

    if (bloom > 0.05) {
      _glowPaint
        ..shader = null
        ..color = palette.glow.withValues(alpha: 0.16 + bloom * 0.32)
        ..strokeWidth = lineWidth * 2.4
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(1.5, bloom * 5.5),
        );
      canvas.drawPath(_glowPath, _glowPaint);
    }

    // 第二遍：细丝 + 粒子
    _filamentPaint.color = palette.primary.withValues(alpha: 0.2);
    _dotPaintA.color = palette.primary.withValues(alpha: 0.5);
    _dotPaintB.color = palette.secondary.withValues(alpha: 0.55);
    _sparkPaint.color = palette.peak.withValues(alpha: 0.8);

    for (var sIdx = 0; sIdx < _strandCount; sIdx++) {
      _buildStrand(sIdx, cx, baseY, maxR, funnelH, sway, spin, t, n, mid);
      _filamentPaint.strokeWidth = lineWidth * 0.8;
      canvas.drawPath(_strandPath, _filamentPaint);
      _drawStrandParticles(
        canvas,
        sIdx,
        cx,
        baseY,
        maxR,
        funnelH,
        sway,
        spin,
        t,
        n,
      );
    }

    _drawDust(canvas, cx, baseY, maxR, t);
  }

  /// 构建第 [sIdx] 条螺旋股（0 底部 → 1 顶部）。
  void _buildStrand(
    int sIdx,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double sway,
    double spin,
    double t,
    int n,
    double mid,
  ) {
    final phase = _strandPhase[sIdx % _strandPhase.length];

    _strandPath.reset();
    for (var k = 0; k < _nodes; k++) {
      final u = k / (_nodes - 1);
      final bandIdx = (u * (n - 1)).round().clamp(0, n - 1);
      final energy = bands[bandIdx];

      // 下窄上宽的漏斗轮廓，能量向外推
      final profile = math.pow(u, 1.35).toDouble();
      final radius =
          maxR * (0.1 + 0.9 * profile) * (0.88 + energy * 0.4 + mid * 0.08);
      // 约 1.6 圈螺旋，股间错相形成缠绕
      final angle = phase + spin + u * 10.0 + t * u * 0.45;

      final x = cx + sway * (1.0 - u) + math.cos(angle) * radius;
      final y = baseY - u * funnelH + math.sin(angle) * radius * 0.18;

      if (k == 0) {
        _strandPath.moveTo(x, y);
      } else {
        _strandPath.lineTo(x, y);
      }
    }
  }

  /// 在螺旋节点上散布粒子；近处（底部）更大，模拟透视。
  void _drawStrandParticles(
    Canvas canvas,
    int sIdx,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double sway,
    double spin,
    double t,
    int n,
  ) {
    final phase = _strandPhase[sIdx % _strandPhase.length];

    for (var k = 0; k < _nodes; k++) {
      final u = k / (_nodes - 1);
      final bandIdx = (u * (n - 1)).round().clamp(0, n - 1);
      final energy = bands[bandIdx];

      final profile = math.pow(u, 1.35).toDouble();
      final radius =
          maxR * (0.1 + 0.9 * profile) * (0.88 + energy * 0.4);
      final angle = phase + spin + u * 10.0 + t * u * 0.45;

      final x = cx + sway * (1.0 - u) + math.cos(angle) * radius;
      final y = baseY - u * funnelH + math.sin(angle) * radius * 0.18;

      final sizePx = 0.9 + (1.0 - u) * 1.7 + energy * 1.1;
      final paint =
          k % 7 == 0 ? _sparkPaint : (k.isEven ? _dotPaintA : _dotPaintB);
      canvas.drawCircle(Offset(x, y), sizePx, paint);
    }
  }

  void _drawDust(Canvas canvas, double cx, double baseY, double maxR, double t) {
    for (var i = 0; i < _dustCount; i++) {
      final o = i * 4;
      final phase = _dustSeeds[o];
      final speed = _dustSeeds[o + 1];
      final wobblePhase = _dustSeeds[o + 2];
      final sizePx = _dustSeeds[o + 3];

      final angle = phase + t * speed;
      final life = (t * 0.16 + i / _dustCount) % 1.0; // 0 地面 → 1 顶部
      final radius = maxR * (0.2 + life * 0.9);
      final x = cx + math.cos(angle) * radius;
      final y = baseY - life * maxR * 0.9 + math.sin(angle) * radius * 0.24;

      final twinkle = 0.5 + 0.5 * math.sin(t * 1.6 + wobblePhase);
      _dustPaint.color = (i.isEven ? palette.secondary : palette.primary)
          .withValues(alpha: 0.18 + twinkle * 0.42);
      canvas.drawCircle(
        Offset(x, y),
        sizePx * (0.7 + twinkle * 0.6),
        _dustPaint,
      );
    }
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
  bool shouldRepaint(covariant ParticleTornadoPainter oldDelegate) => true;
}
