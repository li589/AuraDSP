import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 粒子龙卷风：镜像对称的漏斗涡旋（2026-11-07 重做）
///
/// 对称性由单一中心源保证：整帧只有 `cx = size.width / 2` 一条竖直中轴，
/// 所有可见元素（漏斗轮廓、内芯光晕、对流光带、粒子、轨迹、地面尘、风眼）
/// 都围绕同一条轴生成，且横向坐标只以 `cx ± offset` 成对出现，没有任何
/// 随高度平移的横向偏移量，因此左右两半始终严格镜像。
///
/// 性能约束（与 30 Hz 时间轴 + P2-1 静态层口径一致）：
/// - 位置种子编译期固定（`Float32List`），运行期零随机、零装箱；
/// - 所有 Path / Paint 跨帧复用，只在参数变化时重建；
/// - 径向光晕使用单位圆 Shader + Canvas 变换，只按亮度档位缓存，
///   不逐帧 createShader、不逐帧 blur；
/// - 背景基底（暗场渐变 + 地面辉光 + 中轴光柱）交给独立静态层缓存，
///   动态层只画随音频变化的部分，`willChange: true`。
class ParticleTornadoPainter extends CustomPainter
    implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  /// 逻辑粒子「对」数：每对左右各一个，总点数 = 2 × 该值。
  static const int _pairCount = 84;
  static const int _groundPairCount = 20;
  static const int _ribbonPairCount = 3;
  static const int _ribbonSamples = 40;
  static const double _pitchSin = 0.52; // sin(~31°) 俯视椭圆压缩比

  static final Float32List _particleSeeds = _buildParticleSeeds();

  /// 地面吸积尘种：[半径系数, 角度, 角速度, 尺寸, 闪烁相位]
  static final Float32List _groundSeeds = _buildGroundSeeds();

  /// 三条对流光带的基准相位；左右镜像由绘制时 ±cos 保证，无需成对种子。
  static final Float32List _ribbonPhases =
      Float32List.fromList(const [0.55, 2.35, 4.15]);

  /// 每条光带的纵向扭转率刻意错开：若三者相同，sinA(u) 会在相同高度
  /// 同步穿过前后分界，叠成一片横向条纹；错开后才会互相穿插成编织感。
  static final Float32List _ribbonTwists =
      Float32List.fromList(const [5.2, 6.6, 8.1]);

  final Paint _fillPaint = Paint()..style = PaintingStyle.fill;
  final Paint _strokePaint = Paint()..style = PaintingStyle.stroke;
  final Paint _particlePaint = Paint()..style = PaintingStyle.fill;
  final Paint _trailPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _ringPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _glowPaint = Paint()..style = PaintingStyle.fill;

  final Path _pathOuter = Path();
  final Path _pathMid = Path();
  final Path _pathCore = Path();

  /// 外廓描边专用：只含左右两条母线，不闭合，避免在漏斗上口/根部
  /// 画出一条横贯的直线弦。
  final Path _pathOutline = Path();
  final Path _ribbonBack = Path();
  final Path _ribbonFront = Path();

  /// 单位圆 Shader 缓存：key = 类型 + 亮度档。颜色由调色板决定，
  /// 画笔实例随调色板/配置重建，因此实例内缓存不会串色。
  final Map<String, Shader> _shaderCache = {};

  static const int _alphaLevels = 32;
  static const int _cPrimary = 0;
  static const int _cSecondary = 1;
  static const int _cPeak = 2;
  final List<List<Color>> _alphaTables;

  /// 跨帧平滑状态（实例内持有，避免多个画笔实例共享静态量导致相位污染）。
  double _lastTime = double.nan;
  double _smoothedBass = 0.0;
  double _pulse = 0.0;
  double _spin = 0.0;

  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  }) : _alphaTables = List.generate(
          3,
          (c) => List<Color>.generate(
            _alphaLevels,
            (i) => [
              palette.primary,
              palette.secondary,
              palette.peak,
            ][c].withValues(alpha: i / (_alphaLevels - 1)),
          ),
        );

  @override
  void setVisualizerTime(double time) => animationTime = time;

  Color _colorAt(int base, double alpha) {
    final i = (alpha.clamp(0.0, 1.0) * (_alphaLevels - 1)).round();
    return _alphaTables[base][i];
  }

  static Float32List _buildParticleSeeds() {
    final rnd = math.Random(20261107);
    final out = Float32List(_pairCount * 8);
    for (var i = 0; i < _pairCount; i++) {
      final o = i * 8;
      final isCore = i < (_pairCount * 0.32);
      out[o] = rnd.nextDouble(); // 上升相位
      out[o + 1] = isCore
          ? 0.045 + rnd.nextDouble() * 0.050 // 内芯快速喷涌
          : 0.020 + rnd.nextDouble() * 0.030; // 外缘悠然上升
      out[o + 2] = rnd.nextDouble() * math.pi * 2; // 基准角度
      out[o + 3] = isCore
          ? 1.15 + rnd.nextDouble() * 0.55
          : 0.70 + rnd.nextDouble() * 0.35; // 角速度倍率
      out[o + 4] = isCore
          ? 0.16 + rnd.nextDouble() * 0.30 // 内芯紧贴涡核
          : 0.72 + rnd.nextDouble() * 0.40; // 外壁旋流
      out[o + 5] = isCore
          ? 0.55 + rnd.nextDouble() * 0.65
          : 1.05 + rnd.nextDouble() * 1.35;
      out[o + 6] = isCore ? 1.0 : 0.0;
      out[o + 7] = rnd.nextDouble(); // 颜色选择（量化后只用 0/1/2）
    }
    return out;
  }

  static Float32List _buildGroundSeeds() {
    final rnd = math.Random(99317);
    final out = Float32List(_groundPairCount * 5);
    for (var i = 0; i < _groundPairCount; i++) {
      final o = i * 5;
      out[o] = 0.30 + rnd.nextDouble() * 1.25;
      out[o + 1] = rnd.nextDouble() * math.pi * 2;
      out[o + 2] = 0.40 + rnd.nextDouble() * 0.80;
      out[o + 3] = 0.70 + rnd.nextDouble() * 1.05;
      out[o + 4] = rnd.nextDouble() * math.pi * 2;
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final n = bands.length;
    if (n == 0) return;

    final w = size.width;
    final h = size.height;
    final t = animationTime;
    final minDim = math.min(w, h);

    final bass = _avg(0, math.max(1, n ~/ 8));
    final mid = _avg(n ~/ 4, n ~/ 2);
    final treble = _avg((n * 3) ~/ 4, n);

    final dt = (!t.isFinite || !_lastTime.isFinite || t < _lastTime)
        ? 1.0 / 60.0
        : (t - _lastTime).clamp(0.001, 0.05);
    _lastTime = t;
    _smoothedBass += (bass - _smoothedBass) * (dt * 4.2).clamp(0.0, 1.0);
    _pulse = math.max(bass, _pulse * math.exp(-dt * 5.5));
    _spin += dt * (0.85 + _smoothedBass * 1.05 + _pulse * 1.35);

    // 单一中心源：整帧所有左右元素都从这条竖直线派生。
    final cx = w / 2.0;
    final baseY = h * 0.88;
    final maxR = minDim * (0.19 + _pulse * 0.07);
    final funnelH = h * (0.60 + _pulse * 0.09) * (1.0 + mid * 0.04);
    final scale = (minDim / 720.0).clamp(0.65, 2.0);

    final bl = (_smoothedBass * 6).round().clamp(0, 6);

    _drawEyeAccretionDisk(canvas, cx, baseY, maxR, _smoothedBass, bl);

    _buildRibbons(cx, baseY, maxR, funnelH, t, n, front: false);
    canvas.drawPath(_ribbonBack, _ribbonPaint(front: false));

    _drawParticleLayer(
      canvas,
      front: false,
      cx: cx,
      baseY: baseY,
      maxR: maxR,
      funnelH: funnelH,
      t: t,
      n: n,
      scale: scale,
      treble: treble,
    );

    // 三层嵌套漏斗：外缘 → 中层 → 内芯，半径递减、亮度递增，
    // 形成明确的漏斗轮廓与内芯层次。
    _buildFunnelPath(_pathOuter, cx, baseY, maxR, funnelH, 1.0, n);
    _buildFunnelPath(_pathMid, cx, baseY, maxR, funnelH, 0.70, n);
    _buildFunnelPath(_pathCore, cx, baseY, maxR, funnelH, 0.42, n);
    _buildFunnelOutline(_pathOutline, cx, baseY, maxR, funnelH, n);
    _fillPaint.color = _colorAt(
      _cPrimary,
      (0.045 + _smoothedBass * 0.075).clamp(0.0, 1.0),
    );
    canvas.drawPath(_pathOuter, _fillPaint);
    _fillPaint.color = _colorAt(
      _cSecondary,
      (0.050 + _smoothedBass * 0.085).clamp(0.0, 1.0),
    );
    canvas.drawPath(_pathMid, _fillPaint);
    _fillPaint.color = _colorAt(
      _cPrimary,
      (0.060 + _smoothedBass * 0.100).clamp(0.0, 1.0),
    );
    canvas.drawPath(_pathCore, _fillPaint);

    _drawCoreGlow(canvas, cx, baseY, maxR, funnelH, bl);

    _drawGroundIngestionDust(
      canvas,
      cx,
      baseY,
      maxR,
      t,
      _smoothedBass,
      treble,
      scale,
    );

    _buildRibbons(cx, baseY, maxR, funnelH, t, n, front: true);
    canvas.drawPath(_ribbonFront, _ribbonPaint(front: true));

    _drawParticleLayer(
      canvas,
      front: true,
      cx: cx,
      baseY: baseY,
      maxR: maxR,
      funnelH: funnelH,
      t: t,
      n: n,
      scale: scale,
      treble: treble,
    );

    // 外廓定形线：沿同一 `_pathOuter` 描边，让漏斗轮廓在暗场里也清晰可读。
    _strokePaint
      ..shader = null
      ..color = _colorAt(
        _cSecondary,
        (0.10 + _smoothedBass * 0.14).clamp(0.0, 1.0),
      )
      ..strokeWidth = lineWidth * 0.9;
    canvas.drawPath(_pathOutline, _strokePaint);

    _drawTopEye(canvas, cx, baseY, maxR, funnelH, _smoothedBass, bl);

    if (bloom > 0.05) {
      _drawBloom(canvas, cx, baseY, maxR, funnelH, bl);
    }
  }

  /// 高度 u（0=漏斗根部 → 1=顶部）对应的频带能量。
  double _bandAt(double u, int n) {
    if (n <= 0) return 0.0;
    final idx = (u.clamp(0.0, 1.0) * (n - 1)).round().clamp(0, n - 1);
    final e = bands[idx];
    return e.isFinite ? e.clamp(0.0, 1.0) : 0.0;
  }

  /// 漏斗外廓剖面：底部细风眼、上口舒展；指数 0.86 让轮廓微凹更像漏斗。
  double _profile(double u) {
    final c = u.clamp(0.0, 1.0);
    return 0.16 + 0.84 * math.pow(c, 0.86).toDouble();
  }

  void _buildFunnelPath(
    Path path,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double widthScale,
    int n,
  ) {
    path.reset();
    const samples = 26;
    for (var s = 0; s <= samples; s++) {
      final u = s / samples;
      final rx = maxR *
          _profile(u) *
          widthScale *
          (1.0 + _bandAt(u, n) * 0.17);
      final y = baseY - u * funnelH;
      if (s == 0) {
        path.moveTo(cx - rx, y);
      } else {
        path.lineTo(cx - rx, y);
      }
    }
    for (var s = samples; s >= 0; s--) {
      final u = s / samples;
      final rx = maxR *
          _profile(u) *
          widthScale *
          (1.0 + _bandAt(u, n) * 0.17);
      path.lineTo(cx + rx, baseY - u * funnelH);
    }
    path.close();
  }

  /// 漏斗外廓母线：左缘自上而下 + 右缘自下而上，不 close，
  /// 所以描边只勾左右轮廓，不会横穿上口或根部。
  void _buildFunnelOutline(
    Path path,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    int n,
  ) {
    path.reset();
    const samples = 26;
    for (var s = 0; s <= samples; s++) {
      final u = s / samples;
      final rx =
          maxR * _profile(u) * (1.0 + _bandAt(u, n) * 0.17);
      final y = baseY - u * funnelH;
      if (s == 0) {
        path.moveTo(cx - rx, y);
      } else {
        path.lineTo(cx - rx, y);
      }
    }
    for (var s = samples; s >= 0; s--) {
      final u = s / samples;
      final rx =
          maxR * _profile(u) * (1.0 + _bandAt(u, n) * 0.17);
      path.lineTo(cx + rx, baseY - u * funnelH);
    }
  }

  /// 对流光带：每条带在 +cos / -cos 两侧各画一份，横向坐标严格成对，
  /// 因此左右轮廓是同一组采样点的镜像。
  void _buildRibbons(
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double t,
    int n, {
    required bool front,
  }) {
    final path = front ? _ribbonFront : _ribbonBack;
    path.reset();
    for (var sIdx = 0; sIdx < _ribbonPairCount; sIdx++) {
      final basePhase = _ribbonPhases[sIdx];
      final twist = _ribbonTwists[sIdx];
      var started = false;
      for (var k = 0; k <= _ribbonSamples; k++) {
        final u = k / _ribbonSamples;
        final angle = basePhase +
            _spin * 0.90 +
            u * twist +
            0.16 * math.sin(t * 0.5 + basePhase);
        final sinA = math.sin(angle);
        final belongs = front ? sinA >= 0.0 : sinA < 0.0;
        if (!belongs) {
          started = false;
          continue;
        }
        final cosA = math.cos(angle);
        final r = maxR *
            _profile(u) *
            0.92 *
            (1.0 + _bandAt(u, n) * 0.20) *
            (1.0 + 0.02 * math.sin(t * 0.7 + basePhase));
        final y = baseY - u * funnelH + sinA * r * _pitchSin;
        final xR = cx + cosA * r;
        final xL = cx - cosA * r;
        if (!started) {
          path.moveTo(xR, y);
          path.moveTo(xL, y);
          started = true;
        } else {
          path.lineTo(xR, y);
          path.lineTo(xL, y);
        }
      }
    }
  }

  Paint _ribbonPaint({required bool front}) {
    _strokePaint
      ..shader = null
      ..color = _colorAt(
        front ? _cSecondary : _cPrimary,
        front
            ? (0.16 + _smoothedBass * 0.22).clamp(0.0, 1.0)
            : (0.07 + _smoothedBass * 0.10).clamp(0.0, 1.0),
      )
      ..strokeWidth = (front ? lineWidth * 1.25 : lineWidth * 0.80);
    return _strokePaint;
  }

  /// 粒子层：同一份种子画左右两个镜像点；先画背面、再画正面，
  /// 背面更暗更小，形成稳定的近亮远暗层次。
  void _drawParticleLayer(
    Canvas canvas, {
    required bool front,
    required double cx,
    required double baseY,
    required double maxR,
    required double funnelH,
    required double t,
    required int n,
    required double scale,
    required double treble,
  }) {
    for (var i = 0; i < _pairCount; i++) {
      final o = i * 8;
      final riseSeed = _particleSeeds[o];
      final riseSpeed = _particleSeeds[o + 1];
      final theta0 = _particleSeeds[o + 2];
      final orbitSpeed = _particleSeeds[o + 3];
      final radialFactor = _particleSeeds[o + 4];
      final sizeSeed = _particleSeeds[o + 5];
      final isCore = _particleSeeds[o + 6] > 0.5;
      final colorPick = _particleSeeds[o + 7];

      final rise = riseSeed + t * riseSpeed;
      final u = rise % 1.0;
      final fadeIn = (u / 0.07).clamp(0.0, 1.0);
      final fadeOut = ((1.0 - u) / 0.12).clamp(0.0, 1.0);
      final envelope = fadeIn * fadeOut;
      if (envelope <= 0.001) continue;

      final energy = _bandAt(u, n);
      final angle = theta0 +
          _spin * orbitSpeed +
          rise * 7.0 +
          0.12 * math.sin(t * 0.5 + theta0);
      final sinA = math.sin(angle);
      final belongs = front ? sinA >= 0.0 : sinA < 0.0;
      if (!belongs) continue;
      final cosA = math.cos(angle);
      final frontness = (sinA + 1.0) * 0.5;

      final r = maxR *
          _profile(u) *
          radialFactor *
          (1.0 + 0.035 * math.sin(t * 0.6 + theta0)) *
          (1.0 + energy * 0.10);
      final y = baseY - u * funnelH + sinA * r * _pitchSin;
      final xR = cx + cosA * r;
      final xL = cx - cosA * r;

      final depthFade = isCore ? (0.42 + frontness * 0.58) : (0.20 + frontness * 0.80);
      final alpha = (envelope *
              depthFade *
              (0.50 + energy * 0.45 + treble * 0.10 + _smoothedBass * 0.10))
          .clamp(0.0, 1.0);
      final size = math.max(
        0.7,
        sizeSeed *
            scale *
            (isCore ? 0.95 : (0.62 + frontness * 0.72)) *
            (1.0 + energy * 0.40),
      );

      final int baseColor;
      if (isCore) {
        baseColor = colorPick > 0.72 ? _cPeak : _cSecondary;
      } else {
        baseColor = colorPick > 0.86
            ? _cPeak
            : (colorPick > 0.42 ? _cSecondary : _cPrimary);
      }

      if (isCore && u > 0.05) {
        final tailRise = i.isEven ? 0.018 : 0.011;
        final tailValue = rise - tailRise;
        final tailU = tailValue % 1.0;
        if (tailU < u) {
          final tailAngle = theta0 +
              _spin * orbitSpeed +
              tailValue * 7.0 +
              0.12 * math.sin(t * 0.5 + theta0);
          final tailSin = math.sin(tailAngle);
          final tailCos = math.cos(tailAngle);
          final tailR = maxR * _profile(tailU) * radialFactor;
          final tailY = baseY - tailU * funnelH + tailSin * tailR * _pitchSin;
          final tailXR = cx + tailCos * tailR;
          final tailXL = cx - tailCos * tailR;
          _trailPaint
            ..color = _colorAt(baseColor, alpha * 0.34)
            ..strokeWidth = math.max(0.65, size * 0.60);
          canvas.drawLine(Offset(tailXR, tailY), Offset(xR, y), _trailPaint);
          canvas.drawLine(Offset(tailXL, tailY), Offset(xL, y), _trailPaint);
        }
      }

      _particlePaint.color = _colorAt(
        baseColor,
        isCore ? (alpha * 1.1).clamp(0.0, 1.0) : alpha,
      );
      canvas.drawCircle(Offset(xR, y), size, _particlePaint);
      canvas.drawCircle(Offset(xL, y), size, _particlePaint);
    }
  }

  /// 底部风眼吸积盘：所有环与核心都锁在同一条中轴 `cx` 上。
  void _drawEyeAccretionDisk(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double bass,
    int bl,
  ) {
    const ringMuls = [0.50, 0.95, 1.45];
    for (var ri = 0; ri < ringMuls.length; ri++) {
      final rw = maxR * ringMuls[ri] * (1.0 + bass * 0.08);
      final rh = rw * _pitchSin;
      final a = (0.10 - ri * 0.02 + bass * 0.13).clamp(0.02, 0.35);
      _ringPaint
        ..shader = null
        ..color = _colorAt(
          ri == 1 ? _cSecondary : _cPrimary,
          a,
        )
        ..strokeWidth = (1.1 + (2 - ri) * 0.35) * (lineWidth / 1.5);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, baseY), width: rw, height: rh),
        _ringPaint,
      );
    }

    final coreR = maxR * (0.20 + bass * 0.07);
    final shader = _radialShader(
      'eye_$bl',
      [
        palette.peak.withValues(alpha: 0.26 + bl / 6.0 * 0.30),
        palette.primary.withValues(alpha: 0.10 + bl / 6.0 * 0.14),
        palette.primary.withValues(alpha: 0.0),
      ],
      const [0.0, 0.45, 1.0],
    );
    _drawRadialBlob(
      canvas,
      Offset(cx, baseY),
      coreR,
      coreR * _pitchSin,
      shader,
    );
  }

  /// 内芯光晕层次：中段一团柔光 + 根部一团高光，沿同一中轴对称。
  void _drawCoreGlow(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    int bl,
  ) {
    final center = Offset(cx, baseY - funnelH * 0.42);
    final shader = _radialShader(
      'core_$bl',
      [
        palette.secondary.withValues(alpha: 0.12 + bl / 6.0 * 0.16),
        palette.primary.withValues(alpha: 0.05 + bl / 6.0 * 0.09),
        palette.glow.withValues(alpha: 0.0),
      ],
      const [0.0, 0.5, 1.0],
    );
    _drawRadialBlob(canvas, center, maxR * 0.70, funnelH * 0.55, shader);

    final near = Offset(cx, baseY - funnelH * 0.18);
    _drawRadialBlob(
      canvas,
      near,
      maxR * 0.46,
      funnelH * 0.26,
      _radialShader(
        'coreNear_$bl',
        [
          palette.peak.withValues(alpha: 0.10 + bl / 6.0 * 0.14),
          palette.primary.withValues(alpha: 0.05 + bl / 6.0 * 0.08),
          palette.primary.withValues(alpha: 0.0),
        ],
        const [0.0, 0.5, 1.0],
      ),
    );
  }

  /// 地面旋吸尘：左右成对，向心螺旋进入风眼。
  void _drawGroundIngestionDust(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double t,
    double bass,
    double treble,
    double scale,
  ) {
    for (var i = 0; i < _groundPairCount; i++) {
      final o = i * 5;
      final radiusMul = _groundSeeds[o];
      final baseAngle = _groundSeeds[o + 1];
      final speed = _groundSeeds[o + 2];
      final sizeSeed = _groundSeeds[o + 3];
      final twinklePhase = _groundSeeds[o + 4];

      final angle = baseAngle + _spin * 0.65 * speed + t * 0.45;
      final r = maxR * radiusMul * (1.0 + bass * 0.12);
      final cosA = math.cos(angle);
      final sinA = math.sin(angle);
      final y = baseY + sinA * r * _pitchSin;
      final xR = cx + cosA * r;
      final xL = cx - cosA * r;

      final frontness = (sinA + 1.0) * 0.5;
      final twinkle = 0.5 + 0.5 * math.sin(t * 2.2 + twinklePhase);
      final alpha = (0.035 + frontness * 0.20 + twinkle * 0.08 + treble * 0.10)
          .clamp(0.0, 1.0);
      _particlePaint.color = _colorAt(
        i % 4 == 0 ? _cSecondary : _cPrimary,
        alpha,
      );
      final size = sizeSeed * scale * (0.60 + frontness * 0.65 + bass * 0.18);
      canvas.drawCircle(Offset(xR, y), size, _particlePaint);
      canvas.drawCircle(Offset(xL, y), size, _particlePaint);
    }
  }

  /// 顶部风眼口：椭圆环 + 口部微光，中心严格落在 `cx`。
  void _drawTopEye(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double bass,
    int bl,
  ) {
    final topR = maxR * _profile(1.0);
    final center = Offset(cx, baseY - funnelH);
    final shader = _radialShader(
      'topEye_$bl',
      [
        palette.primary.withValues(alpha: 0.05 + bl / 6.0 * 0.08),
        palette.secondary.withValues(alpha: 0.04 + bl / 6.0 * 0.06),
        palette.glow.withValues(alpha: 0.0),
      ],
      const [0.0, 0.55, 1.0],
    );
    _drawRadialBlob(canvas, center, topR, topR * _pitchSin, shader);

    _ringPaint
      ..shader = null
      ..color = _colorAt(
        _cSecondary,
        (0.12 + bass * 0.16).clamp(0.0, 1.0),
      )
      ..strokeWidth = lineWidth * 0.95;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: topR * 2.0,
        height: topR * 2.0 * _pitchSin,
      ),
      _ringPaint,
    );
  }

  void _drawBloom(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    int bl,
  ) {
    final center = Offset(cx, baseY - funnelH * 0.35);
    final shader = _radialShader(
      'bloom_$bl',
      [
        palette.glow.withValues(
          alpha: (0.05 + bloom * 0.10 + bl / 6.0 * 0.08).clamp(0.0, 1.0),
        ),
        palette.glow.withValues(alpha: 0.0),
      ],
      const [0.0, 1.0],
    );
    _drawRadialBlob(canvas, center, maxR * 2.1, funnelH * 0.62, shader);
  }

  Shader _radialShader(
    String key,
    List<Color> colors,
    List<double> stops,
  ) {
    var shader = _shaderCache[key];
    if (shader == null) {
      if (_shaderCache.length > 64) _shaderCache.clear();
      shader = RadialGradient(colors: colors, stops: stops)
          .createShader(const Rect.fromLTRB(-1, -1, 1, 1));
      _shaderCache[key] = shader;
    }
    return shader;
  }

  void _drawRadialBlob(
    Canvas canvas,
    Offset center,
    double rx,
    double ry,
    Shader shader,
  ) {
    _glowPaint.shader = shader;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(rx, ry);
    canvas.drawCircle(Offset.zero, 1.0, _glowPaint);
    canvas.restore();
    _glowPaint.shader = null;
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

/// 龙卷风的静态基底：暗场渐变 + 地面辉光 + 竖直中轴光柱。
///
/// 这些内容只随「调色板 / bloom / 画布尺寸」变化，与音频帧和时间无关。
/// 视口把它放进独立 `RepaintBoundary`（`willChange: false`），光栅缓存
/// 可以长期保留；动态层每帧重绘不会让它失效。
class TornadoBackdropPainter extends CustomPainter {
  final VisualizerPalette palette;
  final double bloom;

  Paint? _bgPaint;
  Paint? _groundPaint;
  Paint? _axisPaint;
  Size? _shaderSize;

  TornadoBackdropPainter({required this.palette, required this.bloom});

  void _ensureShaders(Size size) {
    if (_bgPaint != null && _shaderSize == size) return;
    _shaderSize = size;
    final cx = size.width / 2.0;
    _bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          palette.primary.withValues(alpha: 0.015 + bloom * 0.02),
          palette.primary.withValues(alpha: 0.0),
          palette.secondary.withValues(alpha: 0.035 + bloom * 0.03),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Offset.zero & size);

    _groundPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          palette.secondary.withValues(alpha: 0.10 + bloom * 0.10),
          palette.primary.withValues(alpha: 0.035 + bloom * 0.04),
          palette.glow.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(
        Rect.fromCenter(
          center: Offset(cx, size.height * 0.88),
          width: size.width * 0.9,
          height: size.height * 0.32,
        ),
      );

    // 中轴光柱用单位径向渐变 + 竖向拉伸，横向与纵向都自然淡出，
    // 避免窄矩形线性渐变留下两条笔直的竖直硬边。
    _axisPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          palette.primary.withValues(alpha: 0.012 + bloom * 0.012),
          palette.primary.withValues(alpha: 0.008 + bloom * 0.008),
          palette.primary.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(const Rect.fromLTRB(-1, -1, 1, 1));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _ensureShaders(size);
    canvas.drawRect(Offset.zero & size, _bgPaint!);
    final cx = size.width / 2.0;
    canvas.save();
    canvas.translate(cx, size.height * 0.50);
    canvas.scale(size.width * 0.11, size.height * 0.42);
    canvas.drawCircle(Offset.zero, 1.0, _axisPaint!);
    canvas.restore();
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, size.height * 0.88),
        width: size.width * 0.9,
        height: size.height * 0.32,
      ),
      _groundPaint!,
    );
  }

  @override
  bool shouldRepaint(covariant TornadoBackdropPainter oldDelegate) =>
      oldDelegate.palette != palette || oldDelegate.bloom != bloom;
}
