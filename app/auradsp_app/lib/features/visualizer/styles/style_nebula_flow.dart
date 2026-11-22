import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_sprite_atlas.dart';
import 'visualizer_time_aware.dart';

/// 星云（Nebula）：深空柔雾星云与星际尘埃视觉语言。
///
/// 2026-11-22 动力学重构：
/// 1. 彻底解除云团定点锚定——引入环形坐标漂移空间（Toroidal Cosmic Space），
///    大幕布底云与主体云团以多层视差速率在宇宙视口中自由飘动，穿出边界平滑回环；
/// 2. 彻底移除云内圆周绕转的“转圈轮子”假象——雾絮（puff）作为星际气体纤维（Filament）
///    与电离脊线，顺着星云流场方向展布，随宇宙潮汐轻微呼吸起伏，呈现真实的星云纤维纹理；
/// 3. 严格保持零逐帧分配（Zero Allocations per Frame）：
///    - 预烘焙精灵图集（VisualizerSpriteAtlas）；
///    - 预分配 Float32List / Int32List 顶点与颜色表；
///    - 逐帧仅 2 次 drawRawAtlas 调用（云体/雾絮批次 + 星点批次），零离屏 pass。
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

  /// 云体种子：每个 12 项
  /// [x0, y0, 半径, 漂移速度vx, 漂移速度vy, 蜿蜒频率,
  ///  蜿蜒幅度, 呼吸频率, 呼吸相位, 颜色档(0~3), 纵横比(0.7~1.3), 基础旋转]
  static final Float32List _cloudSeeds = _buildCloudSeeds();

  /// 星点种子：每个 5 项 [x, y, 尺寸系数, 闪烁相位, 亮度权重]
  static final Float32List _starSeeds = _buildStarSeeds();

  /// 雾絮纤维种子：每个 5 项 [沿流向偏移, 垂直流向偏移, 姿态微倾, 波动频率, alpha系数]
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
  /// 幕布 10 + 云团主副瓣 18×2 + 中央柔光 1 + 雾絮纤维 54。
  static const int _cloudInstanceCount =
      _veilCount + _billowCount * 2 + _haloCount + _wispCount;

  /// 颜色表：[slot * _alphaLevels + level] → ARGB。颜色与 alpha 编成整数，
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
        _ => palette.peak,
      };

  /// 取颜色表里的 ARGB（颜色 + alpha），运行期零分配。
  int _tintAt(int slot, double alpha) {
    final i = (alpha.clamp(0.0, 1.0) * (_alphaLevels - 1)).round();
    return _tints[slot * _alphaLevels + i];
  }

  static Float32List _buildCloudSeeds() {
    final rnd = math.Random(20261107);
    final count = _veilCount + _billowCount;
    final out = Float32List(count * 12);
    for (var i = 0; i < count; i++) {
      final o = i * 12;
      final isBillow = i >= _veilCount;
      // 初始归一化坐标 [0.0, 1.0]
      out[o] = rnd.nextDouble();
      out[o + 1] = rnd.nextDouble();
      // 云团尺寸
      out[o + 2] = isBillow
          ? 0.16 + rnd.nextDouble() * 0.15
          : 0.32 + rnd.nextDouble() * 0.18;
      // 漂移速度：深层幕布缓慢庄严，前景云团平稳前行
      final speedScale = isBillow ? 0.022 : 0.010;
      final driftAngle = rnd.nextDouble() * math.pi * 2;
      out[o + 3] = math.cos(driftAngle) * (speedScale + rnd.nextDouble() * speedScale * 0.8);
      out[o + 4] = math.sin(driftAngle) * (speedScale * 0.6 + rnd.nextDouble() * speedScale * 0.5);
      // 蜿蜒参数：平滑正弦扰动，避免机械直线运动
      out[o + 5] = 0.15 + rnd.nextDouble() * 0.20; // meander freq
      out[o + 6] = 0.04 + rnd.nextDouble() * 0.05; // meander amp
      // 呼吸起伏参数
      out[o + 7] = 0.10 + rnd.nextDouble() * 0.15; // breathe freq
      out[o + 8] = rnd.nextDouble() * math.pi * 2; // breathe phase
      // 颜色档位与几何形态
      out[o + 9] = (rnd.nextDouble() * 4).floorToDouble().clamp(0, 3);
      out[o + 10] = 0.72 + rnd.nextDouble() * 0.56; // aspect
      out[o + 11] = rnd.nextDouble() * math.pi * 2; // base rot
    }
    return out;
  }

  static Float32List _buildStarSeeds() {
    final rnd = math.Random(771231);
    final out = Float32List(_starCount * 5);
    for (var i = 0; i < _starCount; i++) {
      final o = i * 5;
      out[o] = rnd.nextDouble();
      out[o + 1] = rnd.nextDouble();
      out[o + 2] = math.pow(rnd.nextDouble(), 1.8).toDouble();
      out[o + 3] = rnd.nextDouble() * math.pi * 2;
      out[o + 4] = math.pow(rnd.nextDouble(), 2.2).toDouble();
    }
    return out;
  }

  static Float32List _buildWispSeeds() {
    final rnd = math.Random(3141592);
    final out = Float32List(_wispCount * 5);
    for (var i = 0; i < _wispCount; i++) {
      final o = i * 5;
      // 沿流场轴向的相对偏移与横向展布（-0.45 ~ +0.45）
      out[o] = (rnd.nextDouble() * 2 - 1) * 0.45;
      out[o + 1] = (rnd.nextDouble() * 2 - 1) * 0.28;
      // 纤维微倾角（-0.35 ~ +0.35 rad）
      out[o + 2] = (rnd.nextDouble() * 2 - 1) * 0.35;
      // 波动频率与 alpha
      out[o + 3] = 0.4 + rnd.nextDouble() * 0.6;
      out[o + 4] = 0.6 + rnd.nextDouble() * 0.5;
    }
    return out;
  }

  static Int32List _buildCloudSliceOf() {
    final out = Int32List(_veilCount + _billowCount * 2 + _haloCount);
    var i = 0;
    // 幕布：全部用横向云，覆盖画面低频底质
    for (var k = 0; k < _veilCount; k++, i++) {
      out[i] = _sliceWide;
    }
    // 云团：主瓣 + 副瓣
    for (var k = 0; k < _billowCount; k++) {
      final o = (_veilCount + k) * 12;
      final aspect = _cloudSeeds[o + 10];
      final main = aspect < 0.86
          ? _sliceWide
          : (aspect > 1.12 ? _sliceTall : _sliceBlob);
      out[i++] = main;
      out[i++] = main == _sliceBlob
          ? _sliceTall
          : (main == _sliceWide ? _sliceBlob : _sliceWide);
    }
    // 中央柔光
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

  /// 追加一个精灵实例（零分配）：中心对齐 `cx/cy`，等比缩放 + 旋转。
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

  /// 环形宇宙坐标包装：将任意实数坐标映射到 [minVal, minVal + span]
  static double _wrap(double val, double minVal, double span) {
    final d = (val - minVal) % span;
    return minVal + (d < 0.0 ? d + span : d);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
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

    final target = (bass * 0.35 + mid * 0.40 + treble * 0.25).clamp(0.0, 1.0);
    _energy += (target - _energy) * (dt * 3.2).clamp(0.0, 1.0);

    final pulse = 1.0 + _energy * 0.12 + bass * 0.08;

    // 宇宙漂移视口空间（比屏幕外延 35% 边缘，保证出入边界完全平滑无突兀裁切）
    final wrapMinX = -w * 0.35;
    final wrapSpanX = w * 1.70;
    final wrapMinY = -h * 0.25;
    final wrapSpanY = h * 1.50;

    // 1) 大幕布：10 张深层超大云团，以宁静低速在背景自由漂游
    for (var i = 0; i < _veilCount; i++) {
      final o = i * 12;
      final rawX = _cloudSeeds[o] * w +
          _cloudSeeds[o + 3] * t * w +
          math.sin(t * _cloudSeeds[o + 5] + _cloudSeeds[o + 8]) * w * _cloudSeeds[o + 6];
      final rawY = _cloudSeeds[o + 1] * h +
          _cloudSeeds[o + 4] * t * h +
          math.cos(t * _cloudSeeds[o + 5] + _cloudSeeds[o + 8]) * h * _cloudSeeds[o + 6];

      final x = _wrap(rawX, wrapMinX, wrapSpanX);
      final y = _wrap(rawY, wrapMinY, wrapSpanY);

      final breathe = 1.0 + 0.12 * math.sin(t * _cloudSeeds[o + 7] + _cloudSeeds[o + 8]);
      final r = minDim * _cloudSeeds[o + 2] * breathe * pulse;
      final slice = _sliceAt(_cloudSliceOf[i]);

      _appendSprite(
        slice,
        x,
        y,
        (2.2 * r) / slice.height,
        _cloudSeeds[o + 11] + t * 0.005,
        _tintAt(_cloudSeeds[o + 9].toInt(), 0.080 + 0.10 * _energy),
      );
    }

    // 2) 主体星云团：18 个云团自由飘移，每个包含主瓣 + 沿流向拉伸的副瓣
    var idx = _veilCount;
    for (var k = 0; k < _billowCount; k++, idx += 2) {
      final o = (_veilCount + k) * 12;
      final vx = _cloudSeeds[o + 3];
      final vy = _cloudSeeds[o + 4];

      final rawX = _cloudSeeds[o] * w +
          vx * t * w +
          math.sin(t * _cloudSeeds[o + 5] + _cloudSeeds[o + 8]) * w * _cloudSeeds[o + 6];
      final rawY = _cloudSeeds[o + 1] * h +
          vy * t * h +
          math.cos(t * _cloudSeeds[o + 5] + _cloudSeeds[o + 8]) * h * _cloudSeeds[o + 6];

      final x = _wrap(rawX, wrapMinX, wrapSpanX);
      final y = _wrap(rawY, wrapMinY, wrapSpanY);

      final breathe = 1.0 + 0.15 * math.sin(t * _cloudSeeds[o + 7] + _cloudSeeds[o + 8]);
      final r = minDim * _cloudSeeds[o + 2] * breathe * pulse;
      final slot = _cloudSeeds[o + 9].toInt();
      final alpha = 0.16 + 0.24 * _energy;

      // 主瓣
      final mainSlice = _sliceAt(_cloudSliceOf[idx]);
      final flowAngle = math.atan2(vy, vx);
      _appendSprite(
        mainSlice,
        x,
        y,
        (2.0 * r) / mainSlice.height,
        flowAngle * 0.25 + _cloudSeeds[o + 11],
        _tintAt(slot, alpha),
      );

      // 副瓣：顺着云团流场延伸，形成飘逸的不对称尾迹
      final tailAng = flowAngle + math.pi + 0.2 * math.sin(t * 0.3 + k);
      final lx = x + math.cos(tailAng) * r * 0.42;
      final ly = y + math.sin(tailAng) * r * 0.32;
      final lobeSlice = _sliceAt(_cloudSliceOf[idx + 1]);
      _appendSprite(
        lobeSlice,
        lx,
        ly,
        (1.4 * r) / lobeSlice.height,
        tailAng * 0.3 + 0.4,
        _tintAt(slot, alpha * 0.70),
      );
    }

    // 3) 中央柔光源：锚定于场景宏观核心，提供宇宙星系核发光
    _appendSprite(
      _atlas.blob,
      cx,
      cy * 0.88,
      (minDim * 0.95 * (1.0 + _energy * 0.15)) / _atlas.blob.height,
      0.0,
      _tintAt(0, 0.09 + 0.12 * _energy),
    );

    // 4) 雾絮纤维（Puff Filaments）：不再在云内做机械圆周绕转！
    //    按流向与纤维坐标依附在各个主体云团的边缘与脊线上，随星际风暴柔和起伏。
    for (var k = 0; k < _wispCount; k++) {
      final so = k * 5;
      final cloudIdx = _veilCount + (k % _billowCount);
      final o = cloudIdx * 12;

      final vx = _cloudSeeds[o + 3];
      final vy = _cloudSeeds[o + 4];

      final rawX = _cloudSeeds[o] * w +
          vx * t * w +
          math.sin(t * _cloudSeeds[o + 5] + _cloudSeeds[o + 8]) * w * _cloudSeeds[o + 6];
      final rawY = _cloudSeeds[o + 1] * h +
          vy * t * h +
          math.cos(t * _cloudSeeds[o + 5] + _cloudSeeds[o + 8]) * h * _cloudSeeds[o + 6];

      final cloudX = _wrap(rawX, wrapMinX, wrapSpanX);
      final cloudY = _wrap(rawY, wrapMinY, wrapSpanY);

      final r = minDim * _cloudSeeds[o + 2] * pulse;
      final flowAngle = math.atan2(vy, vx);

      // 沿气体流向与正交法向定位纤维，绝不在圆圈里自转
      final uAlong = _wispSeeds[so] * r * 0.85;
      final vCross = _wispSeeds[so + 1] * r * 0.65;
      final cosF = math.cos(flowAngle);
      final sinF = math.sin(flowAngle);

      final wispX = cloudX + (cosF * uAlong - sinF * vCross);
      final wispY = cloudY + (sinF * uAlong + cosF * vCross);

      // 纤维姿态：顺着流向展布，叠加微小的正弦柔和呼吸起伏（绝非 360 度自转）
      final undulation = math.sin(t * _wispSeeds[so + 3] + k * 0.8) * 0.12;
      final wispRot = flowAngle + _wispSeeds[so + 2] + undulation;

      final wispScale = (r * 0.48) / _atlas.puff.width;
      final slot = _cloudSeeds[o + 9].toInt();
      final alpha = (0.075 + 0.11 * _energy) * _wispSeeds[so + 4];

      _appendSprite(
        _atlas.puff,
        wispX,
        wispY,
        wispScale,
        wispRot,
        _tintAt(slot, alpha),
      );
    }

    _flushSprites(canvas, atlas);

    // 5) 深空星点（190 颗）：细小晶莹，高频闪烁，受高频音频调制
    final starArgb = _tintAt(
      5,
      0.35 + 0.65 * (0.35 + 0.65 * treble) * (0.30 + 0.70 * _energy),
    );

    for (var k = 0; k < _starCount; k++) {
      final o = k * 5;
      // 微小视差漂移：恒星极远，仅随深空缓慢位移
      final starRawX = _starSeeds[o] * w + t * 0.002 * w;
      final starX = _wrap(starRawX, 0.0, w);
      final starY = _starSeeds[o + 1] * h;

      final twinkle = 0.5 + 0.5 * math.sin(t * 1.1 + _starSeeds[o + 3]);
      final size = (4.8 + _starSeeds[o + 2] * 6.2) * (0.85 + 0.15 * twinkle);
      final scale = size / 64.0;
      final r = k * 4;

      _starRst[r] = scale;
      _starRst[r + 1] = 0.0;
      _starRst[r + 2] = starX - scale * 32.0;
      _starRst[r + 3] = starY - scale * 32.0;
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

/// 星云的静态基底：暗场 + 轻微渐晕。
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
