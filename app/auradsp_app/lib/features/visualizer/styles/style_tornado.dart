import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 龙卷风：连续体积雾柱（2026-11-07 第三版，WMP 柔雾语言）
///
/// 视觉构成（全部围绕单一 `cx = size.width / 2` 中轴）：
/// - 底部：一片宽而浅的发光盘面（径向柔光，无描边）；
/// - 柱体：[_shellCount] 层嵌套的柔边轮廓壳，半径由外到内递减、
///   每层 alpha 极低（0.03~0.06），靠叠加自然形成「中间厚、边缘淡」的雾柱，
///   外缘没有任何硬边或描边；
/// - 表面：[_bandCount] 条半透明螺旋雾带，每条用 4 道不同线宽的同心描边
///   （alpha 递减）模拟柔边，随时间连续旋转，读起来是雾在转而不是粒子在跑；
/// - 顶部：宽开口的柔光；
/// - 点缀：[_starCount] 颗极小的高光星点，尺寸 1~2 px，数量克制；
/// - 泛光：一层大面积低 alpha 中段辉光。
///
/// 确定性 / 性能约定：
/// - 种子编译期固定（`Float32List`），运行期零随机、零装箱；
/// - 所有 Path / Paint 跨帧复用；径向光晕用单位圆 Shader + Canvas 变换，
///   只在亮度档变化时创建，不逐帧 createShader、不逐帧 blur；逐帧零分配
///   （`Offset` 走 `canvas.translate`）；
/// - 每帧 draw 调用 68 次：浅盘 2 + 壳层 16 + 雾带 6×4 + 顶口 1 +
///   星点 12×2 + 泛光 1。
class ParticleTornadoPainter extends CustomPainter
    implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  static const int _samples = 46;
  static const int _shellCount = 16;
  static const int _bandCount = 6;
  static const int _bandSamples = 38;
  static const int _starCount = 12;

  /// 每层壳的半径缩放：外 → 内，等间距铺满，避免相邻边界落差形成可见台阶。
  static final Float32List _shellScale = Float32List.fromList(
    List<double>.generate(
      _shellCount,
      (i) => 1.16 - 0.90 * (i / (_shellCount - 1)),
    ),
  );

  /// 每层壳的基础 alpha：内层略厚，但单层都极低，靠叠加成体积。
  static final Float32List _shellAlpha = Float32List.fromList(
    List<double>.generate(
      _shellCount,
      (i) => 0.0110 + 0.0390 * math.pow(i / (_shellCount - 1), 1.6).toDouble(),
    ),
  );

  /// 0 = primary，1 = secondary；交替叠色避免大面积纯色块。
  static final List<int> _shellColor =
      List<int>.generate(_shellCount, (i) => i.isEven ? 0 : 1);

  /// 雾带的 4 道同心描边宽度（相对 maxR）与 alpha。
  /// 宽度跨两个量级、alpha 快速衰减，叠加后没有可辨认的线条边界。
  static const List<double> _bandWidth = [0.28, 0.52, 0.82, 1.10];
  static const List<double> _bandAlpha = [0.060, 0.026, 0.0115, 0.0050];

  /// 每条雾带：[相位, 扭转率, 自转角速度, alpha 系数]
  static final Float32List _bandParams = Float32List.fromList(const [
    0.00, 6.4, 0.36, 0.90,
    1.05, 6.9, 0.41, 0.78,
    2.10, 7.4, 0.46, 1.00,
    3.14, 6.1, 0.51, 0.72,
    4.19, 7.8, 0.56, 0.86,
    5.24, 6.7, 0.61, 0.66,
  ]);

  /// 星点种子：[横向系数(-1.15~1.15), 高度(0.1~0.9), 尺寸(0.55~1.45), 闪烁相位]
  static final Float32List _starSeeds = _buildStarSeeds();

  final List<Path> _shellPaths =
      List<Path>.generate(_shellCount, (_) => Path());
  final List<Path> _bandPaths = List<Path>.generate(_bandCount, (_) => Path());

  final Paint _fillPaint = Paint()..style = PaintingStyle.fill;
  final Paint _bandPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _dotPaint = Paint()..style = PaintingStyle.fill;
  final Paint _glowPaint = Paint()..style = PaintingStyle.fill;

  /// 单位圆 Shader 缓存：key = 类型 + 亮度档。
  final Map<String, Shader> _shaderCache = {};

  static const int _alphaLevels = 48;
  final List<List<Color>> _alphaTables;

  double _lastTime = double.nan;
  double _smoothedBass = 0.0;
  double _pulse = 0.0;

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

  static Float32List _buildStarSeeds() {
    final rnd = math.Random(771103);
    final out = Float32List(_starCount * 4);
    for (var i = 0; i < _starCount; i++) {
      final o = i * 4;
      out[o] = (rnd.nextDouble() * 2 - 1) * 1.15;
      out[o + 1] = 0.10 + rnd.nextDouble() * 0.80;
      out[o + 2] = 0.55 + rnd.nextDouble() * 0.90;
      out[o + 3] = rnd.nextDouble() * math.pi * 2;
    }
    return out;
  }

  /// 漏斗母线：u=0 底部（浅盘外扩），u=0.10 腰部最细，u=1 顶部开口最宽。
  /// 通体自下而上连续外扩（锥形收束），底部只在最后 10% 轻微外翻，
  /// 保证读起来是「漏斗」而不是「花瓶」。
  static double _radiusAt(double u) {
    final body = 0.16 + 0.54 * math.pow(u, 1.10).toDouble();
    final cup = 0.12 *
        math.pow(math.max(0.0, (0.10 - u) / 0.10), 2.0).toDouble();
    return body + cup;
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
    _smoothedBass += (bass - _smoothedBass) * (dt * 4.0).clamp(0.0, 1.0);
    _pulse = math.max(bass, _pulse * math.exp(-dt * 5.0));

    // 单一中轴：整帧所有横向坐标都从这条线 ± 派生。
    final cx = w / 2.0;
    final baseY = h * 0.86;
    final funnelH = h * (0.60 + _pulse * 0.06) * (1.0 + mid * 0.04);
    final maxR = minDim * (0.24 + _pulse * 0.06) * (lineWidth / 1.5).clamp(0.85, 1.2);

    final bl = (_smoothedBass * 6).round().clamp(0, 6);
    final bq = bl / 6.0;

    _drawSaucer(canvas, cx, baseY, maxR, bl, bq);

    // 体积壳：外 → 内，alpha 逐层加厚，形成柔边雾柱（无硬轮廓）。
    for (var i = 0; i < _shellCount; i++) {
      _buildShell(i, cx, baseY, maxR, funnelH);
      final a = _shellAlpha[i] * (0.72 + bq * 0.62);
      _fillPaint.color = _colorAt(_shellColor[i], a);
      canvas.drawPath(_shellPaths[i], _fillPaint);
    }

    // 螺旋雾带：每条 4 道同心描边，alpha 递减 → 柔边；随时间连续旋转。
    final energy = (mid * 0.55 + treble * 0.45).clamp(0.0, 1.0);
    for (var b = 0; b < _bandCount; b++) {
      _buildBand(b, cx, baseY, maxR, funnelH, t);
      final mul = _bandParams[b * 4 + 3] * (0.55 + energy * 0.65);
      for (var p = 0; p < 4; p++) {
        _bandPaint
          ..strokeWidth = maxR * _bandWidth[p]
          ..color = _colorAt(
            b.isEven ? 0 : 1,
            _bandAlpha[p] * mul,
          );
        canvas.drawPath(_bandPaths[b], _bandPaint);
      }
    }

    _drawTopRim(canvas, cx, baseY, maxR, funnelH, bl, bq);
    _drawSparks(canvas, cx, baseY, maxR, funnelH, t);
    _drawBloom(canvas, cx, baseY, maxR, funnelH, bl, bq);
  }

  /// 底部浅盘：一层宽柔光 + 一枚亮核，叠出「收进发光盘面」的落点。
  void _drawSaucer(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    int bl,
    double bq,
  ) {
    final rx = maxR * 0.80 * (1.0 + _pulse * 0.10);
    final ry = rx * 0.27;
    _drawRadialBlob(
      canvas,
      cx,
      baseY,
      rx,
      ry,
      _radialShader(
        'saucer_$bl',
        [
          palette.secondary.withValues(alpha: 0.10 + bq * 0.11),
          palette.primary.withValues(alpha: 0.045 + bq * 0.05),
          palette.glow.withValues(alpha: 0.0),
        ],
        const [0.0, 0.48, 1.0],
      ),
    );
    _drawRadialBlob(
      canvas,
      cx,
      baseY,
      rx * 0.52,
      ry * 0.55,
      _radialShader(
        'saucerCore_$bl',
        [
          palette.peak.withValues(alpha: 0.20 + bq * 0.26),
          palette.primary.withValues(alpha: 0.10 + bq * 0.10),
          palette.primary.withValues(alpha: 0.0),
        ],
        const [0.0, 0.42, 1.0],
      ),
    );
  }

  /// 体积壳：闭合柔边轮廓。顶部用二次曲线做浅凹口，避免出现直线弦；
  /// 所有横向坐标都是 `cx ± r`，横向只由一个半径源派生。
  void _buildShell(
    int i,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
  ) {
    final path = _shellPaths[i]..reset();
    final scale = _shellScale[i];
    final wobble = 0.018 * math.sin(i * 1.7);

    double radius(double u) => maxR *
        _radiusAt(u) *
        scale *
        (1.0 + wobble * math.sin(u * 6.2 + i * 1.7));

    final yTop = baseY - funnelH;
    final rTop = radius(1.0);
    path.moveTo(cx - rTop, yTop);
    // 左缘：顶 → 底
    for (var k = 0; k <= _samples; k++) {
      final u = 1.0 - k / _samples;
      path.lineTo(cx - radius(u), baseY - u * funnelH);
    }
    // 底部横移到右缘，再右缘：底 → 顶
    for (var k = 0; k <= _samples; k++) {
      final u = k / _samples;
      path.lineTo(cx + radius(u), baseY - u * funnelH);
    }
    // 顶部凹口（浅弧），避免上口出现一条横贯直边
    path.quadraticBezierTo(cx, yTop + funnelH * 0.055, cx - rTop, yTop);
  }

  /// 螺旋雾带中心线：横向按 cos 摆动、纵向轻微起伏，绕中轴连续旋转。
  void _buildBand(
    int b,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double t,
  ) {
    final path = _bandPaths[b]..reset();
    final o = b * 4;
    final phase = _bandParams[o];
    final twist = _bandParams[o + 1];
    final spin = _bandParams[o + 2];

    for (var k = 0; k <= _bandSamples; k++) {
      final u = k / _bandSamples;
      final ang = phase + twist * u + t * spin;
      final r = maxR * _radiusAt(u) * 0.90;
      final x = cx + math.cos(ang) * r;
      final y = baseY - u * funnelH + math.sin(ang * 0.5) * funnelH * 0.012;
      if (k == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
  }

  void _drawTopRim(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    int bl,
    double bq,
  ) {
    final topR = maxR * _radiusAt(1.0);
    _drawRadialBlob(
      canvas,
      cx,
      baseY - funnelH,
      topR * 1.45,
      topR * 0.40,
      _radialShader(
        'topRim_$bl',
        [
          palette.primary.withValues(alpha: 0.09 + bq * 0.10),
          palette.secondary.withValues(alpha: 0.035 + bq * 0.04),
          palette.glow.withValues(alpha: 0.0),
        ],
        const [0.0, 0.50, 1.0],
      ),
    );
  }

  /// 稀疏星点：尺寸 1~2px，柔和大光晕 + 亮点核心，亮度随中高频轻微闪烁。
  void _drawSparks(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    double t,
  ) {
    for (var i = 0; i < _starCount; i++) {
      final o = i * 4;
      final x = cx + _starSeeds[o] * maxR * 1.15;
      final y = baseY - _starSeeds[o + 1] * funnelH;
      final s = _starSeeds[o + 2];
      final twinkle = 0.5 + 0.5 * math.sin(t * 1.15 + _starSeeds[o + 3]);
      canvas.save();
      canvas.translate(x, y);
      _dotPaint.color = _colorAt(0, 0.030 + 0.030 * twinkle);
      canvas.drawCircle(Offset.zero, 3.4 * s, _dotPaint);
      _dotPaint.color = _colorAt(2, 0.18 + 0.30 * twinkle);
      canvas.drawCircle(Offset.zero, 1.05 * s, _dotPaint);
      canvas.restore();
    }
  }

  void _drawBloom(
    Canvas canvas,
    double cx,
    double baseY,
    double maxR,
    double funnelH,
    int bl,
    double bq,
  ) {
    _drawRadialBlob(
      canvas,
      cx,
      baseY - funnelH * 0.42,
      maxR * (1.45 + bq * 0.10),
      funnelH * 0.40,
      _radialShader(
        'bloom_$bl',
        [
          palette.primary.withValues(alpha: 0.035 + bq * 0.040 + bloom * 0.020),
          palette.secondary.withValues(alpha: 0.018 + bq * 0.020),
          palette.glow.withValues(alpha: 0.0),
        ],
        const [0.0, 0.55, 1.0],
      ),
    );
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
    double cx,
    double cy,
    double rx,
    double ry,
    Shader shader,
  ) {
    _glowPaint.shader = shader;
    canvas.save();
    canvas.translate(cx, cy);
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

/// 龙卷风的静态基底：暗场渐变 + 轻微渐晕 + 地面辉光 + 中轴柔光。
///
/// 只随「调色板 / bloom / 画布尺寸」变化，与音频帧和时间无关；
/// 视口把它放进独立 `RepaintBoundary`（`willChange: false`），
/// 动态层每帧重绘不会让它失效。
class TornadoBackdropPainter extends CustomPainter {
  final VisualizerPalette palette;
  final double bloom;

  Paint? _bgPaint;
  Paint? _vignettePaint;
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

    // 轻微渐晕：中心透明、四周压暗，只作为暗场底噪。
    _vignettePaint = Paint()
      ..shader = RadialGradient(
        colors: const [
          Color(0x00000000),
          Color(0x12000000),
          Color(0x56000000),
        ],
        stops: const [0.0, 0.55, 1.0],
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

    // 中轴光柱用单位径向渐变 + 竖向拉伸，横向与纵向都自然淡出。
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
    canvas.drawRect(Offset.zero & size, _vignettePaint!);
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
