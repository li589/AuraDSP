import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_time_aware.dart';

/// 星云流（Nebula Flow）：WMP 经典「柔雾星云」视觉语言（2026-11-07 重做）。
///
/// 构成：
/// - [_cloudCount] 团半透明云体，全部由**预建径向渐变 Shader** 拉伸成
///   椭圆精灵（1 次 `drawCircle`），边缘天生柔化，没有 MaskFilter、没有硬边；
/// - 云体运动只有低频：缓慢横向漂移 + 呼吸式膨胀；
///   高/中频只改变**亮度**（按档位换已缓存的 Shader），不改变轨迹，
///   因此不会把云抖成噪点；
/// - [_starCount] 颗稀疏星点，尺寸 1~3 px、柔光晕 + 亮点核，
///   亮度随中高频轻微闪烁，位置固定、不形成网格或串珠；
/// - 暗场与渐晕走 [_NebulaBackdropPainter]，由视口放进独立静态缓存层。
///
/// 确定性 / 性能约定：
/// - 种子编译期固定（`Float32List` + 固定 `math.Random`），运行期零随机；
/// - 所有 Paint 跨帧复用；Shader 按「颜色 × 亮度档」缓存，不逐帧 createShader；
/// - 逐帧分配为零（`Offset` 全部用 `canvas.translate`，无 Path / Paint /
///   Shader / Color 新建）；
/// - 每帧 draw 调用 83 次（10 幕布云 + 18×2 云团 + 1 中央柔光 + 18×2 星点）。
class NebulaFlowPainter extends CustomPainter implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;

  static const int _veilCount = 10;
  static const int _billowCount = 18;
  static const int _cloudCount = _veilCount + _billowCount;
  static const int _starCount = 18;

  /// 云体种子：每个 11 项
  /// [x, y, 半径, 横向漂移速度, 纵向漂移速度, 漂移相位,
  ///  呼吸相位, 呼吸速度, 颜色档(0~3), 纵向压扁系数, 类型(0=大幕布 1=云团)]
  static final Float32List _cloudSeeds = _buildCloudSeeds();

  /// 星点种子：每个 5 项 [x, y, 尺寸, 闪烁相位, 色档]
  static final Float32List _starSeeds = _buildStarSeeds();

  final Paint _cloudPaint = Paint()..style = PaintingStyle.fill;
  final Paint _starPaint = Paint()..style = PaintingStyle.fill;

  /// key = 色档 * 16 + 亮度档（整数键，避免逐帧字符串分配）。
  final Map<int, Shader> _shaderCache = {};

  /// 5 个基色的 alpha 查表：星点与泛光用查表取 Color，不逐帧 withValues。
  static const int _alphaLevels = 64;
  final List<List<Color>> _alphaTables;

  double _lastTime = double.nan;
  double _energy = 0.0;

  NebulaFlowPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
  }) : _alphaTables = _buildAlphaTables(palette);

  static List<List<Color>> _buildAlphaTables(VisualizerPalette palette) =>
      List.generate(5, (c) {
        final base = _baseColor(palette, c);
        return List<Color>.generate(
          _alphaLevels,
          (i) => base.withValues(alpha: i / (_alphaLevels - 1)),
        );
      });

  static Color _baseColor(VisualizerPalette palette, int slot) => switch (slot) {
        0 => palette.primary,
        1 => palette.secondary,
        2 => palette.gradient.isNotEmpty ? palette.gradient.first : palette.primary,
        3 => palette.gradient.length > 2 ? palette.gradient[2] : palette.secondary,
        _ => palette.glow,
      };

  Color _colorAt(int slot, double alpha) {
    final i = (alpha.clamp(0.0, 1.0) * (_alphaLevels - 1)).round();
    return _alphaTables[slot][i];
  }

  @override
  void setVisualizerTime(double time) => animationTime = time;

  static Float32List _buildCloudSeeds() {
    final rnd = math.Random(20261107);
    final out = Float32List(_cloudCount * 11);
    for (var i = 0; i < _cloudCount; i++) {
      final o = i * 11;
      final billow = i >= _veilCount;
      out[o] = (rnd.nextDouble() * 2 - 1) * 1.05;
      out[o + 1] = 0.04 + rnd.nextDouble() * 0.92;
      out[o + 2] = billow
          ? 0.14 + rnd.nextDouble() * 0.14
          : 0.30 + rnd.nextDouble() * 0.16;
      out[o + 3] = 0.05 + rnd.nextDouble() * 0.10;
      out[o + 4] = 0.03 + rnd.nextDouble() * 0.07;
      out[o + 5] = rnd.nextDouble() * math.pi * 2;
      out[o + 6] = rnd.nextDouble() * math.pi * 2;
      out[o + 7] = 0.09 + rnd.nextDouble() * 0.13;
      out[o + 8] = (rnd.nextDouble() * 4).floorToDouble().clamp(0, 3);
      out[o + 9] = 0.70 + rnd.nextDouble() * 0.55;
      out[o + 10] = billow ? 1.0 : 0.0;
    }
    return out;
  }

  static Float32List _buildStarSeeds() {
    final rnd = math.Random(771231);
    final out = Float32List(_starCount * 5);
    for (var i = 0; i < _starCount; i++) {
      final o = i * 5;
      out[o] = (rnd.nextDouble() * 2 - 1) * 0.94;
      out[o + 1] = 0.08 + rnd.nextDouble() * 0.84;
      out[o + 2] = 0.55 + rnd.nextDouble() * 0.85;
      out[o + 3] = rnd.nextDouble() * math.pi * 2;
      out[o + 4] = rnd.nextDouble() < 0.35 ? 1.0 : 0.0;
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
    final cx = w / 2.0;
    final cy = h / 2.0;

    final bass = _avg(0, math.max(1, n ~/ 8));
    final mid = _avg(n ~/ 4, n ~/ 2);
    final treble = _avg((n * 3) ~/ 4, n);

    final dt = (!t.isFinite || !_lastTime.isFinite || t < _lastTime)
        ? 1.0 / 30.0
        : (t - _lastTime).clamp(0.001, 0.1);
    _lastTime = t;
    // 亮度只在低频平滑，避免高频把云团闪成噪点。
    final target = (bass * 0.35 + mid * 0.40 + treble * 0.25).clamp(0.0, 1.0);
    _energy += (target - _energy) * (dt * 3.2).clamp(0.0, 1.0);

    // 低频缓慢漂移 + 呼吸膨胀；高频仅参与亮度（bucket）。
    final pulse = 1.0 + _energy * 0.10 + bass * 0.06;
    final fieldR = minDim * (0.62 + _energy * 0.10);

    for (var i = 0; i < _cloudCount; i++) {
      final o = i * 11;
      final billow = _cloudSeeds[o + 10] > 0.5;
      final spread = billow ? 0.78 : 1.06;
      final driftX =
          math.sin(t * _cloudSeeds[o + 3] + _cloudSeeds[o + 5]) * fieldR * 0.10;
      final driftY =
          math.cos(t * _cloudSeeds[o + 4] + _cloudSeeds[o + 5]) * fieldR * 0.06;
      final breathe =
          1.0 + 0.14 * math.sin(t * _cloudSeeds[o + 7] + _cloudSeeds[o + 6]);
      final x = cx + _cloudSeeds[o] * fieldR * spread + driftX;
      final y = cy + (_cloudSeeds[o + 1] - 0.5) * h * 1.02 + driftY;
      final r = minDim * _cloudSeeds[o + 2] * breathe * pulse;

      // 大幕布压得很淡铺满画面；云团更亮、更集中，负责可见的团块结构。
      // 亮度按 0~15 档量化进 Shader 缓存，同档复用同一份渐变。
      final strength = billow
          ? (0.18 + 0.92 * _energy) * (0.72 + 0.30 * breathe)
          : (0.22 + 0.55 * _energy);
      final bucket = (strength.clamp(0.0, 1.0) * 15).round();
      final slot = _cloudSeeds[o + 8].toInt();
      final aspect = _cloudSeeds[o + 9];
      final shader = _cloudShader(slot, bucket, billow);
      _drawCloud(canvas, x, y, r, r * aspect, shader);
      if (billow) {
        // 云团用两瓣错位叠加，剪影不再是标准圆/椭圆。
        final ang = _cloudSeeds[o + 5] + i * 0.73;
        final lx = x + math.cos(ang) * r * 0.44;
        final ly = y + math.sin(ang) * r * 0.34;
        _drawCloud(canvas, lx, ly, r * 0.70, r * 0.70 * aspect, shader);
      }
    }

    // 中央柔光：让云层有共同的光源，避免整屏平铺。
    _drawCloud(
      canvas,
      cx,
      cy * 0.86,
      fieldR * 0.86,
      fieldR * 0.60,
      _cloudShader(0, (18 + (_energy * 26).round()).clamp(0, 15), false),
    );

    _drawStars(canvas, w, h, t, treble);
  }

  /// 云体 Shader：颜色 × 亮度档 × 类型缓存。
  /// 单一色相 + 单调递减的通明度 profile（无中途换色），避免出现环状分层。
  Shader _cloudShader(int colorIdx, int bucket, bool billow) {
    final key = (billow ? 32 : 0) + colorIdx * 16 + bucket;
    var shader = _shaderCache[key];
    if (shader != null) return shader;
    if (_shaderCache.length > 128) _shaderCache.clear();
    final base = _baseColor(palette, colorIdx);
    final peak = billow
        ? 0.050 + 0.130 * (bucket / 15.0)
        : 0.028 + 0.060 * (bucket / 15.0);
    final p3 = billow ? peak * 0.56 : peak * 0.42;
    final p4 = billow ? peak * 0.22 : peak * 0.16;
    shader = RadialGradient(
      colors: [
        base.withValues(alpha: peak),
        base.withValues(alpha: peak * (billow ? 0.88 : 0.78)),
        base.withValues(alpha: p3),
        base.withValues(alpha: p4),
        base.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.24, 0.50, 0.78, 1.0],
    ).createShader(const Rect.fromLTRB(-1, -1, 1, 1));
    _shaderCache[key] = shader;
    return shader;
  }

  void _drawCloud(
    Canvas canvas,
    double cx,
    double cy,
    double rx,
    double ry,
    Shader shader,
  ) {
    _cloudPaint.shader = shader;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(rx, ry);
    canvas.drawCircle(Offset.zero, 1.0, _cloudPaint);
    canvas.restore();
    _cloudPaint.shader = null;
  }

  void _drawStars(Canvas canvas, double w, double h, double t, double treble) {
    final cx = w / 2.0;
    for (var i = 0; i < _starCount; i++) {
      final o = i * 5;
      final x = cx + _starSeeds[o] * w * 0.48;
      final y = _starSeeds[o + 1] * h;
      final s = _starSeeds[o + 2];
      final twinkle = 0.5 + 0.5 * math.sin(t * 1.05 + _starSeeds[o + 3]);
      final bright = (0.30 + 0.55 * treble) * (0.55 + 0.45 * twinkle);
      canvas.save();
      canvas.translate(x, y);
      _starPaint.color = _colorAt(_starSeeds[o + 4].toInt(), 0.028 + 0.05 * bright);
      canvas.drawCircle(Offset.zero, 2.6 * s, _starPaint);
      _starPaint.color = _colorAt(2, 0.12 + 0.42 * bright);
      canvas.drawCircle(Offset.zero, 0.9 * s, _starPaint);
      canvas.restore();
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
  bool shouldRepaint(covariant NebulaFlowPainter oldDelegate) => true;
}

/// 星云流的静态基底：暗场 + 轻微渐晕。
///
/// 只随「调色板 / bloom / 画布尺寸」变化，与音频帧和时间无关；
/// 视口把它放进独立 `RepaintBoundary`（`willChange: false`）。
class NebulaBackdropPainter extends CustomPainter {
  final VisualizerPalette palette;
  final double bloom;

  Paint? _bgPaint;
  Paint? _vignettePaint;
  Size? _shaderSize;

  NebulaBackdropPainter({required this.palette, required this.bloom});

  void _ensureShaders(Size size) {
    if (_bgPaint != null && _shaderSize == size) return;
    _shaderSize = size;
    _bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          palette.gradient.isNotEmpty
              ? palette.gradient.first.withValues(alpha: 0.030 + bloom * 0.02)
              : palette.primary.withValues(alpha: 0.03),
          palette.primary.withValues(alpha: 0.0),
          palette.secondary.withValues(alpha: 0.024 + bloom * 0.02),
        ],
        stops: const [0.0, 0.52, 1.0],
      ).createShader(Offset.zero & size);

    // 轻微渐晕：中心几乎透明，四周压暗，给云体一个「暗腔」。
    _vignettePaint = Paint()
      ..shader = RadialGradient(
        colors: const [
          Color(0x00000000),
          Color(0x14000000),
          Color(0x60000000),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Offset.zero & size);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _ensureShaders(size);
    canvas.drawRect(Offset.zero & size, _bgPaint!);
    canvas.drawRect(Offset.zero & size, _vignettePaint!);
  }

  @override
  bool shouldRepaint(covariant NebulaBackdropPainter oldDelegate) =>
      oldDelegate.palette != palette || oldDelegate.bloom != bloom;
}
