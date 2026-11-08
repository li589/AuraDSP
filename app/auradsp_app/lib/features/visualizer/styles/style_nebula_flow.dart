import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_sprite_atlas.dart';
import 'visualizer_time_aware.dart';

/// 星云流（Nebula Flow）：WMP 经典「柔雾星云」视觉语言。
///
/// 2026-11-07 性能改造：所有云体/雾絮/星点改为**预烘焙精灵**。
/// 旧实现每帧用 `canvas.scale` + `RadialGradient` 画大面积极坐标填充，
/// 实测单核 CPU 96%、GPU 28.7%；换成位图采样后只剩纹理采样 + 混合。
///
/// 绘制路径（2026-11-07 内存修复后）：
/// - 云体 / 雾絮 / 星点**全部**走 `drawRawAtlas`：图集里只有「白色密度」，
///   颜色与 alpha 走逐实例 `colors` + `BlendMode.modulate`；颜色表是
///   构造期建好的 `Int32List`，逐帧只做整数索引，零分配。
/// - 逐实例 colors **必须**配 `BlendMode.modulate`：它是「纹理色 × 实例色」，
///   纹理 alpha 保留；配 `srcOver` 才会丢掉纹理 alpha、退化成纯色四边形
///   （旧版曾把 `srcOver` 的这个语义误判成「colors 不能用」）。
///
/// 为什么不用 `Paint.colorFilter = ColorFilter.mode(...)`：
/// 混合模式色彩滤镜在 Impeller 上是 `ColorFilterContents`，无法内联进片元
/// 着色器，每次带滤镜的绘制都要开一个离屏子 pass 纹理；本样式每帧 100+ 次
/// 精灵绘制，纹理池因此常驻数百 MB（实测 RSS 829 MB、GPU Shared 527 MB，
/// 且均值≈峰值——是渲染目标常驻，不是渐进泄漏）。顶点色属于图集绘制本身，
/// **不开任何离屏层**。
///
/// 构成：
/// - [_veilCount] 张大幕布云，铺满画面做低频云底；
/// - [_billowCount] 个云团，每个两瓣错位叠加，剪影不是标准椭圆；
/// - 1 枚中央柔光，让云层有共同光源；
/// - [_wispCount] 枚小团絮（[VisualizerSpriteAtlas.puff]），
///   宽 30~105 px、高 11~38 px，低 alpha 的不规则剪影 + 内部细颗粒，
///   高频错位 + 缓慢旋转，给云体叠出肉眼可辨的湍流纹理；
/// - [_starCount] 颗细小星点，尺寸 5.5~12 px（带十字芒）、亮核 0.9~1.9 px。
///
/// 确定性 / 性能约定：
/// - 种子编译期固定（`Float32List` + 固定 `math.Random`），运行期零随机；
/// - 颜色表、顶点缓冲、实例色缓冲都在构造期分配、跨帧复用，逐帧堆分配为零；
/// - 不逐帧 createShader / 新建 Image / 使用 saveLayer / MaskFilter.blur；
/// - 运行期**没有 ColorFilter、没有 ImageShader、没有 Paint 池**，全样式零离屏层；
/// - 每帧 **2 次** draw 调用：云体+雾絮 101 个实例合成 1 次 `drawRawAtlas`，
///   星点 190 个实例 1 次；静态暗场仍走 [NebulaBackdropPainter] 的独立缓存层
///   （`willChange: false`）。
///
/// 稳态零烘焙依据：图集由 [VisualizerSpriteAtlas.instance] 在首帧
/// `ensureImage()` 后**异步解码一次**（缺省读 `assets/viz/atlas_v1.png`），
/// 解码前 `imageOrNull == null`、本样式跳过精灵批次，绝不退回同步烘焙。
/// 解码入口不接受任何参数，缓存键里不存在音频派生量
/// （bass/mid/treble、`_energy`、`bloom`、时间、画布尺寸都不进键）。`paint()`
/// 中唯一的图像来源就是这张常驻图集，音频只改**颜色表索引与顶点变换**。
/// 因此首帧之后的任意时长（含 120 s）烘焙次数恒为 0。
class NebulaFlowPainter extends CustomPainter implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;

  static const int _veilCount = 10;
  static const int _billowCount = 18;
  static const int _haloCount = 1;
  static const int _wispCount = 54;
  static const int _starCount = 190;

  static const int _sliceBlob = 0;
  static const int _sliceWide = 1;
  static const int _sliceTall = 2;

  /// 云体种子：每个 11 项
  /// [x, y, 半径, 横向漂移速度, 纵向漂移速度, 漂移相位,
  ///  呼吸相位, 呼吸速度, 颜色档(0~3), 纵向拉长系数, 类型(0=幕布 1=云团)]
  static final Float32List _cloudSeeds = _buildCloudSeeds();

  /// 星点种子：每个 5 项 [x, y, 尺寸系数, 闪烁相位, 亮度权重]
  static final Float32List _starSeeds = _buildStarSeeds();

  /// 雾絮种子：每个 4 项 [相位, 旋转相位, 错位相位, alpha 系数]
  static final Float32List _wispSeeds = _buildWispSeeds();

  /// 每个云实例用哪块子图（构造期固定）。
  static final Int32List _cloudSliceOf = _buildCloudSliceOf();

  /// 每个星点用哪档亮度的星点精灵（构造期固定）。
  static final Int32List _starTierOf = _buildStarTierOf();

  final VisualizerSpriteAtlas _atlas = VisualizerSpriteAtlas.instance;

  final Float32List _starRst = Float32List(_starCount * 4);
  final Float32List _starRects = Float32List(_starCount * 4);

  static const int _alphaLevels = 64;

  /// 每帧精灵实例数（构造期常量，缓冲按它精确分配，不留空位）：
  /// 幕布 10 + 云团主副瓣 18×2 + 中央柔光 1 + 雾絮 54。
  static const int _cloudInstanceCount =
      _veilCount + _billowCount * 2 + _haloCount + _wispCount;

  /// 颜色表：[slot * _alphaLevels + level] → ARGB。颜色与 alpha 都编成整数，
  /// 作为 `drawRawAtlas` 的逐实例 `colors`，运行期只做整数索引。
  final Int32List _tints;

  /// 云体+雾絮这一批的顶点缓冲（RST 4 项 / 图集矩形 4 项 / 颜色 1 项）。
  final Float32List _spriteRst = Float32List(_cloudInstanceCount * 4);
  final Float32List _spriteRects = Float32List(_cloudInstanceCount * 4);
  final Int32List _spriteColors = Int32List(_cloudInstanceCount);
  int _spriteIndex = 0;

  /// 两批共用的绘制参数：只承载采样质量，颜色来自逐实例 colors。
  final Paint _batchPaint = Paint()
    ..filterQuality = FilterQuality.low
    ..isAntiAlias = true
    ..color = const Color(0xFFFFFFFF);

  final Int32List _starColors = Int32List(_starCount);

  double _lastTime = double.nan;
  double _energy = 0.0;

  NebulaFlowPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
  }) : _tints = _buildTintTable(palette) {
    _fillStarRects();
  }

  @override
  void setVisualizerTime(double time) => animationTime = time;

  static const int _slotCount = 6;

  static Int32List _buildTintTable(VisualizerPalette palette) {
    final out = Int32List(_slotCount * _alphaLevels);
    for (var s = 0; s < _slotCount; s++) {
      final rgb = _baseColor(palette, s).toARGB32() & 0x00FFFFFF;
      for (var i = 0; i < _alphaLevels; i++) {
        final a = (i * 255 / (_alphaLevels - 1)).round();
        out[s * _alphaLevels + i] = (a << 24) | rgb;
      }
    }
    return out;
  }

  static Color _baseColor(VisualizerPalette palette, int slot) => switch (slot) {
        0 => palette.primary,
        1 => palette.secondary,
        2 =>
          palette.gradient.isNotEmpty ? palette.gradient.first : palette.primary,
        3 => palette.gradient.length > 2
            ? palette.gradient[2]
            : palette.secondary,
        4 => palette.glow,
        // 星点必须用最亮的 peak：旧版误用 gradient.first（深色底），
        // 星点乘上深色后比云体更暗，会读成「暗十字」。
        _ => palette.peak,
      };

  /// 取颜色表里的 ARGB（颜色 + alpha），运行期零分配。
  int _tintAt(int slot, double alpha) {
    final i = (alpha.clamp(0.0, 1.0) * (_alphaLevels - 1)).round();
    return _tints[slot * _alphaLevels + i];
  }

  static Float32List _buildCloudSeeds() {
    final rnd = math.Random(20261107);
    final out = Float32List((_veilCount + _billowCount) * 11);
    for (var i = 0; i < _veilCount + _billowCount; i++) {
      final o = i * 11;
      final billow = i >= _veilCount;
      out[o] = (rnd.nextDouble() * 2 - 1) * 1.05;
      out[o + 1] = 0.04 + rnd.nextDouble() * 0.92;
      out[o + 2] = billow
          ? 0.13 + rnd.nextDouble() * 0.14
          : 0.28 + rnd.nextDouble() * 0.16;
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
      out[o] = (rnd.nextDouble() * 2 - 1) * 0.96;
      out[o + 1] = 0.03 + rnd.nextDouble() * 0.94;
      // 尺寸分布偏小：多数微星、少量稍大的星，避免「雨点」感。
      // 指数 > 1 才会把分布压向 0；指数 < 1 反而让大多数星偏大。
      out[o + 2] = math.pow(rnd.nextDouble(), 1.8).toDouble();
      out[o + 3] = rnd.nextDouble() * math.pi * 2;
      out[o + 4] = math.pow(rnd.nextDouble(), 2.2).toDouble();
    }
    return out;
  }

  static Float32List _buildWispSeeds() {
    final rnd = math.Random(3141592);
    final out = Float32List(_wispCount * 4);
    for (var i = 0; i < _wispCount; i++) {
      final o = i * 4;
      out[o] = rnd.nextDouble() * math.pi * 2;
      out[o + 1] = rnd.nextDouble() * math.pi * 2;
      out[o + 2] = rnd.nextDouble() * math.pi * 2;
      out[o + 3] = 0.55 + rnd.nextDouble() * 0.65;
    }
    return out;
  }

  static Int32List _buildCloudSliceOf() {
    final out =
        Int32List(_veilCount + _billowCount * 2 + _haloCount);
    var i = 0;
    // 幕布：全部用横向云，覆盖画面宽度。
    for (var k = 0; k < _veilCount; k++, i++) {
      out[i] = _sliceWide;
    }
    // 云团：主瓣 + 副瓣，按种子的拉长系数选不同的剪影。
    for (var k = 0; k < _billowCount; k++) {
      final o = (_veilCount + k) * 11;
      final aspect = _cloudSeeds[o + 9];
      final main = aspect < 0.86
          ? _sliceWide
          : (aspect > 1.12 ? _sliceTall : _sliceBlob);
      out[i++] = main;
      out[i++] = main == _sliceBlob
          ? _sliceTall
          : (main == _sliceWide ? _sliceBlob : _sliceWide);
    }
    // 中央柔光。
    out[i] = _sliceBlob;
    return out;
  }

  static Int32List _buildStarTierOf() {
    final out = Int32List(_starCount);
    for (var i = 0; i < _starCount; i++) {
      final w = _starSeeds[i * 5 + 4];
      out[i] = w < 0.15 ? 0 : (w < 0.45 ? 1 : (w < 0.80 ? 2 : 3));
    }
    return out;
  }

  SpriteSlice _sliceAt(int index) => switch (index) {
        _sliceWide => _atlas.blobWide,
        _sliceTall => _atlas.blobTall,
        _ => _atlas.blob,
      };

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

  /// 追加一个精灵实例（不即时绘制）：中心对齐 `cx/cy`，等比缩放 + 旋转。
  ///
  /// 等价于旧实现的 `translate/rotate/scale + drawImageRect(localRect)`，
  /// 但只写顶点缓冲：RST 采用 Skia 的 `[scos, ssin, tx, ty]` 约定——矩形
  /// 左上角映射到 `(tx, ty)`，因此把子图中心平移到目标点的偏移是
  /// `(scos·w/2 − ssin·h/2, ssin·w/2 + scos·h/2)`。逐帧不分配对象。
  void _appendSprite(SpriteSlice s, double cx, double cy, double scale,
      double rot, int argb) {
    if (_spriteIndex >= _cloudInstanceCount) return;
    final i = _spriteIndex++;
    final o = i * 4;
    final cosA = rot == 0.0 ? 1.0 : math.cos(rot);
    final sinA = rot == 0.0 ? 0.0 : math.sin(rot);
    final sc = scale * cosA;
    final ss = scale * sinA;
    final hw = s.width * 0.5;
    final hh = s.height * 0.5;
    _spriteRects[o] = s.rect[0];
    _spriteRects[o + 1] = s.rect[1];
    _spriteRects[o + 2] = s.rect[2];
    _spriteRects[o + 3] = s.rect[3];
    _spriteRst[o] = sc;
    _spriteRst[o + 1] = ss;
    _spriteRst[o + 2] = cx - (sc * hw - ss * hh);
    _spriteRst[o + 3] = cy - (ss * hw + sc * hh);
    _spriteColors[i] = argb;
  }

  /// 一次提交整批精灵：`BlendMode.modulate` 把实例色乘到纹理上，
  /// 纹理 alpha 保留，不开任何离屏层。
  void _flushSprites(Canvas canvas, ui.Image atlas) {
    canvas.drawRawAtlas(
      atlas,
      _spriteRst,
      _spriteRects,
      _spriteColors,
      BlendMode.modulate,
      null,
      _batchPaint,
    );
    assert(_spriteIndex <= _cloudInstanceCount);
    _spriteIndex = 0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // 资源路径：首帧发起一次异步解码；未完成（或解码失败）的那几帧直接
    // 跳过精灵批次，绝不退回同步烘焙。
    _atlas.ensureImage();
    final ui.Image? atlas = _atlas.imageOrNull;
    if (atlas == null) return;

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

    final pulse = 1.0 + _energy * 0.10 + bass * 0.06;
    final fieldR = minDim * (0.60 + _energy * 0.12);

    // 1) 大幕布：铺满画面的低频云底，亮度最低。
    for (var i = 0; i < _veilCount; i++) {
      final o = i * 11;
      final driftX =
          math.sin(t * _cloudSeeds[o + 3] + _cloudSeeds[o + 5]) * fieldR * 0.10;
      final driftY =
          math.cos(t * _cloudSeeds[o + 4] + _cloudSeeds[o + 5]) * fieldR * 0.06;
      final breathe =
          1.0 + 0.14 * math.sin(t * _cloudSeeds[o + 7] + _cloudSeeds[o + 6]);
      final x = cx + _cloudSeeds[o] * fieldR * 1.08 + driftX;
      final y = cy + (_cloudSeeds[o + 1] - 0.5) * h * 1.06 + driftY;
      final r = minDim * _cloudSeeds[o + 2] * breathe * pulse;
      final slice = _sliceAt(_cloudSliceOf[i]);
      _appendSprite(
        slice,
        x,
        y,
        (2.0 * r) / slice.height,
        _cloudSeeds[o + 5] * 0.22,
        _tintAt(_cloudSeeds[o + 8].toInt(), 0.075 + 0.10 * _energy),
      );
    }

    // 2) 云团：主瓣 + 一瓣错位副瓣，剪影不再是标准椭圆。
    var idx = _veilCount;
    for (var k = 0; k < _billowCount; k++, idx += 2) {
      final o = (_veilCount + k) * 11;
      final driftX =
          math.sin(t * _cloudSeeds[o + 3] + _cloudSeeds[o + 5]) * fieldR * 0.10;
      final driftY =
          math.cos(t * _cloudSeeds[o + 4] + _cloudSeeds[o + 5]) * fieldR * 0.06;
      final breathe =
          1.0 + 0.14 * math.sin(t * _cloudSeeds[o + 7] + _cloudSeeds[o + 6]);
      final x = cx + _cloudSeeds[o] * fieldR * 0.78 + driftX;
      final y = cy + (_cloudSeeds[o + 1] - 0.5) * h * 1.02 + driftY;
      final r = minDim * _cloudSeeds[o + 2] * breathe * pulse;
      final slot = _cloudSeeds[o + 8].toInt();
      final alpha = 0.15 + 0.22 * _energy;

      final mainSlice = _sliceAt(_cloudSliceOf[idx]);
      _appendSprite(mainSlice, x, y, (2.0 * r) / mainSlice.height,
          _cloudSeeds[o + 6] * 0.30, _tintAt(slot, alpha));

      // 副瓣：偏移 + 更小 + 更淡，把圆形剪影打散。
      final ang = _cloudSeeds[o + 5] + k * 0.73;
      final lx = x + math.cos(ang) * r * 0.44;
      final ly = y + math.sin(ang) * r * 0.34;
      final lobeSlice = _sliceAt(_cloudSliceOf[idx + 1]);
      _appendSprite(lobeSlice, lx, ly, (2.0 * r * 0.70) / lobeSlice.height,
          ang * 0.5 + 0.6, _tintAt(slot, alpha * 0.72));
    }

    // 3) 中央柔光：给云层一个共同的光源，避免整屏平铺。
    _appendSprite(
      _atlas.blob,
      cx,
      cy * 0.86,
      (fieldR * 1.30) / _atlas.blob.height,
      0.0,
      _tintAt(0, 0.09 + 0.11 * _energy),
    );

    // 4) 雾絮：贴在云团/幕布上做高频错位叠加，形成细密湍流纹理。
    for (var k = 0; k < _wispCount; k++) {
      final so = k * 4;
      // 全部贴到云团上：幕布太淡，纤维落在幕布上会脱离云体、读成一道划痕。
      final cloudIndex = _veilCount + (k % _billowCount);
      final o = cloudIndex * 11;
      final driftX =
          math.sin(t * _cloudSeeds[o + 3] + _cloudSeeds[o + 5]) * fieldR * 0.10;
      final driftY =
          math.cos(t * _cloudSeeds[o + 4] + _cloudSeeds[o + 5]) * fieldR * 0.06;
      final x = cx +
          _cloudSeeds[o] * fieldR * 0.78 +
          driftX +
          math.sin(t * 1.35 + _wispSeeds[so + 2]) * fieldR * 0.055;
      final y = cy +
          (_cloudSeeds[o + 1] - 0.5) * h * 1.02 +
          driftY +
          math.cos(t * 1.10 + _wispSeeds[so + 2]) * fieldR * 0.040;
      final r = minDim * _cloudSeeds[o + 2] * 0.42;
      // 小团絮：宽度 ≈ r（30~105 px）、高度 0.36r（11~38 px），剪影不规则；
      // 保持低 alpha，让它读作云体内部的湍流纹，而不是一块独立色斑。
      _appendSprite(
        _atlas.puff,
        x,
        y,
        (r * 1.0) / _atlas.puff.width,
        _wispSeeds[so + 1] + t * 0.16,
        _tintAt(
          _cloudSeeds[o + 8].toInt(),
          (0.07 + 0.10 * _energy) * _wispSeeds[so + 3],
        ),
      );
    }

    // 云体+雾絮整批提交：101 个实例 = 1 次 draw（旧版是 101 次 drawImageRect，
    // 每次带混合模式 ColorFilter，在 Impeller 上各开一个离屏子 pass）。
    _flushSprites(canvas, atlas);

    // 5) 星点：一次 drawRawAtlas 提交全部实例。
    //    亮度分布来自四档烘焙精灵（按固定种子挑选），闪烁只改变尺寸；
    //    alpha 走逐实例 colors（整批同值），不挂 ColorFilter。
    final starArgb =
        _tintAt(5, 0.30 + 0.70 * (0.35 + 0.65 * treble) * (0.30 + 0.70 * _energy));
    for (var k = 0; k < _starCount; k++) {
      final o = k * 5;
      final x = cx + _starSeeds[o] * w * 0.48;
      final y = _starSeeds[o + 1] * h;
      final twinkle = 0.5 + 0.5 * math.sin(t * 0.85 + _starSeeds[o + 3]);
      // 5.5~12 px（含十字芒）：亮核落在 0.9~1.9 px，读作细颗粒而不是雨点。
      final size = (5.5 + _starSeeds[o + 2] * 6.5) * (0.85 + 0.15 * twinkle);
      final scale = size / 64.0;
      final r = k * 4;
      _starRst[r] = scale;
      _starRst[r + 1] = 0.0;
      _starRst[r + 2] = x - scale * 32.0;
      _starRst[r + 3] = y - scale * 32.0;
      _starColors[k] = starArgb;
    }
    canvas.drawRawAtlas(
      atlas,
      _starRst,
      _starRects,
      _starColors,
      BlendMode.modulate,
      null,
      _batchPaint,
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
