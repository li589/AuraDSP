import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';

/// 粒子龙卷风：确定性粒子漏斗
///
/// 设计要点：
/// - 用极淡的锥体轮廓 + 3 条纵向渐隐的螺旋导引线勾勒漏斗，而不是满屏缠绕丝线；
/// - 108 个轨道粒子按 `sin(angle)` 做前后景深：背面暗而小、正面亮而大，形成体积感；
/// - 粒子自地面向顶部缓慢上升并同步旋转，低频增强半径/转速，高频只点亮少量火花；
/// - 粒子种子为进程级静态表，每帧零随机、零列表分配。
class ParticleTornadoPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;
  final double lineWidth;

  static const int _particleCount = 108;
  static const int _groundCount = 24;
  static const int _strandCount = 3;
  static const int _strandSamples = 40;

  static const List<double> _strandPhases = [0.0, 2.09, 4.19];

  /// 粒子种子：[初始高度, 上升速度, 初始相位, 轨道速度, 径向抖动, 尺寸] × N
  static final List<double> _particleSeeds = _buildParticleSeeds();

  /// 地面尘种：[相位, 角速度, 半径系数, 尺寸] × N
  static final List<double> _groundSeeds = _buildGroundSeeds();

  final Paint _hazePaint = Paint()..style = PaintingStyle.fill;
  final Paint _conePaint = Paint()..style = PaintingStyle.fill;
  final Paint _strandPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _particlePaint = Paint()..style = PaintingStyle.fill;
  final Paint _groundPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.fill;
  final Path _strandPath = Path();
  final Path _conePath = Path();

  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  });

  static List<double> _buildParticleSeeds() {
    final rnd = math.Random(20251031);
    final out = List<double>.filled(_particleCount * 6, 0.0);
    for (var i = 0; i < _particleCount; i++) {
      final o = i * 6;
      out[o] = rnd.nextDouble(); // 初始高度 0 地面 → 1 顶部
      out[o + 1] = 0.022 + rnd.nextDouble() * 0.045; // 上升速度
      out[o + 2] = rnd.nextDouble() * math.pi * 2; // 初始相位
      out[o + 3] = 0.7 + rnd.nextDouble() * 0.7; // 轨道速度倍率
      out[o + 4] = 0.86 + rnd.nextDouble() * 0.28; // 径向抖动
      out[o + 5] = 0.7 + rnd.nextDouble() * 1.1; // 基础尺寸
    }
    return out;
  }

  static List<double> _buildGroundSeeds() {
    final rnd = math.Random(4481);
    final out = List<double>.filled(_groundCount * 4, 0.0);
    for (var i = 0; i < _groundCount; i++) {
      final o = i * 4;
      out[o] = rnd.nextDouble() * math.pi * 2;
      out[o + 1] = 0.5 + rnd.nextDouble() * 0.9;
      out[o + 2] = 1.0 + rnd.nextDouble() * 0.55;
      out[o + 3] = 0.8 + rnd.nextDouble() * 0.8;
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
    final treble = _avg((n * 3) ~/ 4, n);
    final minDim = math.min(w, h);

    final cx = w / 2.0;
    final baseY = h * 0.88;
    final maxR = minDim * (0.16 + bass * 0.07);
    final funnelH = h * (0.62 + bass * 0.06) * (1.0 + mid * 0.03);
    final sway = w * 0.018 * math.sin(t * 0.3);
    final spin = t * (1.1 + bass * 0.8);

    _drawGroundHaze(canvas, cx, baseY, maxR, minDim, bass);
    _drawCone(canvas, cx, baseY, maxR, funnelH, bass);
    _drawStrands(canvas, cx, baseY, maxR, funnelH, sway, spin, t);
    _drawGroundDust(canvas, cx, baseY, maxR, t, bass, treble);
    _drawParticles(
      canvas,
      cx,
      baseY,
      maxR,
      funnelH,
      sway,
      spin,
      t,
      n,
      bass,
      treble,
    );

    if (bloom > 0.05) {
      // 整体低频辉光：只对底部光池加一次模糊，不放大粒子噪声
      _glowPaint
        ..shader = RadialGradient(
          colors: [
            palette.glow.withValues(alpha: 0.08 + bloom * 0.16 + bass * 0.1),
            palette.glow.withValues(alpha: 0.0),
          ],
        ).createShader(
          Rect.fromCenter(
            center: Offset(cx, baseY),
            width: maxR * 3.2,
            height: minDim * 0.3,
          ),
        )
        // 渐变本身就有柔边，不再叠加每帧模糊图层
        ..maskFilter = null;
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, baseY),
          width: maxR * 3.2,
          height: minDim * 0.18,
        ),
        _glowPaint,
      );
    }
  }

  /// 底部光池：椭圆径向渐变，交代地面与中心落点
  void _drawGroundHaze(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double minDim,
    double bass,
  ) {
    _hazePaint.shader = RadialGradient(
      colors: [
        palette.secondary.withValues(alpha: 0.10 + bass * 0.16),
        palette.primary.withValues(alpha: 0.04 + bass * 0.06),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(
      Rect.fromCenter(
        center: Offset(cx, baseY),
        width: maxR * 3.4,
        height: minDim * 0.26,
      ),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, baseY),
        width: maxR * 3.4,
        height: minDim * 0.14,
      ),
      _hazePaint,
    );
  }

  /// 极淡的漏斗锥体：下窄上宽，仅提供轮廓 cohesion（透明度 3%~6%）
  void _drawCone(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double bass,
  ) {
    _conePath.reset();
    const samples = 18;
    for (var s = 0; s <= samples; s++) {
      final u = s / samples;
      final x = cx - maxR * _profile(u);
      final y = baseY - u * funnelH;
      if (s == 0) {
        _conePath.moveTo(x, y);
      } else {
        _conePath.lineTo(x, y);
      }
    }
    for (var s = samples; s >= 0; s--) {
      final u = s / samples;
      _conePath.lineTo(cx + maxR * _profile(u), baseY - u * funnelH);
    }
    _conePath.close();

    _conePaint.shader = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        palette.primary.withValues(alpha: 0.055 + bass * 0.03),
        palette.secondary.withValues(alpha: 0.02),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.6, 1.0],
    ).createShader(
      Rect.fromLTWH(cx - maxR, baseY - funnelH, maxR * 2, funnelH),
    );
    canvas.drawPath(_conePath, _conePaint);
  }

  /// 3 条合并绘制的螺旋导引线，底部亮、顶部渐隐
  void _drawStrands(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double sway,
    double spin,
    double t,
  ) {
    _strandPath.reset();
    for (var sIdx = 0; sIdx < _strandCount; sIdx++) {
      final phase = _strandPhases[sIdx];
      for (var k = 0; k <= _strandSamples; k++) {
        final u = k / _strandSamples;
        final angle = phase + spin + u * 8.0;
        final r = maxR * _profile(u) * (1.0 + 0.03 * math.sin(t * 0.6 + phase));
        final x = cx + sway * (1.0 - u) + math.cos(angle) * r;
        final y = baseY - u * funnelH + math.sin(angle) * r * 0.20;
        if (k == 0) {
          _strandPath.moveTo(x, y);
        } else {
          _strandPath.lineTo(x, y);
        }
      }
    }

    _strandPaint
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          palette.primary.withValues(alpha: 0.20),
          palette.secondary.withValues(alpha: 0.08),
          palette.glow.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(
        Rect.fromLTWH(cx - maxR, baseY - funnelH, maxR * 2, funnelH),
      )
      ..strokeWidth = lineWidth * 0.8;
    canvas.drawPath(_strandPath, _strandPaint);
  }

  /// 地面尘：绕基座旋转的扁椭圆尘环
  void _drawGroundDust(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double t,
    double bass,
    double treble,
  ) {
    for (var i = 0; i < _groundCount; i++) {
      final o = i * 4;
      final phase = _groundSeeds[o];
      final speed = _groundSeeds[o + 1];
      final radiusFactor = _groundSeeds[o + 2];
      final sizeSeed = _groundSeeds[o + 3];

      final angle = phase + t * speed * (0.6 + bass * 0.7);
      final radius = maxR * radiusFactor;
      final x = cx + math.cos(angle) * radius;
      final y = baseY + math.sin(angle) * radius * 0.24;
      final twinkle = 0.5 + 0.5 * math.sin(t * 1.8 + phase);

      _groundPaint.color = (i.isEven ? palette.secondary : palette.primary)
          .withValues(alpha: 0.08 + twinkle * 0.18 + treble * 0.06);
      canvas.drawCircle(
        Offset(x, y),
        sizeSeed * (0.7 + twinkle * 0.5),
        _groundPaint,
      );
    }
  }

  /// 轨道粒子：按深度分配透明度与尺寸，形成漏斗体积
  void _drawParticles(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double sway,
    double spin,
    double t,
    int n,
    double bass,
    double treble,
  ) {
    for (var i = 0; i < _particleCount; i++) {
      final o = i * 6;
      final u = (_particleSeeds[o] + t * _particleSeeds[o + 1]) % 1.0;
      final phase = _particleSeeds[o + 2];
      final orbitSpeed = _particleSeeds[o + 3];
      final radialJitter = _particleSeeds[o + 4];
      final sizeSeed = _particleSeeds[o + 5];

      final bandIdx = (u * (n - 1)).round().clamp(0, n - 1);
      final energy = bands[bandIdx];

      final angle = phase + spin * orbitSpeed + u * 8.0;
      final radius = maxR * _profile(u) * radialJitter;
      final depth = math.sin(angle); // -1 背面 → +1 正面
      final front = (depth + 1.0) * 0.5;
      final x = cx + sway * (1.0 - u) + math.cos(angle) * radius;
      final y = baseY - u * funnelH + depth * radius * 0.20;

      // 接近顶部时渐隐，避免漏斗口出现一圈硬边粒子
      final fadeTop = u > 0.88 ? ((1.0 - u) / 0.12).clamp(0.0, 1.0) : 1.0;
      final alpha = (0.06 + 0.52 * front) *
          fadeTop *
          (0.55 + energy * 0.7 + bass * 0.15);

      final size = sizeSeed *
          (0.7 + front * 1.4 + energy * 1.0) *
          (1.0 - 0.28 * u);

      // 亮粒子只用峰值色提亮，不再逐个加模糊滤镜（每帧上百个模糊图层会拖垮光栅）
      _particlePaint
        ..color = (i % 11 == 0
                ? palette.peak
                : (i % 4 == 0 ? palette.secondary : palette.primary))
            .withValues(alpha: i % 11 == 0 ? alpha + treble * 0.12 : alpha)
        ..maskFilter = null;
      canvas.drawCircle(Offset(x, y), math.max(0.6, size), _particlePaint);
    }
  }

  /// 漏斗半径剖面：底部 0.16 → 顶部 1.0
  double _profile(double u) => 0.16 + 0.84 * math.pow(u, 0.9).toDouble();

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
