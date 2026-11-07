import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 一张精灵图集里的一块子图。
///
/// 同时预存两种矩形，避免运行期逐帧构造 `Rect`：
/// - [srcRect] 图集内的采样区域；
/// - [localRect] 以子图中心为原点的本地矩形，配 `canvas.translate/scale`
///   使用，绘制后中心正好落在目标点。
class SpriteSlice {
  /// `[left, top, right, bottom]`，直接喂给 `Canvas.drawRawAtlas`。
  final Float32List rect;
  final double width;
  final double height;

  /// 子图中心（图集坐标），烘焙期使用。
  final double anchorX;
  final double anchorY;

  /// 预构造的 `Rect`（运行期零分配）。
  final Rect srcRect;
  final Rect localRect;

  const SpriteSlice._(
    this.rect,
    this.width,
    this.height,
    this.anchorX,
    this.anchorY,
    this.srcRect,
    this.localRect,
  );

  factory SpriteSlice(int left, int top, int width, int height) {
    final rect = Float32List.fromList(<double>[
      left.toDouble(),
      top.toDouble(),
      (left + width).toDouble(),
      (top + height).toDouble(),
    ]);
    final src = Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
    return SpriteSlice._(
      rect,
      width.toDouble(),
      height.toDouble(),
      left + width / 2.0,
      top + height / 2.0,
      src,
      Rect.fromLTWH(
        -width / 2.0,
        -height / 2.0,
        width.toDouble(),
        height.toDouble(),
      ),
    );
  }
}

/// 可视化柔光精灵图集（预烘焙，运行期只做采样）。
///
/// 性能背景（2026-11-07 实测）：`canvas.scale` + `RadialGradient` 的大面积
/// 半透明填充在 Impeller GL 上走通用矩阵路径，逐像素求值并大面积混合，
/// 是龙卷风/云流 CPU 与 GPU 的主要成本。因此所有柔光改为**启动时烘焙
/// 一次**的灰度精灵（白色 + 透明度），运行期只用位图采样。
///
/// 运行期两条绘制路径（都在目标机上验证过是「纹理 + 柔边」正确输出）：
/// 1. 需要逐实例 alpha / 颜色时：`canvas.translate/rotate/scale` +
///    `drawImageRect` + 预建 `Paint`（`ColorFilter.mode(color, modulate)`）；
/// 2. 星点这类可统一着色的元素：一次 `drawRawAtlas`（`colors` 参数传 null）。
///
/// 注意：本机渲染后端在 `drawAtlas/drawRawAtlas` 传入 `colors` 时会丢掉
/// 纹理 alpha（只剩纯色四边形），因此**不使用逐实例 colors**。
///
/// 不使用 `MaskFilter.blur`、不使用 `saveLayer`，不产生整屏离屏层。
///
/// 图集布局（1024×1024，透明底，白色密度）：
/// - blob        192×192 柔和圆斑
/// - blobWide    224×168 横向压扁的云
/// - blobTall    168×224 纵向拉长的云
/// - saucer      352×96  底部浅盘（宽高比 ≈ 3.67）
/// - puff        224×80  小团絮（不规则多瓣 + 细颗粒，高频湍流纹理来源）
/// - starDim     64×64 ×4 四档亮度星点（运行期按种子挑选，形成亮度分布）
/// - funnelWide  448×448 龙卷风外层锥体
/// - funnelCore  352×448 龙卷风内层亮锥
class VisualizerSpriteAtlas {
  static final VisualizerSpriteAtlas instance = VisualizerSpriteAtlas._();

  static const int _atlasSize = 1024;

  ui.Image? _image;

  final SpriteSlice blob = SpriteSlice(0, 0, 192, 192);
  final SpriteSlice blobWide = SpriteSlice(192, 0, 224, 168);
  final SpriteSlice blobTall = SpriteSlice(416, 0, 168, 224);
  final SpriteSlice saucer = SpriteSlice(0, 288, 352, 96);

  /// 小团絮（224×80，宽高比 2.8:1）：运行期按 30~135 px 贴到云体 / 锥面上，
  /// 缩放后 11~60 px，边缘不规则（不是椭圆也不是细线），
  /// 用来提供中高频湍流团块。
  final SpriteSlice puff = SpriteSlice(0, 192, 224, 80);

  /// 四档亮度：0.30 / 0.52 / 0.78 / 1.0（烘焙进峰值 alpha）。
  final List<SpriteSlice> starTiers = [
    SpriteSlice(352, 288, 64, 64),
    SpriteSlice(416, 288, 64, 64),
    SpriteSlice(480, 288, 64, 64),
    SpriteSlice(544, 288, 64, 64),
  ];

  final SpriteSlice funnelWide = SpriteSlice(0, 384, 448, 448);
  final SpriteSlice funnelCore = SpriteSlice(448, 384, 352, 448);

  ui.Image get image => _image ??= _bake();

  VisualizerSpriteAtlas._();

  /// 烘焙一次，之后跨帧、跨风格复用同一张纹理。
  ui.Image _bake() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    _bakeBlob(canvas, blob, 1.0);
    _bakeBlob(canvas, blobWide, 1.0);
    _bakeBlob(canvas, blobTall, 1.0);
    _bakeSaucer(canvas, saucer);
    _bakePuff(canvas, puff);
    const starPeaks = [0.30, 0.52, 0.78, 1.0];
    for (var i = 0; i < starTiers.length; i++) {
      _bakeStar(canvas, starTiers[i], starPeaks[i]);
    }
    _bakeFunnel(canvas, funnelWide, widthScale: 1.0);
    _bakeFunnel(canvas, funnelCore, widthScale: 0.72);

    final picture = recorder.endRecording();
    final image = picture.toImageSync(_atlasSize, _atlasSize);
    picture.dispose();
    return image;
  }

  /// 白色柔斑：径向衰减 + 若干低 alpha 小斑形成内部密度起伏（烘焙时一次算完）。
  void _bakeBlob(Canvas canvas, SpriteSlice slice, double strength) {
    final w = slice.width;
    final h = slice.height;
    canvas.save();
    canvas.translate(slice.anchorX, slice.anchorY);
    canvas.scale(w / 2.0, h / 2.0);
    canvas.drawCircle(
      Offset.zero,
      1.0,
      Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0xFFFFFFFF),
            Color(0xE6FFFFFF),
            Color(0xA8FFFFFF),
            Color(0x54FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.22, 0.45, 0.72, 1.0],
        ).createShader(const Rect.fromLTRB(-1, -1, 1, 1)),
    );
    canvas.restore();

    // 内部低 alpha 小斑：让云体近看有密度起伏，而不是一片均匀色块。
    // 两级：9 个大斑给低频起伏，36 个细斑给中高频颗粒（运行时云团被放大
    // 3~4 倍，细斑直径正好落在 8~25 px，读作「云里的颗粒」）。
    final rnd = math.Random(424242);
    final mottle = Paint();
    for (var i = 0; i < 69; i++) {
      final fine = i >= 9;
      // 大斑只能落在子图内部：半径过大 + 靠近边缘会被精灵矩形裁出一条
      // 直线边，放大后读成一块「矩形色斑」。半径与圆心同时收紧。
      final r = fine
          ? (0.010 + rnd.nextDouble() * 0.026) * w
          : (0.10 + rnd.nextDouble() * 0.14) * w;
      final span = fine ? 0.56 : 0.42;
      final cx = slice.rect[0] + (0.50 - span * 0.5 + rnd.nextDouble() * span) * w;
      final cy = slice.rect[1] + (0.50 - span * 0.5 + rnd.nextDouble() * span) * h;
      final a = (fine ? 0.075 : 0.14) * strength;
      mottle.shader = RadialGradient(
        colors: [
          Color.fromRGBO(255, 255, 255, a),
          const Color(0x00FFFFFF),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawCircle(Offset(cx, cy), r, mottle);
    }
  }

  /// 小团絮：一个柔边椭圆底 + 3 个低 alpha 小瓣 + 细颗粒。
  ///
  /// 关键是**不要做成长条**：细长椭圆缩下去会读成一道亮线（划痕感），
  /// 而多瓣叠加出来的不规则剪影才是「湍流团块」。
  void _bakePuff(Canvas canvas, SpriteSlice slice) {
    final w = slice.width;
    final h = slice.height;

    canvas.save();
    canvas.translate(slice.anchorX, slice.anchorY);
    canvas.scale(w / 2.0, h / 2.0);
    canvas.drawCircle(
      Offset.zero,
      1.0,
      Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0xB4FFFFFF),
            Color(0x6EFFFFFF),
            Color(0x2AFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.28, 0.62, 1.0],
        ).createShader(const Rect.fromLTRB(-1, -1, 1, 1)),
    );
    canvas.restore();

    final rnd = math.Random(2718281);
    final lobe = Paint();
    final ox = slice.rect[0];
    final oy = slice.rect[1];
    for (var i = 0; i < 3; i++) {
      // 瓣必须落在中心区、且 alpha 很低：强瓣 + 靠边会在剪影上叠出
      // 「M / Λ」形状，缩小旋转后读成字形而不是湍流。
      final cx = ox + w * (0.36 + rnd.nextDouble() * 0.28);
      final cy = oy + h * (0.40 + rnd.nextDouble() * 0.20);
      final r = (0.050 + rnd.nextDouble() * 0.040) * w;
      lobe.shader = RadialGradient(
        colors: [
          Color.fromRGBO(255, 255, 255, 0.05 + rnd.nextDouble() * 0.05),
          const Color(0x00FFFFFF),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawCircle(Offset(cx, cy), r, lobe);
    }

    // 细颗粒：让团絮内部也有分形感，缩到 30~135 px 时仍有颗粒。
    for (var i = 0; i < 18; i++) {
      final cx = ox + w * (0.18 + rnd.nextDouble() * 0.64);
      final cy = oy + h * (0.18 + rnd.nextDouble() * 0.64);
      final r = 1.0 + rnd.nextDouble() * 2.6;
      lobe.shader = RadialGradient(
        colors: [
          Color.fromRGBO(255, 255, 255, 0.06 + rnd.nextDouble() * 0.10),
          const Color(0x00FFFFFF),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawCircle(Offset(cx, cy), r, lobe);
    }
  }

  void _bakeSaucer(Canvas canvas, SpriteSlice slice) {
    canvas.save();
    canvas.translate(slice.anchorX, slice.anchorY);
    canvas.scale(slice.width / 2.0, slice.height / 2.0);
    canvas.drawCircle(
      Offset.zero,
      1.0,
      Paint()
        ..shader = RadialGradient(
          colors: const [
            Color(0xFFFFFFFF),
            Color(0xC0FFFFFF),
            Color(0x50FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.30, 0.66, 1.0],
        ).createShader(const Rect.fromLTRB(-1, -1, 1, 1)),
    );
    canvas.restore();
  }

  /// 星点：柔光晕 + 亮核。四档亮度共用同一形状，只是峰值 alpha 不同，
  /// 运行期按固定种子挑档，形成「多数微星、少数亮星」的自然分布。
  void _bakeStar(Canvas canvas, SpriteSlice slice, double peak) {
    final center = Offset(slice.anchorX, slice.anchorY);
    canvas.drawCircle(
      center,
      30,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.fromRGBO(255, 255, 255, 0.40 * peak),
            Color.fromRGBO(255, 255, 255, 0.11 * peak),
            const Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.42, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: 30)),
    );
    // 亮核外径固定 10px：运行期整图缩到 5~13px 时，核落在 0.8~2px。
    canvas.drawCircle(
      center,
      10,
      Paint()..color = Color.fromRGBO(255, 255, 255, peak),
    );

    // 十字光芒：参考图里的星点是「小花」而不是圆点，加两条 44px 长、
    // 两端渐隐的细芒，缩放后仍有 4 个尖，但不会变成雨点。
    final rayRect = Rect.fromCenter(center: center, width: 44, height: 44);
    final rayShader = LinearGradient(
      colors: [
        const Color(0x00FFFFFF),
        Color.fromRGBO(255, 255, 255, 0.32 * peak),
        const Color(0x00FFFFFF),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(rayRect);
    final rayPaintH = Paint()
      ..shader = rayShader
      ..blendMode = BlendMode.plus;
    final rayPaintV = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0x00FFFFFF),
          Color.fromRGBO(255, 255, 255, 0.32 * peak),
          const Color(0x00FFFFFF),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rayRect)
      ..blendMode = BlendMode.plus;
    canvas.drawRect(
      Rect.fromCenter(center: center, width: 44, height: 1.6),
      rayPaintH,
    );
    canvas.drawRect(
      Rect.fromCenter(center: center, width: 1.6, height: 44),
      rayPaintV,
    );
  }

  /// 龙卷风锥体：把锥面切成 1px 高的水平薄片逐片烘出来。
  ///
  /// 每片只画一条**横向柔边渐变**（边缘 alpha 0 → 中心 1），所以左右轮廓
  /// 是真正的柔边而不是多边形硬边；相邻薄片的半宽与 alpha 连续变化，
  /// 竖向看不出分层。顶部 32% 的 alpha 逐片衰减到 0，开口直接溶进暗场，
  /// 不需要 `dstIn` 裁剪，也不会读成「杯口」。
  ///
  /// 母线是**单调外扩**的干净锥形（底部最窄 → 顶部最宽），只在最底部 10%
  /// 轻微外翻收进浅盘；中段没有任何鼓起。
  void _bakeFunnel(
    Canvas canvas,
    SpriteSlice slice, {
    required double widthScale,
  }) {
    final w = slice.width;
    final h = slice.height;
    final cx = slice.anchorX;
    final topY = slice.rect[1];
    final baseY = slice.rect[1] + h * 0.94;
    final funnelH = baseY - topY;
    final maxR = w * 0.5 * widthScale;

    // 横向柔边：单位宽渐变，用 canvas.scale 拉到半宽，整张图只建一次 shader。
    final edgePaint = Paint()
      ..shader = LinearGradient(
        colors: const [
          Color(0x00FFFFFF),
          Color(0x8CFFFFFF),
          Color(0xFFFFFFFF),
          Color(0x8CFFFFFF),
          Color(0x00FFFFFF),
        ],
        stops: const [0.0, 0.20, 0.5, 0.80, 1.0],
      ).createShader(const Rect.fromLTRB(-1, -0.5, 1, 0.5));

    // 1px 一行、行与行**首尾相接不重叠**：重叠会让交叠处 alpha 翻倍，
    // 缩放后变成一道横向亮线（第一版 4px 行 + 0.58 半高就踩了这个坑）。
    // 行高取 1px 而不是 2px，是为了让 8bit alpha 的量化台阶小到看不出来。
    const step = 1.0;
    final steps = (funnelH / step).ceil();
    for (var i = 0; i < steps; i++) {
      final u = (i + 0.5) / steps;
      final y = baseY - u * funnelH;
      final halfW = maxR * radiusAt(u);

      // 竖向密度：底部略淡（融进浅盘）→ 中段最实 → 顶部 38% 渐隐到 0。
      var vert = 0.70 + 0.30 * u;
      if (u > 0.62) vert *= (1.0 - u) / 0.38;
      if (u < 0.10) vert *= 0.55 + 0.45 * (u / 0.10);

      edgePaint.colorFilter = ColorFilter.mode(
        Color.fromRGBO(255, 255, 255, vert),
        BlendMode.modulate,
      );

      canvas.save();
      canvas.translate(cx, y);
      canvas.scale(halfW, 1.0);
      canvas.drawRect(
        const Rect.fromLTRB(-1.0, -step * 0.5, 1.0, step * 0.5),
        edgePaint,
      );
      canvas.restore();
    }
  }

  /// 与运行期共用的锥体母线（u=0 底部，u=1 顶部）。
  ///
  /// 底部最窄、向上单调外扩；只在最底部 10% 轻微外翻收进浅盘，
  /// 中段没有任何鼓起，避免读成「花瓶」或「杯口」。
  static double radiusAt(double u) {
    final body = 0.14 + 0.62 * math.pow(u, 1.06).toDouble();
    final cup = 0.05 * math.pow(math.max(0.0, (0.10 - u) / 0.10), 2.0).toDouble();
    return body + cup;
  }
}
