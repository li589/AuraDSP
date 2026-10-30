import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';

/// 粒子龙卷风：确定性粒子漏斗（2026-10-31 重做）
///
/// 与旧实现的差异（对应反馈：锥体阴影与粒子不重叠 / 左右跳变 / 廉价感）：
/// 1. **统一中轴**：锥体、螺旋导引、粒子、地面尘共用 `_axisX(u)`（含摆动），
///    粒子横向位置由「实际高度处的锥面半径」推出，永远落在漏斗内；
/// 2. **消化周期回卷**：粒子的高度相位从 1 回卷到 0 时，角度不再突变——
///    角度里的螺旋项改用连续上升量，且首尾 6%/10% 做淡入淡出，回卷不可见；
/// 3. **运动拖尾**：每颗粒子额外画一段短拖尾（按前一时刻位置），形成速度感，
///    不再是漂浮的圆点；前后景只影响亮度/尺寸，纵向偏移极小，避免错位；
/// 4. 全部种子为进程级静态表：每帧零随机、零列表分配、零 MaskFilter。
class ParticleTornadoPainter extends CustomPainter {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double animationTime;
  final double lineWidth;

  static const int _particleCount = 150;
  static const int _groundCount = 26;
  static const int _strandCount = 3;
  static const int _strandSamples = 44;

  static const List<double> _strandPhases = [0.0, 2.09, 4.19];

  /// 粒子种子：[初始上升相位, 上升速度, 初始角度, 轨道速度, 半径抖动, 尺寸, 尾长]
  static final List<double> _particleSeeds = _buildParticleSeeds();

  /// 地面尘种：[初始角度, 角速度, 半径系数, 尺寸, 闪烁相位]
  static final List<double> _groundSeeds = _buildGroundSeeds();

  final Paint _hazePaint = Paint()..style = PaintingStyle.fill;
  final Paint _conePaint = Paint()..style = PaintingStyle.fill;
  final Paint _silhouettePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _strandPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _particlePaint = Paint()..style = PaintingStyle.fill;
  final Paint _trailPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _groundPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.fill;
  final Path _strandPath = Path();
  final Path _conePath = Path();
  final Path _leftSilhouette = Path();
  final Path _rightSilhouette = Path();

  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  });

  static List<double> _buildParticleSeeds() {
    final rnd = math.Random(20251031);
    final out = List<double>.filled(_particleCount * 7, 0.0);
    for (var i = 0; i < _particleCount; i++) {
      final o = i * 7;
      out[o] = rnd.nextDouble(); // 初始上升相位 0 地面 → 1 顶部
      out[o + 1] = 0.020 + rnd.nextDouble() * 0.040; // 上升速度
      out[o + 2] = rnd.nextDouble() * math.pi * 2; // 初始角度
      out[o + 3] = 0.75 + rnd.nextDouble() * 0.5; // 轨道速度倍率
      out[o + 4] = 0.78 + rnd.nextDouble() * 0.20; // 半径抖动（严格落在锥面内）
      out[o + 5] = 0.7 + rnd.nextDouble() * 1.0; // 基础尺寸
      out[o + 6] = 0.010 + rnd.nextDouble() * 0.014; // 拖尾时长（相位差）
    }
    return out;
  }

  static List<double> _buildGroundSeeds() {
    final rnd = math.Random(4481);
    final out = List<double>.filled(_groundCount * 5, 0.0);
    for (var i = 0; i < _groundCount; i++) {
      final o = i * 5;
      out[o] = rnd.nextDouble() * math.pi * 2;
      out[o + 1] = 0.45 + rnd.nextDouble() * 0.75;
      out[o + 2] = 1.0 + rnd.nextDouble() * 0.55;
      out[o + 3] = 0.8 + rnd.nextDouble() * 0.8;
      out[o + 4] = rnd.nextDouble() * math.pi * 2;
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
    final baseY = h * 0.9;
    final maxR = minDim * (0.17 + bass * 0.06);
    final funnelH = h * (0.66 + bass * 0.05) * (1.0 + mid * 0.03);

    // 缓慢的左右摆风：整条漏斗（含粒子与尘环）一起摆动，保证结构严丝合缝
    final sway = w * 0.016 * math.sin(t * 0.24);
    // 自转速度保持温和：过快会让粒子看起来像在乱跳
    final spin = t * (0.75 + bass * 0.45);

    _drawGroundHaze(canvas, cx, baseY, maxR, minDim, bass, sway);
    _drawCone(canvas, cx, baseY, maxR, funnelH, bass, sway);
    _drawStrands(canvas, cx, baseY, maxR, funnelH, spin, t, sway);
    _drawGroundDust(canvas, cx, baseY, maxR, t, bass, treble, sway);
    _drawParticles(
      canvas,
      cx,
      baseY,
      maxR,
      funnelH,
      spin,
      t,
      n,
      bass,
      treble,
      sway,
    );

    if (bloom > 0.05) {
      // 整体低频辉光：只对底部光池加一次渐变柔光，不放大粒子噪声
      _glowPaint
        ..shader = RadialGradient(
          colors: [
            palette.glow.withValues(alpha: 0.08 + bloom * 0.16 + bass * 0.1),
            palette.glow.withValues(alpha: 0.0),
          ],
        ).createShader(
          Rect.fromCenter(
            center: Offset(cx + sway, baseY),
            width: maxR * 3.2,
            height: minDim * 0.3,
          ),
        )
        ..maskFilter = null;
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sway, baseY),
          width: maxR * 3.2,
          height: minDim * 0.18,
        ),
        _glowPaint,
      );
    }
  }

  /// 漏斗中轴：底部 = 基座 + 摆动，顶部回到中心（越往上越稳定）
  double _axisX(double cx, double sway, double u) =>
      cx + sway * (1.0 - u) * (1.0 - u);

  /// 漏斗半径剖面：底部 0.16 → 顶部 1.0
  double _profile(double u) {
    final clamped = u.clamp(0.0, 1.0);
    return 0.16 + 0.84 * math.pow(clamped, 0.92).toDouble();
  }

  /// 底部光池：椭圆径向渐变，交代地面与中心落点
  void _drawGroundHaze(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double minDim,
    double bass,
    double sway,
  ) {
    final center = Offset(cx + sway, baseY);
    _hazePaint.shader = RadialGradient(
      colors: [
        palette.secondary.withValues(alpha: 0.10 + bass * 0.16),
        palette.primary.withValues(alpha: 0.04 + bass * 0.06),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(
      Rect.fromCenter(
        center: center,
        width: maxR * 3.4,
        height: minDim * 0.26,
      ),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: maxR * 3.4,
        height: minDim * 0.14,
      ),
      _hazePaint,
    );
  }

  /// 漏斗锥体：下窄上宽，轮廓与粒子共用同一中轴与半径剖面。
  /// 除极淡填充外再画两条侧影高光，避免看起来像一块平面梯形阴影。
  void _drawCone(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double bass,
    double sway,
  ) {
    _conePath.reset();
    _leftSilhouette.reset();
    _rightSilhouette.reset();

    const samples = 24;
    for (var s = 0; s <= samples; s++) {
      final u = s / samples;
      final axis = _axisX(cx, sway, u);
      final rx = maxR * _profile(u);
      final y = baseY - u * funnelH;
      final leftX = axis - rx;
      final rightX = axis + rx;
      if (s == 0) {
        _conePath.moveTo(leftX, y);
        _leftSilhouette.moveTo(leftX, y);
        _rightSilhouette.moveTo(rightX, y);
      } else {
        _conePath.lineTo(leftX, y);
        _leftSilhouette.lineTo(leftX, y);
        _rightSilhouette.lineTo(rightX, y);
      }
    }
    for (var s = samples; s >= 0; s--) {
      final u = s / samples;
      final axis = _axisX(cx, sway, u);
      final rx = maxR * _profile(u);
      _conePath.lineTo(axis + rx, baseY - u * funnelH);
    }
    _conePath.close();

    final rect = Rect.fromLTWH(
      cx - maxR * 1.2,
      baseY - funnelH,
      maxR * 2.4,
      funnelH,
    );
    _conePaint.shader = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        palette.primary.withValues(alpha: 0.07 + bass * 0.04),
        palette.secondary.withValues(alpha: 0.025),
        palette.glow.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.62, 1.0],
    ).createShader(rect);
    canvas.drawPath(_conePath, _conePaint);

    _silhouettePaint
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          palette.primary.withValues(alpha: 0.15 + bass * 0.07),
          palette.secondary.withValues(alpha: 0.06),
          palette.glow.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect)
      ..strokeWidth = lineWidth * 0.7;
    canvas.drawPath(_leftSilhouette, _silhouettePaint);
    canvas.drawPath(_rightSilhouette, _silhouettePaint);
  }

  /// 3 条合并绘制的螺旋导引线，底部亮、顶部渐隐；与粒子共用中轴
  void _drawStrands(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double spin,
    double t,
    double sway,
  ) {
    _strandPath.reset();
    for (var sIdx = 0; sIdx < _strandCount; sIdx++) {
      final phase = _strandPhases[sIdx];
      for (var k = 0; k <= _strandSamples; k++) {
        final u = k / _strandSamples;
        // 连续旋转 + 随高度缓慢扭转（不随高度回卷，避免首尾跳线）
        final angle = phase + spin + u * 7.5 + 0.25 * math.sin(t * 0.5 + phase);
        final r = maxR * _profile(u) * (1.0 + 0.03 * math.sin(t * 0.6 + phase));
        final x = _axisX(cx, sway, u) + math.cos(angle) * r;
        final y = baseY - u * funnelH + math.sin(angle) * r * 0.16;
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
          palette.primary.withValues(alpha: 0.16),
          palette.secondary.withValues(alpha: 0.06),
          palette.glow.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(
        Rect.fromLTWH(cx - maxR, baseY - funnelH, maxR * 2, funnelH),
      )
      ..strokeWidth = lineWidth * 0.7;
    canvas.drawPath(_strandPath, _strandPaint);
  }

  /// 地面尘：绕基座旋转的扁椭圆尘环（与漏斗同轴）
  void _drawGroundDust(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double t,
    double bass,
    double treble,
    double sway,
  ) {
    final centerX = cx + sway;
    for (var i = 0; i < _groundCount; i++) {
      final o = i * 5;
      final phase = _groundSeeds[o];
      final speed = _groundSeeds[o + 1];
      final radiusFactor = _groundSeeds[o + 2];
      final sizeSeed = _groundSeeds[o + 3];
      final twinklePhase = _groundSeeds[o + 4];

      final angle = phase + t * speed * (0.7 + bass * 0.5);
      final radius = maxR * radiusFactor;
      final x = centerX + math.cos(angle) * radius;
      final y = baseY + math.sin(angle) * radius * 0.22;
      // 尘环也要有前后景：背面更暗，增强地面包裹感
      final depth = (math.sin(angle) + 1.0) * 0.5;
      final twinkle = 0.5 + 0.5 * math.sin(t * 1.6 + twinklePhase);

      _groundPaint.color = (i.isEven ? palette.secondary : palette.primary)
          .withValues(alpha: 0.05 + depth * 0.16 + twinkle * 0.08 + treble * 0.04);
      canvas.drawCircle(
        Offset(x, y),
        sizeSeed * (0.6 + twinkle * 0.45) * (0.7 + depth * 0.5),
        _groundPaint,
      );
    }
  }

  /// 轨道粒子：连续上升 + 首尾淡入淡出 + 运动拖尾
  void _drawParticles(
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
      final o = i * 7;
      final riseSeed = _particleSeeds[o];
      final riseSpeed = _particleSeeds[o + 1];
      final phase = _particleSeeds[o + 2];
      final orbitSpeed = _particleSeeds[o + 3];
      final radialJitter = _particleSeeds[o + 4];
      final sizeSeed = _particleSeeds[o + 5];
      final tailRise = _particleSeeds[o + 6];

      // 连续上升量（不回卷）：角度项因此不会在顶部瞬间跳变
      final rise = riseSeed + t * riseSpeed;
      final u = rise % 1.0;

      // 首尾淡入淡出：回卷时粒子已几乎透明，肉眼看不到“瞬移”
      final fadeIn = (u / 0.06).clamp(0.0, 1.0);
      final fadeOut = ((1.0 - u) / 0.10).clamp(0.0, 1.0);
      final envelope = fadeIn * fadeOut;
      if (envelope <= 0.001) continue;

      final bandIdx = (u * (n - 1)).round().clamp(0, n - 1);
      final energy = bands[bandIdx];
      final energyNorm = energy.isFinite ? energy.clamp(0.0, 1.0) : 0.0;

      // 螺旋项用连续上升量：回卷后角度继续前进，不会左右跳
      final angle = phase +
          spin * orbitSpeed +
          rise * 7.2 +
          0.18 * math.sin(t * 0.45 + phase);
      final depth = math.sin(angle); // -1 背面 → +1 正面
      final front = (depth + 1.0) * 0.5;

      final baseHeightY = baseY - u * funnelH;
      // 纵向只做极小的景深偏移（旧实现用 radius*0.2，顶部会甩出锥体）
      final y = baseHeightY + depth * (1.0 - u) * 2.2;
      // 半径按“粒子实际所在高度”的锥面求，保证永远贴着漏斗轮廓
      final heightU = ((baseY - y) / funnelH).clamp(0.0, 1.0);
      final radius = maxR *
          _profile(heightU) *
          radialJitter *
          (1.0 + 0.035 * math.sin(t * 0.55 + phase));
      final x = _axisX(cx, sway, heightU) + math.cos(angle) * radius;

      final alpha = (0.08 + 0.56 * front) *
          envelope *
          (0.6 + energyNorm * 0.7 + bass * 0.12);
      final size = sizeSeed *
          (0.7 + front * 1.3 + energyNorm * 0.9) *
          (1.0 - 0.25 * u);

      final color = i % 11 == 0
          ? palette.peak
          : (i % 4 == 0 ? palette.secondary : palette.primary);

      // 拖尾：与粒子同一套几何，只是上升相位稍早、透明度更低
      final tailU = (rise - tailRise) % 1.0;
      if (u > 0.02 && tailU < u) {
        final tailBandIdx = (tailU * (n - 1)).round().clamp(0, n - 1);
        final tailEnergy = bands[tailBandIdx];
        final tailEnergyNorm =
            tailEnergy.isFinite ? tailEnergy.clamp(0.0, 1.0) : 0.0;
        final tailAngle = phase +
            spin * orbitSpeed +
            (rise - tailRise) * 7.2 +
            0.18 * math.sin(t * 0.45 + phase);
        final tailDepth = math.sin(tailAngle);
        final tailY = (baseY - tailU * funnelH) +
            tailDepth * (1.0 - tailU) * 2.2;
        final tailHeightU = ((baseY - tailY) / funnelH).clamp(0.0, 1.0);
        final tailRadius = maxR * _profile(tailHeightU) * radialJitter;
        final tailX =
            _axisX(cx, sway, tailHeightU) + math.cos(tailAngle) * tailRadius;

        _trailPaint
          ..color = color.withValues(
            alpha: (alpha * 0.34) * (0.5 + tailEnergyNorm * 0.5),
          )
          ..strokeWidth = math.max(0.8, size * 0.75);
        canvas.drawLine(Offset(tailX, tailY), Offset(x, y), _trailPaint);
      }

      _particlePaint
        ..color = color.withValues(
          alpha: i % 11 == 0 ? (alpha + treble * 0.1).clamp(0.0, 1.0) : alpha,
        )
        ..maskFilter = null;
      canvas.drawCircle(Offset(x, y), math.max(0.6, size), _particlePaint);
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
