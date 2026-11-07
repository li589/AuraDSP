import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 镜像织带（Mirrored Weave）：Winamp / WMP 经典线条类视觉的确定性实现。
///
/// 观感目标：一条竖直中轴上，左右镜像的频谱折线环带持续上下流动，
/// 外层沉重、内层明亮，配合穿行的多边形频谱环与中心柔光，形成「有形体
/// 在变换线条、持续跑动」的经典观感，而不是粒子堆。
///
/// 对称性：整帧只有 `cx = size.width / 2` 一个横向中心源。每一行的左右
/// 顶点由同一对 `cx ± halfWidth` 生成，顶点集合天然镜像；没有任何按行
/// 或按层变化的横向偏置。环带与多边形环的顶点也都成对分布在 `cx` 两侧。
///
/// 性能约束：Path / Paint / Color 全部跨帧复用；每帧不创建 Shader、不做
/// blur、不用随机数；频谱只读、时间源仍是 30 Hz 主时间轴。
class MirrorWeavePainter extends CustomPainter implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double lineWidth;
  double animationTime;

  static const int _layers = 3;
  static const int _samples = 26;
  static const int _ringCount = 4;
  static const int _ringSides = 10;
  static const int _alphaLevels = 24;

  static const List<double> _layerScale = [1.0, 0.72, 0.46];
  static const List<double> _layerWidth = [1.55, 1.10, 0.75];

  final Paint _fillPaint = Paint()..style = PaintingStyle.fill;
  final Paint _strokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _glowPaint = Paint()..style = PaintingStyle.fill;

  final List<Path> _layerPaths =
      List<Path>.generate(_layers, (_) => Path());
  final List<Path> _ringPaths =
      List<Path>.generate(_ringCount, (_) => Path());
  final Path _rungPath = Path();
  final Path _spinePath = Path();

  final List<List<Color>> _alphaTables;
  final Map<String, Shader> _shaderCache = {};

  double _lastTime = double.nan;
  double _smoothedBass = 0.0;

  MirrorWeavePainter({
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

    // 单一中心源：所有左右顶点均由这条竖直线派生。
    final cx = w / 2.0;
    final top = h * 0.13;
    final bottom = h * 0.90;
    final span = bottom - top;
    final baseHalf = math.min(w * 0.235, minDim * 0.40);
    final bl = (_smoothedBass * 5).round().clamp(0, 5);

    _drawCenterGlow(canvas, cx, top + span * 0.5, baseHalf, span, bl, bass, mid);

    _drawTravelingRings(canvas, cx, top, span, baseHalf, t, n, bass, treble);

    for (var layer = 0; layer < _layers; layer++) {
      _buildLayer(_layerPaths[layer], layer, cx, top, span, baseHalf, t, n, bass, mid);
      _fillPaint.color = _colorAt(
        2,
        (0.015 + _smoothedBass * 0.025 + layer * 0.004).clamp(0.0, 1.0),
      );
      canvas.drawPath(_layerPaths[layer], _fillPaint);

      final baseColor = layer == 2 ? 2 : (layer == 1 ? 1 : 0);
      _strokePaint
        ..shader = null
        ..color = _colorAt(
          baseColor,
          (0.16 + layer * 0.10 + _smoothedBass * 0.22 + mid * 0.10)
              .clamp(0.0, 1.0),
        )
        ..strokeWidth = lineWidth * _layerWidth[layer];
      canvas.drawPath(_layerPaths[layer], _strokePaint);
    }

    // 横向织线：只在中层取样，把左右边缘缝合成「织带」质感。
    _buildRungs(cx, top, span, baseHalf, t, n, mid);
    _strokePaint
      ..shader = null
      ..color = _colorAt(
        2,
        (0.045 + treble * 0.10 + _smoothedBass * 0.06).clamp(0.0, 1.0),
      )
      ..strokeWidth = math.max(0.6, lineWidth * 0.45);
    canvas.drawPath(_rungPath, _strokePaint);

    _spinePath
      ..reset()
      ..moveTo(cx, top)
      ..lineTo(cx, bottom);
    _strokePaint
      ..shader = null
      ..color = _colorAt(
        1,
        (0.05 + _smoothedBass * 0.08).clamp(0.0, 1.0),
      )
      ..strokeWidth = math.max(0.6, lineWidth * 0.5);
    canvas.drawPath(_spinePath, _strokePaint);
  }

  double _bandAt(double u, int n) {
    if (n <= 0) return 0.0;
    final idx = (u.clamp(0.0, 1.0) * (n - 1)).round().clamp(0, n - 1);
    final e = bands[idx];
    return e.isFinite ? e.clamp(0.0, 1.0) : 0.0;
  }

  /// 闭环折线环带：左缘自上而下、右缘自下而上，左右顶点共用同一组 y，
  /// 且 x 只取 `cx ± halfWidth`，因此闭环轮廓关于中轴严格镜像。
  void _buildLayer(
    Path path,
    int layer,
    double cx,
    double top,
    double span,
    double baseHalf,
    double t,
    int n,
    double bass,
    double mid,
  ) {
    path.reset();
    final phase = layer * 1.85;
    final flow = 0.14 * math.sin(t * 0.42 + phase);
    for (var j = 0; j <= _samples; j++) {
      final u = j / _samples;
      final sampleU = (u + flow).clamp(0.0, 1.0);
      final energy = _bandAt(sampleU, n);
      final wave = math.sin(t * 1.05 - u * 5.2 + phase);
      final ripple = math.sin(t * 0.55 + u * 3.4 + phase * 0.7);
      final half = math.max(
        1.5,
        baseHalf *
            _layerScale[layer] *
            (0.18 + energy * 0.78 + 0.10 * wave + 0.04 * ripple),
      );
      final y = top +
          u * span +
          math.sin(t * 0.85 + u * 4.4 + phase) * span * 0.012;
      if (j == 0) {
        path.moveTo(cx - half, y);
      } else {
        path.lineTo(cx - half, y);
      }
    }
    for (var j = _samples; j >= 0; j--) {
      final u = j / _samples;
      final sampleU = (u + flow).clamp(0.0, 1.0);
      final energy = _bandAt(sampleU, n);
      final wave = math.sin(t * 1.05 - u * 5.2 + phase);
      final ripple = math.sin(t * 0.55 + u * 3.4 + phase * 0.7);
      final half = math.max(
        1.5,
        baseHalf *
            _layerScale[layer] *
            (0.18 + energy * 0.78 + 0.10 * wave + 0.04 * ripple),
      );
      final y = top +
          u * span +
          math.sin(t * 0.85 + u * 4.4 + phase) * span * 0.012;
      path.lineTo(cx + half, y);
    }
    path.close();
  }

  void _buildRungs(
    double cx,
    double top,
    double span,
    double baseHalf,
    double t,
    int n,
    double mid,
  ) {
    _rungPath.reset();
    final phase = 1.85; // 与中层一致
    final flow = 0.14 * math.sin(t * 0.42 + phase);
    for (var j = 2; j < _samples; j += 3) {
      final u = j / _samples;
      final sampleU = (u + flow).clamp(0.0, 1.0);
      final energy = _bandAt(sampleU, n);
      final wave = math.sin(t * 1.05 - u * 5.2 + phase);
      final half = math.max(
        1.5,
        baseHalf *
            _layerScale[1] *
            (0.18 + energy * 0.78 + 0.10 * wave),
      );
      final y = top + u * span + math.sin(t * 0.85 + u * 4.4 + phase) * span * 0.012;
      _rungPath
        ..moveTo(cx - half, y)
        ..lineTo(cx + half, y);
    }
  }

  /// 穿行的多边形频谱环：10 边形顶点左右成对，整体上下流动。
  void _drawTravelingRings(
    Canvas canvas,
    double cx,
    double top,
    double span,
    double baseHalf,
    double t,
    int n,
    double bass,
    double treble,
  ) {
    for (var k = 0; k < _ringCount; k++) {
      final u = (k / _ringCount + t * 0.14) % 1.0;
      final energy = _bandAt(u, n);
      final cy = top + u * span;
      final halfW = baseHalf *
          (0.95 + k * 0.03) *
          (0.12 + energy * 0.86) *
          (1.0 + 0.07 * math.sin(t * 1.4 + k));
      final halfH = span *
          0.042 *
          (0.65 + energy * 0.85) *
          (1.0 + 0.08 * math.sin(t * 1.1 + k * 1.7));
      final path = _ringPaths[k]..reset();
      for (var v = 0; v < _ringSides; v++) {
        final a = v / _ringSides * math.pi * 2;
        final x = cx + math.cos(a) * halfW;
        final y = cy + math.sin(a) * halfH;
        if (v == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();

      final fade = (1.0 - (u - 0.5).abs() * 0.9).clamp(0.25, 1.0);
      _strokePaint
        ..shader = null
        ..color = _colorAt(
          k.isEven ? 1 : 2,
          ((0.10 + energy * 0.34 + treble * 0.08) * fade).clamp(0.0, 1.0),
        )
        ..strokeWidth = lineWidth * (0.7 + energy * 0.55 + bass * 0.15);
      canvas.drawPath(path, _strokePaint);

      _fillPaint.color = _colorAt(
        k.isEven ? 0 : 1,
        ((0.010 + energy * 0.030) * fade).clamp(0.0, 1.0),
      );
      canvas.drawPath(path, _fillPaint);
    }
  }

  void _drawCenterGlow(
    Canvas canvas,
    double cx,
    double cy,
    double baseHalf,
    double span,
    int bl,
    double bass,
    double mid,
  ) {
    final shader = _radialShader(
      'weave_$bl',
      [
        palette.peak.withValues(
          alpha: (0.06 + bl / 5.0 * 0.12 + bass * 0.05).clamp(0.0, 1.0),
        ),
        palette.secondary.withValues(
          alpha: (0.03 + bl / 5.0 * 0.06).clamp(0.0, 1.0),
        ),
        palette.glow.withValues(alpha: 0.0),
      ],
      const [0.0, 0.48, 1.0],
    );
    _glowPaint.shader = shader;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(baseHalf * 1.35, span * 0.46);
    canvas.drawCircle(Offset.zero, 1.0, _glowPaint);
    canvas.restore();
    _glowPaint.shader = null;

    if (bloom > 0.4) {
      final outer = _radialShader(
        'weaveOuter_$bl',
        [
          palette.primary.withValues(
            alpha: ((bloom - 0.4) * 0.10 + mid * 0.03).clamp(0.0, 1.0),
          ),
          palette.glow.withValues(alpha: 0.0),
        ],
        const [0.0, 1.0],
      );
      _glowPaint.shader = outer;
      canvas.save();
      canvas.translate(cx, cy);
      canvas.scale(baseHalf * 2.0, span * 0.64);
      canvas.drawCircle(Offset.zero, 1.0, _glowPaint);
      canvas.restore();
      _glowPaint.shader = null;
    }
  }

  Shader _radialShader(String key, List<Color> colors, List<double> stops) {
    var shader = _shaderCache[key];
    if (shader == null) {
      if (_shaderCache.length > 24) _shaderCache.clear();
      shader = RadialGradient(colors: colors, stops: stops)
          .createShader(const Rect.fromLTRB(-1, -1, 1, 1));
      _shaderCache[key] = shader;
    }
    return shader;
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
  bool shouldRepaint(covariant MirrorWeavePainter oldDelegate) => true;
}
