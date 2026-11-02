import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 粒子龙卷风：次世代三维流场涡旋视效（重构版）
///
/// 视觉特性：
/// 1. **立体俯视倾角投影**：引入 ~23° 俯仰角，水平旋转轨道展开为具纵深的椭圆，
///    顶部风眼斜向敞开，直视深邃涡核；
/// 2. **彻底摒弃廉价硬边界线条**：移除原有的玩具式侧影描边，完全由
///    半透明气旋体积锥光（Volumetric Core）、双螺旋对流光带（Streamlines）
///    以及粒子场自身密度构成自然的空气动力学流体边界；
/// 3. **惯性平滑自转**：废除瞬时低音直接乘绝对时间的阶跃算法，引入角速度
///    连续积分累加器，自转速度随低音有呼吸加速与惯性滑行，彻底消除抽搐抖动；
/// 4. **重构风眼与底部吸积盘**：由环境尘雾池、同心呼吸进动涡环（Accretion Rings）
///    与向心旋吸微粒轨迹共同构成富有科幻质感的气旋底盘；
/// 5. **双层多尺度粒子系统**：核心高速细粒子 + 外围带拖尾的螺旋尘粒，
///    配合严格的深度明暗投影（Depth Cueing），前后遮挡秩序井然。
class ParticleTornadoPainter extends CustomPainter
    implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  static const int _particleCount = 180;
  static const int _groundCount = 32;
  static const int _strandCount = 3;
  static const int _strandSamples = 52;
  static const double _pitchSin = 0.38; // sin(~22.3°) 俯视椭圆比例

  static const List<double> _strandPhases = [0.0, 2.094, 4.189];

  /// 静态自转积分器与平滑低频状态（跨帧保持平滑连续，永无相位突变）
  static double _lastTime = double.nan;
  static double _smoothedBass = 0.0;
  static double _spinAccumulator = 0.0;

  /// 粒子种子：[初始上升相位, 上升速度, 初始角度, 轨道速度, 半径系数, 尺寸, 尾长, 层次]
  static final List<double> _particleSeeds = _buildParticleSeeds();

  /// 地面吸积尘种：[初始半径, 初始角度, 螺旋向心速度, 尺寸, 闪烁相位]
  static final List<double> _groundSeeds = _buildGroundSeeds();

  final Paint _hazePaint = Paint()..style = PaintingStyle.fill;
  final Paint _conePaint = Paint()..style = PaintingStyle.fill;
  final Paint _strandPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _ringPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _particlePaint = Paint()..style = PaintingStyle.fill;
  final Paint _trailPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _groundPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.fill;
  final Path _strandPathFront = Path();
  final Path _strandPathBack = Path();
  final Path _conePath = Path();

  /// 着色器缓存：按 (Size, Palette, 量化档) 复用，杜绝逐帧产生 Skia C++ 对象
  static final Map<String, Shader> _shaderCache = {};

  static Shader _getOrCreateShader(String key, Shader Function() factory) {
    var s = _shaderCache[key];
    if (s == null) {
      if (_shaderCache.length > 48) {
        _shaderCache.clear();
      }
      s = factory();
      _shaderCache[key] = s;
    }
    return s;
  }


  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  });

  @override
  void setVisualizerTime(double time) => animationTime = time;

  static List<double> _buildParticleSeeds() {
    final rnd = math.Random(20261102);
    final out = List<double>.filled(_particleCount * 8, 0.0);
    for (var i = 0; i < _particleCount; i++) {
      final o = i * 8;
      final isCore = i < (_particleCount * 0.38); // 38% 核心涡流粒子
      out[o] = rnd.nextDouble(); // 初始上升相位 0~1
      out[o + 1] = isCore
          ? (0.035 + rnd.nextDouble() * 0.045) // 核心高速喷涌
          : (0.018 + rnd.nextDouble() * 0.032); // 外围悠然旋转
      out[o + 2] = rnd.nextDouble() * math.pi * 2; // 初始角度
      out[o + 3] = isCore
          ? (1.20 + rnd.nextDouble() * 0.60) // 核心高角速度
          : (0.80 + rnd.nextDouble() * 0.35); // 外围平缓轨道速度
      out[o + 4] = isCore
          ? (0.22 + rnd.nextDouble() * 0.35) // 紧贴涡核内部
          : (0.75 + rnd.nextDouble() * 0.35); // 外壁旋流
      out[o + 5] = isCore
          ? (0.55 + rnd.nextDouble() * 0.65) // 核心细密光点
          : (0.80 + rnd.nextDouble() * 1.30); // 外围主要尘团
      out[o + 6] = 0.012 + rnd.nextDouble() * 0.018; // 运动拖尾长度
      out[o + 7] = isCore ? 1.0 : 0.0; // 核心标记
    }
    return out;
  }

  static List<double> _buildGroundSeeds() {
    final rnd = math.Random(99317);
    final out = List<double>.filled(_groundCount * 5, 0.0);
    for (var i = 0; i < _groundCount; i++) {
      final o = i * 5;
      out[o] = 0.25 + rnd.nextDouble() * 1.15; // 半径乘数
      out[o + 1] = rnd.nextDouble() * math.pi * 2; // 角度
      out[o + 2] = 0.40 + rnd.nextDouble() * 0.85; // 轨道角速度
      out[o + 3] = 0.70 + rnd.nextDouble() * 1.10; // 尺寸
      out[o + 4] = rnd.nextDouble() * math.pi * 2; // 闪烁相位
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

    // 惯性平滑自转累加（杜绝每帧瞬态跃迁抖动）
    final dt = (!t.isFinite || !_lastTime.isFinite || t < _lastTime)
        ? 1.0 / 60.0
        : (t - _lastTime).clamp(0.001, 0.05);
    _lastTime = t;
    _smoothedBass += (bass - _smoothedBass) * (dt * 4.2).clamp(0.0, 1.0);
    _spinAccumulator += dt * (1.10 + _smoothedBass * 1.70);
    final spin = _spinAccumulator;

    final cx = w / 2.0;
    final baseY = h * 0.88;
    // 漏斗尺寸随低音平滑呼吸膨胀
    final maxR = minDim * (0.21 + _smoothedBass * 0.06);
    final funnelH = h * (0.64 + _smoothedBass * 0.06) * (1.0 + mid * 0.04);

    // 缓慢优雅的气流摆动中轴
    final sway = w * 0.015 * math.sin(t * 0.22);

    // 1. 底部风眼吸积盘与同心进动光环
    _drawEyeAccretionDisk(canvas, cx, baseY, maxR, minDim, _smoothedBass, sway);

    // 2. 气旋内壁对流光带（后半段：在背景锥光之前绘制，提供纵深包裹）
    _drawVortexRibbons(canvas, cx, baseY, maxR, funnelH, spin, t, sway, isFront: false);

    // 3. 柔和气旋体积雾锥体（无生硬线框，纯半透明发光流体）
    _drawVolumetricCone(canvas, cx, baseY, maxR, funnelH, _smoothedBass, sway);

    // 4. 地面旋吸微粒群
    _drawGroundIngestionDust(canvas, cx, baseY, maxR, t, spin, _smoothedBass, treble, sway);

    // 5. 气旋立体粒子场（带严格前后景深区分与运动拖尾）
    _drawVortexParticles(
      canvas,
      cx,
      baseY,
      maxR,
      funnelH,
      spin,
      t,
      n,
      _smoothedBass,
      treble,
      sway,
    );

    // 6. 气旋前半段对流光带（在粒子前方，增强立体包裹感）
    _drawVortexRibbons(canvas, cx, baseY, maxR, funnelH, spin, t, sway, isFront: true);

    // 7. 顶部深邃风眼口外沿呼吸微光
    _drawTopEyeMouthGlow(canvas, cx, baseY, maxR, funnelH, _smoothedBass, sway);

    // 8. 全局泛光（Shader 按尺寸与平滑低音 6 档量化缓存，杜绝逐帧分配）
    if (bloom > 0.05) {
      final bassLvl = (_smoothedBass * 5.0).round().clamp(0, 5);
      final glowRect = Rect.fromCenter(
        center: Offset(cx, baseY - funnelH * 0.35),
        width: maxR * 3.6,
        height: funnelH * 1.1,
      );
      _glowPaint.shader = _getOrCreateShader('glow_x__', () => RadialGradient(
        colors: [
          palette.glow.withValues(alpha: (0.06 + bloom * 0.14 + (bassLvl / 5.0) * 0.08)),
          palette.glow.withValues(alpha: 0.0),
        ],
      ).createShader(glowRect));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sway * 0.6, baseY - funnelH * 0.35),
          width: maxR * 3.6,
          height: funnelH * 1.1,
        ),
        _glowPaint,
      );
    }
  }

  /// 漏斗中轴：平滑 S 形流动摆动
  double _axisX(double cx, double sway, double u) =>
      cx + sway * math.pow(1.0 - u.clamp(0.0, 1.0), 1.6);

  /// 漏斗外廓剖面函数：底部精细风眼，上口广阔舒展
  double _profile(double u) {
    final clamped = u.clamp(0.0, 1.0);
    return 0.15 + 0.85 * math.pow(clamped, 0.90).toDouble();
  }

  /// 1. 底部风眼与同心进动吸积盘
  void _drawEyeAccretionDisk(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double minDim,
    double bass,
    double sway,
  ) {
    final center = Offset(cx + sway, baseY);

    final bassLvl = (bass * 5.0).round().clamp(0, 5);

    // a. 底部广域环境微光沉降池（Shader 复用）
    final hazeRect = Rect.fromCenter(center: Offset(cx, baseY), width: maxR * 3.8, height: minDim * 0.30);
    _hazePaint.shader = _getOrCreateShader('haze____', () => RadialGradient(
      colors: [
        palette.secondary.withValues(alpha: 0.16 + (bassLvl / 5.0) * 0.18),
        palette.primary.withValues(alpha: 0.06 + (bassLvl / 5.0) * 0.08),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.45, 1.0],
    ).createShader(hazeRect));
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: maxR * 3.8,
        height: maxR * 3.8 * _pitchSin,
      ),
      _hazePaint,
    );

    // b. 同心进动高能吸积环（三道不同半径的优雅椭圆环，Shader 复用）
    const ringMultipliers = [0.45, 0.85, 1.35];
    for (var ri = 0; ri < ringMultipliers.length; ri++) {
      final mul = ringMultipliers[ri] * (1.0 + (bassLvl / 5.0) * 0.06);
      final rw = maxR * mul;
      final rh = rw * _pitchSin;
      final ringAlpha = (0.12 - ri * 0.03 + (bassLvl / 5.0) * 0.10).clamp(0.02, 0.35);
      final ringRect = Rect.fromCenter(center: Offset(cx, baseY), width: rw, height: rh);

      _ringPaint
        ..shader = _getOrCreateShader('ring_____', () => SweepGradient(
          colors: [
            palette.primary.withValues(alpha: ringAlpha),
            palette.secondary.withValues(alpha: ringAlpha * 1.8),
            palette.primary.withValues(alpha: ringAlpha * 0.5),
            palette.primary.withValues(alpha: ringAlpha),
          ],
        ).createShader(ringRect))
        ..strokeWidth = (1.2 + (2 - ri) * 0.4) * (lineWidth / 1.5);

      canvas.drawOval(
        Rect.fromCenter(center: center, width: rw, height: rh),
        _ringPaint,
      );
    }

    // c. 风眼中心深邃极核（中央极度致密的高能焦点，Shader 复用）
    final coreR = maxR * (0.18 + (bassLvl / 5.0) * 0.05);
    final coreRect = Rect.fromCenter(center: Offset(cx, baseY), width: coreR * 2, height: coreR * 2 * _pitchSin);
    _hazePaint.shader = _getOrCreateShader('core____', () => RadialGradient(
      colors: [
        palette.peak.withValues(alpha: 0.30 + (bassLvl / 5.0) * 0.40),
        palette.primary.withValues(alpha: 0.12 + (bassLvl / 5.0) * 0.15),
        palette.primary.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.45, 1.0],
    ).createShader(coreRect));
    canvas.drawOval(
      Rect.fromCenter(center: center, width: coreR * 2, height: coreR * 2 * _pitchSin),
      _hazePaint,
    );
  }

  /// 2 & 6. 向心螺旋对流光带（前后分段绘制，消除玩具线条感）
  void _drawVortexRibbons(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double spin,
    double t,
    double sway, {
    required bool isFront,
  }) {
    final path = isFront ? _strandPathFront : _strandPathBack;
    path.reset();

    for (var sIdx = 0; sIdx < _strandCount; sIdx++) {
      final basePhase = _strandPhases[sIdx];
      var hasMove = false;

      for (var k = 0; k <= _strandSamples; k++) {
        final u = k / _strandSamples;
        // 螺线上升角度与轻度涡动
        final angle = basePhase + spin + u * 8.2 + 0.18 * math.sin(t * 0.4 + basePhase);
        final sinA = math.sin(angle);
        final depth = sinA; // >0 为前半球，<0 为后半球

        // 仅在属于当前半球时绘制连线，形成天然的空间穿插
        final belongs = isFront ? depth >= -0.05 : depth <= 0.05;
        if (!belongs) {
          hasMove = false;
          continue;
        }

        final cosA = math.cos(angle);
        final r = maxR * _profile(u) * (1.0 + 0.025 * math.sin(t * 0.7 + basePhase));
        final x = _axisX(cx, sway, u) + cosA * r;
        final y = baseY - u * funnelH + sinA * r * _pitchSin;

        if (!hasMove) {
          path.moveTo(x, y);
          hasMove = true;
        } else {
          path.lineTo(x, y);
        }
      }
    }

    final alphaBase = isFront ? 0.22 : 0.08;
    _strandPaint
      ..shader = _getOrCreateShader('strand____', () => LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          palette.secondary.withValues(alpha: alphaBase * 1.5),
          palette.primary.withValues(alpha: alphaBase),
          palette.glow.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.65, 1.0],
      ).createShader(
        Rect.fromLTWH(cx - maxR * 1.5, baseY - funnelH, maxR * 3.0, funnelH),
      ))
      ..strokeWidth = (isFront ? lineWidth * 1.1 : lineWidth * 0.7);

    canvas.drawPath(path, _strandPaint);
  }

  /// 3. 柔和气旋体积雾锥体（彻底消除侧影硬线条）
  void _drawVolumetricCone(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double bass,
    double sway,
  ) {
    _conePath.reset();

    const samples = 28;
    // 左外缘
    for (var s = 0; s <= samples; s++) {
      final u = s / samples;
      final axis = _axisX(cx, sway, u);
      final rx = maxR * _profile(u);
      final y = baseY - u * funnelH;
      if (s == 0) {
        _conePath.moveTo(axis - rx, y);
      } else {
        _conePath.lineTo(axis - rx, y);
      }
    }
    // 顶部风眼椭圆弧前沿
    for (var s = samples; s >= 0; s--) {
      final u = s / samples;
      final axis = _axisX(cx, sway, u);
      final rx = maxR * _profile(u);
      _conePath.lineTo(axis + rx, baseY - u * funnelH);
    }
    _conePath.close();

    final coneRect = Rect.fromLTWH(
      cx - maxR * 1.4,
      baseY - funnelH,
      maxR * 2.8,
      funnelH,
    );

    final coneBassLvl = (bass * 5.0).round().clamp(0, 5);
    // 核心微光体积填充：底部浓、上部自然淡出，两侧柔和衰减（Shader 复用）
    _conePaint.shader = _getOrCreateShader('cone____', () => LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        palette.primary.withValues(alpha: 0.09 + (coneBassLvl / 5.0) * 0.07),
        palette.secondary.withValues(alpha: 0.04 + (coneBassLvl / 5.0) * 0.03),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.55, 1.0],
    ).createShader(coneRect));

    canvas.drawPath(_conePath, _conePaint);
  }

  /// 4. 地面旋吸微粒群（向心螺旋进入风眼底部）
  void _drawGroundIngestionDust(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double t,
    double spin,
    double bass,
    double treble,
    double sway,
  ) {
    final centerX = cx + sway;
    for (var i = 0; i < _groundCount; i++) {
      final o = i * 5;
      final baseRadiusMul = _groundSeeds[o];
      final baseAngle = _groundSeeds[o + 1];
      final speed = _groundSeeds[o + 2];
      final sizeSeed = _groundSeeds[o + 3];
      final twinklePhase = _groundSeeds[o + 4];

      // 连续螺旋旋进动力学
      final angle = baseAngle + spin * 0.65 * speed + t * 0.45;
      final r = maxR * baseRadiusMul * (1.0 + bass * 0.12);
      final cosA = math.cos(angle);
      final sinA = math.sin(angle);

      final x = centerX + cosA * r;
      final y = baseY + sinA * r * _pitchSin;

      final depth = (sinA + 1.0) * 0.5; // 前景度
      final twinkle = 0.5 + 0.5 * math.sin(t * 2.2 + twinklePhase);

      final alpha = (0.04 + depth * 0.22 + twinkle * 0.10 + treble * 0.06)
          .clamp(0.0, 1.0);
      final pColor = (i % 3 == 0) ? palette.secondary : palette.primary;

      _groundPaint.color = pColor.withValues(alpha: alpha);
      canvas.drawCircle(
        Offset(x, y),
        sizeSeed * (0.65 + depth * 0.70 + bass * 0.20),
        _groundPaint,
      );
    }
  }

  /// 5. 气旋立体粒子场（带严格前后景深区分与运动拖尾）
  void _drawVortexParticles(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double spin,
    double t,
    int n,
    double bass,
    double treble,
    double sway,
  ) {
    for (var i = 0; i < _particleCount; i++) {
      final o = i * 8;
      final riseSeed = _particleSeeds[o];
      final riseSpeed = _particleSeeds[o + 1];
      final phase = _particleSeeds[o + 2];
      final orbitSpeed = _particleSeeds[o + 3];
      final radialFactor = _particleSeeds[o + 4];
      final sizeSeed = _particleSeeds[o + 5];
      final tailRise = _particleSeeds[o + 6];
      final isCore = _particleSeeds[o + 7] > 0.5;

      // 连续上升量（不回卷相位），首尾双向包络平滑淡入淡出
      final rise = riseSeed + t * riseSpeed;
      final u = rise % 1.0;

      final fadeIn = (u / 0.08).clamp(0.0, 1.0);
      final fadeOut = ((1.0 - u) / 0.12).clamp(0.0, 1.0);
      final envelope = fadeIn * fadeOut;
      if (envelope <= 0.001) continue;

      // 频段能量耦合
      final bandIdx = (u * (n - 1)).round().clamp(0, n - 1);
      final energy = bands[bandIdx];
      final energyNorm = energy.isFinite ? energy.clamp(0.0, 1.0) : 0.0;

      // 三维立体坐标旋转
      final angle = phase + spin * orbitSpeed + rise * 7.5 + 0.14 * math.sin(t * 0.5 + phase);
      final cosA = math.cos(angle);
      final sinA = math.sin(angle);
      final depth = sinA; // -1 背面 → +1 正面
      final front = (depth + 1.0) * 0.5;

      final r = maxR * _profile(u) * radialFactor * (1.0 + 0.04 * math.sin(t * 0.6 + phase));
      final x = _axisX(cx, sway, u) + cosA * r;
      // 俯视倾角投影关键：y 轴根据三维前后深度做真实倾斜偏移
      final y = baseY - u * funnelH + sinA * r * _pitchSin;

      // 深度着色：背面受体积雾遮挡变暗变小，正面更亮更大更通透
      final depthFade = isCore ? (0.35 + front * 0.65) : (0.15 + front * 0.85);
      final alpha = (envelope * depthFade * (0.45 + energyNorm * 0.65 + bass * 0.15))
          .clamp(0.0, 1.0);

      final size = sizeSeed *
          (isCore ? 1.0 : (0.65 + front * 0.85)) *
          (1.0 + energyNorm * 0.45);

      final color = isCore
          ? (i % 7 == 0 ? palette.peak : palette.secondary)
          : (i % 11 == 0
              ? palette.peak
              : (i % 3 == 0 ? palette.secondary : palette.primary));

      // 运动矢量拖尾绘制
      final tailU = (rise - tailRise) % 1.0;
      if (u > 0.03 && tailU < u) {
        final tailAngle = phase +
            spin * orbitSpeed +
            (rise - tailRise) * 7.5 +
            0.14 * math.sin(t * 0.5 + phase);
        final tailCosA = math.cos(tailAngle);
        final tailSinA = math.sin(tailAngle);
        final tailR = maxR * _profile(tailU) * radialFactor;
        final tailX = _axisX(cx, sway, tailU) + tailCosA * tailR;
        final tailY = baseY - tailU * funnelH + tailSinA * tailR * _pitchSin;

        _trailPaint
          ..color = color.withValues(alpha: alpha * 0.38)
          ..strokeWidth = math.max(0.7, size * 0.65);
        canvas.drawLine(Offset(tailX, tailY), Offset(x, y), _trailPaint);
      }

      // 核心微粒光点绘制
      _particlePaint.color = color.withValues(
        alpha: isCore ? (alpha * 1.15).clamp(0.0, 1.0) : alpha,
      );
      canvas.drawCircle(Offset(x, y), math.max(0.65, size), _particlePaint);
    }
  }

  /// 7. 顶部深邃风眼口外沿呼吸微光环
  void _drawTopEyeMouthGlow(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double bass,
    double sway,
  ) {
    final topAxis = _axisX(cx, sway, 1.0);
    final topCenter = Offset(topAxis, baseY - funnelH);
    final topR = maxR * _profile(1.0);
    final eyeRect = Rect.fromCenter(
      center: topCenter,
      width: topR * 2.0,
      height: topR * 2.0 * _pitchSin,
    );

    final eyeBassLvl = (bass * 5.0).round().clamp(0, 5);
    _ringPaint
      ..shader = _getOrCreateShader('topEye____', () => LinearGradient(
        colors: [
          palette.primary.withValues(alpha: 0.08 + (eyeBassLvl / 5.0) * 0.12),
          palette.secondary.withValues(alpha: 0.15 + (eyeBassLvl / 5.0) * 0.18),
          palette.glow.withValues(alpha: 0.04),
        ],
      ).createShader(eyeRect))
      ..strokeWidth = lineWidth * 0.85;

    canvas.drawOval(eyeRect, _ringPaint);
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
