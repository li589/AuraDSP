import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_sprite_atlas.dart';
import 'visualizer_time_aware.dart';

/// 龙卷风：连续体积雾柱（2026-11-07 第四版，预烘焙精灵版）。
///
/// 2026-11-07 实测：旧实现每帧用 `canvas.scale` + `RadialGradient` 画
/// 大面积半透明填充，单核 CPU 96.1%、GPU 28.7%、RSS 469MB。本版把柔光
/// 全部换成**启动时烘焙一次的锥体精灵**，运行期只做位图采样。
///
/// 绘制路径：
/// - 浅盘 / 锥体 / 雾絮：逐实例 `canvas.translate/rotate/scale` +
///   `drawImageRect` + 预建 `Paint` 池（`ColorFilter.mode(色, modulate)`），
///   颜色与 alpha 全在 Paint 池里，逐帧零分配；
/// - 星点：一次 `drawRawAtlas`（`colors` 传 null），四档烘焙亮度精灵按
///   固定种子挑选。
///
/// 注意：本机渲染后端在 `drawAtlas/drawRawAtlas` 传入逐实例 `colors`
/// 时会丢掉纹理 alpha（退化成纯色四边形），因此**不使用逐实例 colors**。
///
/// 构成：
/// - 底部浅盘 2 层（宽柔光 + 亮核），收进发光落点；
/// - 外层锥体 [funnelWide] + 内层亮锥 [funnelCore]：烘焙期由 1px 高的
///   水平薄片叠成，每片是一条横向柔边渐变，所以左右轮廓是真柔边；
///   母线单调外扩、中段没有鼓起，顶部 32% 的 alpha 逐片衰减到 0，
///   开口直接溶进暗场，不会读成「杯口」；
/// - [_wispCount] 枚小团絮（[VisualizerSpriteAtlas.puff]）按连续的 u
///   顺旋转方向贴到锥面，随时间连续旋转 + 高频抖动，叠出细密湍流纹理；
/// - [_starCount] 颗细小星点。
///
/// 确定性 / 性能约定：
/// - 种子编译期固定，运行期零随机；Paint 池与缓冲跨帧复用，逐帧零分配；
/// - 不逐帧 createShader / 新建 Image / saveLayer / MaskFilter.blur；
/// - 每帧 31 次 draw 调用（浅盘 2 + 锥体 2 + 细纹 26 + 星点 1）；静态暗场
///   仍走 [TornadoBackdropPainter] 的独立缓存层（`willChange: false`）。
class ParticleTornadoPainter extends CustomPainter
    implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  static const int _bandCount = 6;
  static const int _wispCount = 26;
  static const int _starCount = 44;

  /// 每条雾带：[相位, 扭转率, 自转角速度, alpha 系数]
  static final Float32List _bandParams = Float32List.fromList(const [
    0.00, 6.4, 0.36, 0.90,
    1.05, 6.9, 0.41, 0.78,
    2.10, 7.4, 0.46, 1.00,
    3.14, 6.1, 0.51, 0.72,
    4.19, 7.8, 0.56, 0.86,
    5.24, 6.7, 0.61, 0.66,
  ]);

  /// 星点种子：[横向系数(-1.12~1.12), 高度(0.1~0.9), 尺寸(0.55~1.45),
  /// 闪烁相位, 亮度权重]
  static final Float32List _starSeeds = _buildStarSeeds();

  static final Int32List _starTierOf = _buildStarTierOf();

  final VisualizerSpriteAtlas _atlas = VisualizerSpriteAtlas.instance;

  final Float32List _starRst = Float32List(_starCount * 4);
  final Float32List _starRects = Float32List(_starCount * 4);

  static const int _alphaLevels = 64;

  /// Paint 池：[slot * _alphaLevels + level]。
  final List<Paint> _paints;

  double _lastTime = double.nan;
  double _smoothedBass = 0.0;
  double _pulse = 0.0;

  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  }) : _paints = _buildPaintPool(palette) {
    _fillStarRects();
  }

  @override
  void setVisualizerTime(double time) => animationTime = time;

  static const int _slotCount = 3;

  static List<Paint> _buildPaintPool(VisualizerPalette palette) {
    final bases = [palette.primary, palette.secondary, palette.peak];
    final out = <Paint>[];
    for (var s = 0; s < _slotCount; s++) {
      final rgb = bases[s].toARGB32() & 0x00FFFFFF;
      for (var i = 0; i < _alphaLevels; i++) {
        final a = (i * 255 / (_alphaLevels - 1)).round();
        out.add(
          Paint()
            ..filterQuality = FilterQuality.low
            ..isAntiAlias = true
            ..colorFilter = ColorFilter.mode(
              Color((a << 24) | rgb),
              BlendMode.modulate,
            ),
        );
      }
    }
    return out;
  }

  Paint _paintAt(int slot, double alpha) {
    final i = (alpha.clamp(0.0, 1.0) * (_alphaLevels - 1)).round();
    return _paints[slot * _alphaLevels + i];
  }

  static Float32List _buildStarSeeds() {
    final rnd = math.Random(771103);
    final out = Float32List(_starCount * 5);
    for (var i = 0; i < _starCount; i++) {
      final o = i * 5;
      out[o] = (rnd.nextDouble() * 2 - 1) * 1.12;
      out[o + 1] = 0.10 + rnd.nextDouble() * 0.80;
      out[o + 2] = 0.55 + rnd.nextDouble() * 0.90;
      out[o + 3] = rnd.nextDouble() * math.pi * 2;
      out[o + 4] = math.pow(rnd.nextDouble(), 2.2).toDouble();
    }
    return out;
  }

  static Int32List _buildStarTierOf() {
    final out = Int32List(_starCount);
    for (var i = 0; i < _starCount; i++) {
      final w = _starSeeds[i * 5 + 4];
      out[i] = w < 0.20 ? 0 : (w < 0.55 ? 1 : (w < 0.85 ? 2 : 3));
    }
    return out;
  }

  SpriteSlice _starSliceAt(int tier) =>
      _atlas.starTiers[tier.clamp(0, _atlas.starTiers.length - 1)];

  void _fillStarRects() {
    for (var i = 0; i < _starCount; i++) {
      final s = _starSliceAt(_starTierOf[i]);
      final o = i * 4;
      _starRects[o] = s.rect[0];
      _starRects[o + 1] = s.rect[1];
      _starRects[o + 2] = s.rect[2];
      _starRects[o + 3] = s.rect[3];
    }
  }

  /// 画一个精灵实例：以中心对齐 `cx/cy`，等比缩放 + 旋转。
  void _sprite(Canvas canvas, SpriteSlice s, double cx, double cy,
      double scale, double rot, Paint paint) {
    canvas.save();
    canvas.translate(cx, cy);
    if (rot != 0.0) canvas.rotate(rot);
    canvas.scale(scale, scale);
    canvas.drawImageRect(_atlas.image, s.srcRect, s.localRect, paint);
    canvas.restore();
  }

  /// 漏斗母线（与烘焙精灵共用同一条曲线，雾絮才能准确贴在锥面上）。
  static double _radiusAt(double u) => VisualizerSpriteAtlas.radiusAt(u);

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
        ? 1.0 / 30.0
        : (t - _lastTime).clamp(0.001, 0.05);
    _lastTime = t;
    _smoothedBass += (bass - _smoothedBass) * (dt * 4.0).clamp(0.0, 1.0);
    _pulse = math.max(bass, _pulse * math.exp(-dt * 5.0));

    // 单一中轴：整帧所有横向坐标都从这条线 ± 派生。
    final cx = w / 2.0;
    final baseY = h * 0.86;
    final funnelH = h * (0.60 + _pulse * 0.06) * (1.0 + mid * 0.04);
    final maxR =
        minDim * (0.28 + _pulse * 0.06) * (lineWidth / 1.5).clamp(0.85, 1.2);

    final bl = (_smoothedBass * 6).round().clamp(0, 6);
    final bq = bl / 6.0;

    // 1) 底部浅盘：宽柔光 + 亮核。
    final saucerW = maxR * 1.90 * (1.0 + _pulse * 0.10);
    _sprite(canvas, _atlas.saucer, cx, baseY, saucerW / _atlas.saucer.width,
        0.0, _paintAt(1, 0.085 + 0.10 * bq));
    _sprite(canvas, _atlas.saucer, cx, baseY, (saucerW * 0.52) / _atlas.saucer.width,
        0.0, _paintAt(2, 0.16 + 0.22 * bq));

    // 2) 锥体：外层 + 内层。精灵的锥底在精灵内 94% 处，对齐 baseY。
    //    烘焙图本身已带「横向柔边 + 顶部渐隐」，这里只调制整体亮度。
    final funnelScale = funnelH / 448.0;
    final funnelCenterY = baseY - 448.0 * 0.94 * funnelScale * 0.5;
    _sprite(canvas, _atlas.funnelWide, cx, funnelCenterY, funnelScale, 0.0,
        _paintAt(0, 0.52 + 0.24 * bq));
    _sprite(canvas, _atlas.funnelCore, cx, funnelCenterY, funnelScale, 0.0,
        _paintAt(1, 0.40 + 0.22 * bq));

    // 3) 细纹：细长纤维贴到锥面，u 连续分布（不再按 3 行等距排列，
    //    避免出现横向条带），不同相位的高频抖动叠出湍流纹理。
    final energy = (mid * 0.55 + treble * 0.45).clamp(0.0, 1.0);
    for (var k = 0; k < _wispCount; k++) {
      final band = k % _bandCount;
      final o = band * 4;
      final phase = _bandParams[o];
      final twist = _bandParams[o + 1];
      final spin = _bandParams[o + 2];
      final jitter = math.sin(k * 12.9898) * 0.5 + 0.5;

      final u = (0.08 +
              0.84 * ((k + 0.5) / _wispCount) +
              math.sin(t * 0.55 + phase * 1.7) * 0.035)
          .clamp(0.05, 0.97);
      final ang = phase + twist * u + t * spin;
      // 贴面深度：团絮尺寸与偏移都按**局部半径**缩放，保证外缘不越出锥面
      // 剪影（尺寸固定会让底部窄处的团絮鼓出锥体外，读成「罗纹鼓起」）。
      final localR = maxR * _radiusAt(u);
      final rr = localR * (0.25 + 0.35 * jitter);
      final x = cx + math.cos(ang) * rr;
      final y = baseY - u * funnelH + math.sin(ang * 0.5) * funnelH * 0.010;

      // 团絮顺着旋转方向贴面（不是长条，避免读成划痕）；
      // 顶部随锥体一起渐隐，否则会有团絮戳出锥口。
      final topFade = u > 0.62 ? (1.0 - u) / 0.38 : 1.0;
      final rot = ang * 0.35 + 0.55;
      final mul = _bandParams[o + 3] * (0.55 + energy * 0.65);
      _sprite(canvas, _atlas.puff, x, y,
          (localR * 0.70) / _atlas.puff.width, rot,
          _paintAt(k.isEven ? 0 : 1, (0.12 * mul + 0.08 * bq) * topFade));
    }

    // 4) 星点：一次 drawRawAtlas 提交全部实例。
    final starAlpha = 0.35 + 0.65 * (0.30 + 0.70 * energy);
    for (var k = 0; k < _starCount; k++) {
      final o = k * 5;
      final x = cx + _starSeeds[o] * maxR * 1.55;
      final y = baseY - _starSeeds[o + 1] * funnelH;
      final twinkle = 0.5 + 0.5 * math.sin(t * 1.05 + _starSeeds[o + 3]);
      final size = (3.4 + _starSeeds[o + 2] * 5.6) * (0.85 + 0.15 * twinkle);
      final scale = size / 64.0;
      final r = k * 4;
      _starRst[r] = scale;
      _starRst[r + 1] = 0.0;
      _starRst[r + 2] = x - scale * 32.0;
      _starRst[r + 3] = y - scale * 32.0;
    }
    canvas.drawRawAtlas(
      _atlas.image,
      _starRst,
      _starRects,
      null,
      BlendMode.srcOver,
      null,
      _paintAt(2, starAlpha),
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
  bool shouldRepaint(covariant ParticleTornadoPainter oldDelegate) => true;
}

/// 龙卷风的静态基底：暗场渐变 + 轻微渐晕 + 地面辉光。
///
/// 只随「调色板 / bloom / 画布尺寸」变化，与音频帧和时间无关；
/// 视口把它放进独立 `RepaintBoundary`（`willChange: false`），
/// 动态层每帧重绘不会让它失效。
///
/// 2026-11-07：删掉原先的中轴竖光柱——它是一条 0.11×0.42 的拉伸径向渐变，
/// 在锥体外侧会读成一道竖直淡边线；锥体自身已有体积密度，不需要它。
class TornadoBackdropPainter extends CustomPainter {
  final VisualizerPalette palette;
  final double bloom;

  Paint? _bgPaint;
  Paint? _vignettePaint;
  Paint? _groundPaint;
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
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _ensureShaders(size);
    canvas.drawRect(Offset.zero & size, _bgPaint!);
    canvas.drawRect(Offset.zero & size, _vignettePaint!);
    final cx = size.width / 2.0;
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
