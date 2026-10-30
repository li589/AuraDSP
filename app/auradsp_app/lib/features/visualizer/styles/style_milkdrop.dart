import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import '../plugins/milkdrop_preset.dart';

/// Winamp MilkDrop 2 经典拓扑（2026-10-31 重做）
///
/// 反馈「有方向跳变」的根因：旧版星芒完全镜像对称——一个左右对称的图形在
/// 缓慢旋转时，人眼无法判断转向，能量快速变化时就像在原地乱跳；同心环则
/// 完全没有时间项，画面死板。现改为：
/// 1. 所有拓扑共用同一条**单调递增**的缓慢旋转角（约 0.3 rad/s，20s 一圈）；
/// 2. 星芒长度叠加非对称的三阶/七阶角向调制，旋转方向清晰可辨；
/// 3. 同心环变成随低频呼吸的波动环，绕轴缓慢旋进；
/// 4. 背景径向渐变之外再叠一层旋转的椭圆微光，整屏都有缓慢流动感。
/// 采样点为静态缓冲，每帧不分配 List。
class MilkdropPainter extends CustomPainter {
  final MilkdropPreset preset;
  final List<double> bands;
  final VisualizerPalette palette;
  final double time;
  final double sensitivity;
  final double lineWidth;

  static const int _spiralPoints = 96;
  static const int _ringSamples = 56;

  /// 螺旋路径采样坐标（x,y 交错存放），跨帧复用，避免每帧分配 List
  static final Float32List _spiralXY = Float32List((_spiralPoints + 1) * 2);

  final Path _strokePath = Path();
  final Paint _strokePaint = Paint()..style = PaintingStyle.stroke;

  MilkdropPainter({
    required this.preset,
    required this.bands,
    required this.palette,
    required this.time,
    required this.sensitivity,
    this.lineWidth = 1.5,
  });

  /// 缓慢且方向恒定的旋转角（rad）。所有拓扑共享，保证观感一致。
  double get _rotation => time * 0.30;

  /// 对称镜像连续采样：[0, 1) 映射为 0 -> 1 -> 0，消除环状结构首尾低频到高频的突变断开
  static double sampleMirroredEnergy(List<double> bands, double normPos) {
    if (bands.isEmpty) return 0.0;
    final mirrorU = 1.0 - (2.0 * (normPos % 1.0) - 1.0).abs();
    final floatIdx = mirrorU * (bands.length - 1);
    final i0 = floatIdx.floor();
    final i1 = math.min(i0 + 1, bands.length - 1);
    final frac = floatIdx - i0;
    // 余弦连续插值柔化
    final smoothFrac = (1.0 - math.cos(frac * math.pi)) / 2.0;
    return bands[i0] * (1.0 - smoothFrac) + bands[i1] * smoothFrac;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final cx = size.width / 2.0;
    final cy = size.height / 2.0;
    final baseRadius = math.min(cx, cy);

    // 提取三频能量 (Bass, Mid, Treble)
    var bass = 0.0, mid = 0.0, treble = 0.0;
    if (bands.length >= 16) {
      bass = ((bands[0] + bands[1] + bands[2] + bands[3]) / 4.0 * sensitivity)
          .clamp(0.0, 2.0);
      mid = ((bands[8] + bands[10] + bands[12]) / 3.0 * sensitivity)
          .clamp(0.0, 2.0);
      treble = ((bands[20] + bands[24] + bands[28]) / 3.0 * sensitivity)
          .clamp(0.0, 2.0);
    }

    // 1. 背景：径向衰减 + 缓慢旋转的椭圆微光（整屏都在动，不再是一张死底图）
    final zoomFactor = preset.zoom.clamp(0.8, 1.4) + bass * 0.08;
    final bgPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.9 * zoomFactor,
        colors: [
          palette.secondary
              .withValues(alpha: (0.12 * preset.decay + bass * 0.18).clamp(0.0, 0.6)),
          palette.primary.withValues(alpha: (0.05 * preset.decay).clamp(0.0, 0.4)),
          const Color(0x00000000),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final rot = _rotation;
    final shimmerBegin =
        Alignment(math.cos(rot) * 0.8, math.sin(rot) * 0.8);
    final shimmerEnd =
        Alignment(-math.cos(rot) * 0.8, -math.sin(rot) * 0.8);
    final shimmerPaint = Paint()
      ..shader = LinearGradient(
        begin: shimmerBegin,
        end: shimmerEnd,
        colors: [
          palette.primary.withValues(alpha: 0.05 + mid * 0.05),
          const Color(0x00000000),
          palette.secondary.withValues(alpha: 0.04 + bass * 0.04),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), shimmerPaint);

    // 2. 根据 Preset WaveMode 呈现不同 MilkDrop 经典拓扑
    switch (preset.waveMode % 3) {
      case 0:
        _paintConcentricVortex(canvas, cx, cy, baseRadius, bass, mid);
        break;
      case 1:
        _paintPolarSpiral(canvas, cx, cy, baseRadius, bass, mid, treble);
        break;
      case 2:
      default:
        _paintStarburstWarp(canvas, cx, cy, baseRadius, bass, mid);
        break;
    }
  }

  /// 波动同心环：半径随角度/低频呼吸变化，整组绕轴缓慢旋进
  void _paintConcentricVortex(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double bass,
    double mid,
  ) {
    const ringCount = 8;
    final rot = _rotation;
    for (var i = 0; i < ringCount; i++) {
      final frac = (i + 1) / ringCount;
      final baseR = r * frac * (0.62 + bass * 0.30);
      final wobble = baseR * (0.045 + mid * 0.06 + bass * 0.03);
      final phase = i * 0.75;
      final lobes = 3.0 + (i % 3);

      _strokePath.reset();
      for (var s = 0; s <= _ringSamples; s++) {
        final normPos = (s / _ringSamples) % 1.0;
        final theta = normPos * 2.0 * math.pi + rot * (0.6 + 0.08 * i);
        final energy = sampleMirroredEnergy(bands, normPos) * sensitivity;
        final radius = baseR +
            wobble *
                math.sin(theta * lobes + phase + rot * 0.8) +
            energy * 10.0 * frac;
        final x = cx + math.cos(theta) * radius;
        final y = cy + math.sin(theta) * radius;
        if (s == 0) {
          _strokePath.moveTo(x, y);
        } else {
          _strokePath.lineTo(x, y);
        }
      }
      _strokePath.close();

      final alpha =
          (0.16 + (1.0 - frac) * 0.5 * (0.5 + mid * 0.5)).clamp(0.0, 0.8);
      final color = Color.lerp(palette.primary, palette.secondary, frac)!;
      _strokePaint
        ..strokeWidth = lineWidth + bass * 2.0
        ..color = color.withValues(alpha: alpha);
      canvas.drawPath(_strokePath, _strokePaint);
    }
  }

  /// 极坐标螺旋：缓慢旋转 + 轻微角向调制，首尾用镜像能量保证闭合平滑
  void _paintPolarSpiral(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double bass,
    double mid,
    double treble,
  ) {
    final rot = _rotation * 1.3;
    for (var i = 0; i <= _spiralPoints; i++) {
      final normPos = (i / _spiralPoints) % 1.0;
      final theta = normPos * 2.0 * math.pi + rot;
      final energy = sampleMirroredEnergy(bands, normPos) * sensitivity;
      final dist = (0.35 + normPos * 0.45) * r +
          energy * 26.0 * (1.0 + bass) +
          r * 0.025 * math.sin(normPos * 2.0 * math.pi * 3.0 + rot * 1.1);
      _spiralXY[i * 2] = cx + dist * math.cos(theta);
      _spiralXY[i * 2 + 1] = cy + dist * math.sin(theta);
    }

    _strokePath.reset();
    _strokePath.moveTo(_spiralXY[0], _spiralXY[1]);
    for (var i = 1; i <= _spiralPoints; i++) {
      final midX = (_spiralXY[(i - 1) * 2] + _spiralXY[i * 2]) / 2.0;
      final midY = (_spiralXY[(i - 1) * 2 + 1] + _spiralXY[i * 2 + 1]) / 2.0;
      _strokePath.quadraticBezierTo(
        _spiralXY[(i - 1) * 2],
        _spiralXY[(i - 1) * 2 + 1],
        midX,
        midY,
      );
    }

    _strokePaint
      ..strokeWidth = lineWidth * 1.1 + treble * 1.8
      ..color = palette.primary.withValues(alpha: 0.85);
    canvas.drawPath(_strokePath, _strokePaint);
  }

  /// 缓慢旋转的星芒：非对称角向调制让旋转方向可辨（镜像对称会看起来像抖动）。
  /// 两层结构（长射线 + 短内芒）叠加，避免只有一圈细线显得单薄。
  void _paintStarburstWarp(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double bass,
    double mid,
  ) {
    const rays = 36;
    final rot = _rotation;

    // 中心柔光
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          palette.glow.withValues(alpha: 0.14 + bass * 0.12),
          palette.glow.withValues(alpha: 0.0),
        ],
      ).createShader(
        Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.42),
      );
    canvas.drawCircle(Offset(cx, cy), r * 0.42, glow);

    for (var i = 0; i < rays; i++) {
      final normPos = i / rays;
      final theta = normPos * 2.0 * math.pi;
      final angle = theta + rot;
      final amp = sampleMirroredEnergy(bands, normPos) * sensitivity;
      // 三阶 + 七阶角向调制：破除左右对称，人眼能清楚看到“在转”
      final asym = 1.0 +
          0.26 * math.sin(theta * 3.0 + rot * 1.2) +
          0.10 * math.sin(theta * 7.0 - rot * 0.9);
      _drawRay(canvas, cx, cy, angle, amp, asym, r,
          innerFactor: 0.22, outerFactor: 0.34, alphaScale: 1.0, bass: bass, mid: mid);

      // 短内芒：错开半格相位，速度略快，制造层次
      if (i.isEven) {
        final innerAngle = (i / rays) * 2.0 * math.pi + rot * 1.18 + 0.09;
        _drawRay(canvas, cx, cy, innerAngle, amp * 0.8, asym, r,
            innerFactor: 0.10,
            outerFactor: 0.22,
            alphaScale: 0.5,
            bass: bass,
            mid: mid);
      }
    }
  }

  void _drawRay(
    Canvas canvas,
    double cx,
    double cy,
    double angle,
    double amp,
    double asym,
    double r, {
    required double innerFactor,
    required double outerFactor,
    required double alphaScale,
    required double bass,
    required double mid,
  }) {
    final inner = r * innerFactor * (1.0 + mid * 0.4);
    final outer = r * (outerFactor + amp * 0.46 + bass * 0.2) * asym;
    final x1 = cx + inner * math.cos(angle);
    final y1 = cy + inner * math.sin(angle);
    final x2 = cx + outer * math.cos(angle);
    final y2 = cy + outer * math.sin(angle);
    final color = Color.lerp(
      palette.primary,
      palette.secondary,
      (angle / (2.0 * math.pi)) % 1.0,
    )!;
    _strokePaint
      ..strokeWidth = lineWidth * (0.9 + 0.4 * alphaScale)
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(
        alpha: ((0.32 + amp * 0.55) * alphaScale).clamp(0.0, 1.0),
      );
    canvas.drawLine(Offset(x1, y1), Offset(x2, y2), _strokePaint);
  }

  @override
  bool shouldRepaint(covariant MilkdropPainter oldDelegate) => true;
}
