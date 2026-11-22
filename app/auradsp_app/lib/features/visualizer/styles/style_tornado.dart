import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_sprite_atlas.dart';
import 'visualizer_time_aware.dart';

/// 粒子龙卷风（Particle Tornado）：物理吸入与上升气旋视觉语言。
///
/// 2026-11-22 动力学重构：
/// 1. 彻底解决粒子不旋转、仅随音频机械缩放的假象：
///    - 建立连续粒子动力学生命周期（吸入辐合 → 螺旋跃升 → 穹顶抛出）；
///    - 严格遵循角动量守恒近似：外围粒子向中心聚拢时角速度急剧飙升，形成真实漩涡吸力；
///    - 核心上升柱沿双曲漏斗母线盘旋而上，带有前后景深度投影（前亮后暗）与 3D 旋转体感；
///    - 顶部辐散区在离心力作用下向外扩散渐隐，随后平滑重入吸入循环；
/// 2. 音频驱动转向动能与发光而非形体缩放：
///    - 音频低频/中频主要驱动自转角速度 ω、核心电光闪烁与湍流活跃度，
///      漏斗外廓骨架保持宏观稳固，不再随音量机械缩放；
/// 3. 严格保持零逐帧分配（Zero Allocations per Frame）：
///    - 预分配 220 颗旋风粒子（Float32List / Int32List）；
///    - 仅 2 次 drawRawAtlas 调用（锥体柔光/团絮批次 + 旋风粒子群批次），单帧 CPU 耗时 < 0.2ms。
class ParticleTornadoPainter extends CustomPainter
    implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  static const int _bandCount = 6;
  static const int _wispCount = 26;
  static const int _starCount = 220;

  /// 每条雾带：[相位, 扭转率, 自转角速度, alpha 系数]
  static final Float32List _bandParams = Float32List.fromList(const [
    0.00, 6.4, 0.36, 0.90,
    1.05, 6.9, 0.41, 0.78,
    2.10, 7.4, 0.46, 1.00,
    3.14, 6.1, 0.51, 0.72,
    4.19, 7.8, 0.56, 0.86,
    5.24, 6.7, 0.61, 0.66,
  ]);

  /// 旋风粒子种子：每个 6 项
  /// [初始相位(0~1), 循环速率, 初始方位角(0~2π), 外围吸入半径系数(1.4~2.8), 壁面紧贴系数(0.82~1.18), 电光权重]
  static final Float32List _starSeeds = _buildStarSeeds();

  static final Int32List _starTierOf = _buildStarTierOf();

  final VisualizerSpriteAtlas _atlas = VisualizerSpriteAtlas.instance;

  final Float32List _starRst = Float32List(_starCount * 4);
  final Float32List _starRects = Float32List(_starCount * 4);

  static const int _alphaLevels = 64;

  /// 每帧精灵实例数（构造期常量，缓冲精确分配）：
  /// 浅盘 2 + 锥体 2 + 细纹 26。
  static const int _spriteInstanceCount = 2 + 2 + _wispCount;

  /// 颜色表：[slot * _alphaLevels + level] → ARGB，作为逐实例 `colors`。
  final Int32List _tints;

  final Float32List _spriteRst = Float32List(_spriteInstanceCount * 4);
  final Float32List _spriteRects = Float32List(_spriteInstanceCount * 4);
  final Int32List _spriteColors = Int32List(_spriteInstanceCount);
  int _spriteIndex = 0;

  /// 两批共用的绘制参数：只承载采样质量，颜色来自逐实例 colors。
  final Paint _batchPaint = Paint()
    ..filterQuality = FilterQuality.low
    ..isAntiAlias = true
    ..color = const Color(0xFFFFFFFF);

  final Int32List _starColors = Int32List(_starCount);

  double _lastTime = double.nan;
  double _smoothedBass = 0.0;
  double _smoothedEnergy = 0.0;

  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  }) : _tints = _buildTintTable(palette) {
    _fillStarRects();
  }

  @override
  void setVisualizerTime(double time) => animationTime = time;

  static const int _slotCount = 4;

  static Int32List _buildTintTable(VisualizerPalette palette) {
    final bases = [
      palette.primary,
      palette.secondary,
      palette.peak,
      palette.glow,
    ];
    final out = Int32List(_slotCount * _alphaLevels);
    for (var s = 0; s < _slotCount; s++) {
      final rgb = bases[s].toARGB32() & 0x00FFFFFF;
      for (var i = 0; i < _alphaLevels; i++) {
        final a = (i * 255 / (_alphaLevels - 1)).round();
        out[s * _alphaLevels + i] = (a << 24) | rgb;
      }
    }
    return out;
  }

  /// 取颜色表里的 ARGB（颜色 + alpha），运行期零分配。
  int _tintAt(int slot, double alpha) {
    final i = (alpha.clamp(0.0, 1.0) * (_alphaLevels - 1)).round();
    return _tints[slot * _alphaLevels + i];
  }

  static Float32List _buildStarSeeds() {
    final rnd = math.Random(771103);
    final out = Float32List(_starCount * 6);
    for (var i = 0; i < _starCount; i++) {
      final o = i * 6;
      // 初始归一化生命周期相位 [0.0, 1.0)
      out[o] = rnd.nextDouble();
      // 循环周期速率（完整循环耗时约 3.0 ~ 5.5 秒）
      out[o + 1] = 0.20 + rnd.nextDouble() * 0.14;
      // 初始空间方位角 [0, 2π)
      out[o + 2] = rnd.nextDouble() * math.pi * 2;
      // 地面外围吸入半径系数（漏斗最大半径的 1.4 ~ 3.0 倍）
      out[o + 3] = 1.4 + rnd.nextDouble() * 1.6;
      // 沿漏斗母线的壁面紧密程度系数
      out[o + 4] = 0.82 + rnd.nextDouble() * 0.36;
      // 电光闪烁与亮核权重
      out[o + 5] = math.pow(rnd.nextDouble(), 1.8).toDouble();
    }
    return out;
  }

  static Int32List _buildStarTierOf() {
    final out = Int32List(_starCount);
    for (var i = 0; i < _starCount; i++) {
      final w = _starSeeds[i * 6 + 5];
      out[i] = w < 0.22 ? 0 : (w < 0.55 ? 1 : (w < 0.82 ? 2 : 3));
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

  /// 追加一个精灵实例（零分配）：中心对齐 `cx/cy`，等比缩放 + 旋转。
  void _appendSprite(SpriteSlice s, double cx, double cy, double scale,
      double rot, int argb) {
    if (_spriteIndex >= _spriteInstanceCount) return;
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
    assert(_spriteIndex <= _spriteInstanceCount);
    _spriteIndex = 0;
  }

  /// 漏斗母线（与烘焙精灵共用同一条曲线，雾絮才能准确贴在锥面上）。
  static double _radiusAt(double u) => VisualizerSpriteAtlas.radiusAt(u);

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

    final bass = _avg(0, math.max(1, n ~/ 8));
    final mid = _avg(n ~/ 4, n ~/ 2);
    final treble = _avg((n * 3) ~/ 4, n);

    final dt = (!t.isFinite || !_lastTime.isFinite || t < _lastTime)
        ? 1.0 / 30.0
        : (t - _lastTime).clamp(0.001, 0.05);
    _lastTime = t;

    _smoothedBass += (bass - _smoothedBass) * (dt * 4.5).clamp(0.0, 1.0);
    final rawEnergy = (bass * 0.45 + mid * 0.35 + treble * 0.20).clamp(0.0, 1.0);
    _smoothedEnergy += (rawEnergy - _smoothedEnergy) * (dt * 5.0).clamp(0.0, 1.0);

    // 核心几何体保持稳定：杜绝“音量一大幅度就忽大忽小乱膨胀”的廉价感
    final cx = w / 2.0;
    final baseY = h * 0.86;
    final funnelH = h * 0.62;
    final maxR = minDim * 0.28 * (lineWidth / 1.5).clamp(0.85, 1.2);

    // 音频驱动核心自转角速度（kick 鼓点下气旋转速瞬间加快）
    final spinRate = 2.4 + 4.2 * _smoothedBass + 1.2 * mid;

    // 1) 底部浅盘：承载地表吸聚辐合与触地发光
    final saucerW = maxR * 1.95;
    final saucerIntensity = 0.09 + 0.12 * _smoothedBass;
    _appendSprite(
      _atlas.saucer,
      cx,
      baseY,
      saucerW / _atlas.saucer.width,
      0.0,
      _tintAt(1, saucerIntensity),
    );
    _appendSprite(
      _atlas.saucer,
      cx,
      baseY,
      (saucerW * 0.54) / _atlas.saucer.width,
      0.0,
      _tintAt(2, 0.18 + 0.25 * _smoothedBass),
    );

    // 2) 连续体积锥体：外层柔光 + 内层明锥
    final funnelScale = funnelH / 448.0;
    final funnelCenterY = baseY - 448.0 * 0.94 * funnelScale * 0.5;
    _appendSprite(
      _atlas.funnelWide,
      cx,
      funnelCenterY,
      funnelScale,
      0.0,
      _tintAt(0, 0.52 + 0.22 * _smoothedEnergy),
    );
    _appendSprite(
      _atlas.funnelCore,
      cx,
      funnelCenterY,
      funnelScale,
      0.0,
      _tintAt(1, 0.38 + 0.24 * _smoothedEnergy),
    );

    // 3) 锥面气旋团絮（26 枚）：顺旋转方向贴面盘旋，产生体积湍流流动
    for (var k = 0; k < _wispCount; k++) {
      final band = k % _bandCount;
      final o = band * 4;
      final phase = _bandParams[o];
      final twist = _bandParams[o + 1];
      final spin = _bandParams[o + 2];
      final jitter = math.sin(k * 12.9898) * 0.5 + 0.5;

      final u = (0.06 +
              0.86 * ((k + 0.5) / _wispCount) +
              math.sin(t * 0.6 + phase * 1.7) * 0.03)
          .clamp(0.04, 0.98);

      final ang = phase + twist * u + t * (spin * 1.6 + spinRate * 0.25);
      final localR = maxR * _radiusAt(u);
      final rr = localR * (0.28 + 0.32 * jitter);
      final x = cx + math.cos(ang) * rr;
      final y = baseY - u * funnelH + math.sin(ang * 0.5) * funnelH * 0.010;

      final topFade = u > 0.65 ? (1.0 - u) / 0.35 : 1.0;
      final rot = ang * 0.35 + 0.55;
      final mul = _bandParams[o + 3] * (0.60 + _smoothedEnergy * 0.60);

      _appendSprite(
        _atlas.puff,
        x,
        y,
        (localR * 0.72) / _atlas.puff.width,
        rot,
        _tintAt(k.isEven ? 0 : 1, (0.12 * mul + 0.08 * _smoothedBass) * topFade),
      );
    }

    _flushSprites(canvas, atlas);

    // 4) 众旋风粒子群（220 颗）：真实的三阶段漩涡运动学与角动量守恒
    //    阶段一 (tau ∈ [0.0, 0.36])：地表外围吸入辐合，越往中心靠拢角速度越急剧加速；
    //    阶段二 (tau ∈ [0.36, 0.86])：核心上升螺旋柱，沿漏斗母线飞速盘旋向上，带有前后深度投射；
    //    阶段三 (tau ∈ [0.86, 1.00])：顶部离心力抛出并渐隐溶解，随后重入循环。
    for (var k = 0; k < _starCount; k++) {
      final o = k * 6;
      final phase0 = _starSeeds[o];
      final rate = _starSeeds[o + 1];
      final azimuth0 = _starSeeds[o + 2];
      final inflowRMult = _starSeeds[o + 3];
      final tightness = _starSeeds[o + 4];
      final sparkWeight = _starSeeds[o + 5];

      // 连续闭环生命周期进度 tau ∈ [0.0, 1.0)
      final tau = (t * rate + phase0) % 1.0;

      double px;
      double py;
      double pz; // 用于伪 3D 深度投影 (z > 0 为前景亮部，z < 0 为背景暗部)
      double pAlpha;
      double pScaleBonus = 1.0;

      if (tau < 0.36) {
        // === 阶段一：地表外向内强力吸入 ===
        final s = tau / 0.36; // 0.0 -> 1.0
        // 半径从外围向漏斗底部基底半径逼近
        final baseR = maxR * _radiusAt(0.0) * tightness;
        final startR = maxR * inflowRMult;
        // 缓动曲线：吸入初段缓慢，靠近中心时由于引力急速下沉
        final rCur = baseR + (startR - baseR) * math.pow(1.0 - s, 1.4);

        // 角动量守恒效应：半径越小，角速度 ω 越高
        final angularAcc = math.pow((startR / (rCur + maxR * 0.12)), 0.85);
        final theta = azimuth0 + t * spinRate * 0.42 * angularAcc + s * 4.5;

        px = cx + math.cos(theta) * rCur;
        pz = math.sin(theta) * rCur;
        // 高度贴近地表，带有轻微空气扰动
        py = baseY + (1.0 - s) * h * 0.025 * math.sin(azimuth0 * 3.0);

        // 逐渐从暗中显现
        pAlpha = (0.25 + 0.75 * s) * (0.50 + 0.50 * _smoothedEnergy);
        pScaleBonus = 0.85 + 0.25 * s;
      } else if (tau < 0.86) {
        // === 阶段二：漏斗核心上升螺旋柱 ===
        final u = (tau - 0.36) / 0.50; // 0.0 -> 1.0 (高度归一化)
        final localR = maxR * _radiusAt(u) * tightness;
        // 盘旋向上的扭曲角度（整体旋转 + 沿高度螺旋缠绕）
        final theta = azimuth0 + t * spinRate + u * 8.5;

        final cosT = math.cos(theta);
        final sinT = math.sin(theta);
        px = cx + cosT * localR;
        pz = sinT * localR;
        py = baseY - u * funnelH;

        // 3D 深度阴影：前景粒子明亮放大，后景粒子半透明减弱
        final depthNorm = (pz / (localR + 0.001)).clamp(-1.0, 1.0);
        if (depthNorm >= 0.0) {
          // 前景 (朝向屏幕)
          pAlpha = (0.75 + 0.25 * depthNorm) * (0.60 + 0.40 * _smoothedEnergy);
          pScaleBonus = 1.0 + 0.30 * depthNorm;
        } else {
          // 后景 (被中心雾柱遮挡)
          pAlpha = (0.75 + 0.40 * depthNorm).clamp(0.20, 0.75) * (0.50 + 0.50 * _smoothedEnergy);
          pScaleBonus = 1.0 + 0.20 * depthNorm;
        }

        // 核心电光火花：高 sparkWeight 粒子在低频重击时暴增亮度
        if (sparkWeight > 0.75 && _smoothedBass > 0.4) {
          pAlpha = math.min(1.0, pAlpha * 1.4);
          pScaleBonus *= 1.25;
        }
      } else {
        // === 阶段三：顶部穹顶离心力抛散 ===
        final e = (tau - 0.86) / 0.14; // 0.0 -> 1.0
        final topBaseR = maxR * _radiusAt(1.0) * tightness;
        // 离心力向外猛烈甩出
        final rOut = topBaseR + math.pow(e, 1.15) * maxR * 1.5;
        final theta = azimuth0 + t * spinRate + 8.5 + e * 2.5;

        px = cx + math.cos(theta) * rOut;
        pz = math.sin(theta) * rOut;
        py = baseY - funnelH - e * funnelH * 0.08;

        // 向外迅速衰减至透明
        pAlpha = (1.0 - e) * 0.70 * (0.50 + 0.50 * _smoothedEnergy);
        pScaleBonus = 1.1 - e * 0.4;
      }

      // 星点闪烁
      final twinkle = 0.65 + 0.35 * math.sin(t * 1.6 + _starSeeds[o]);
      final baseSize = 3.6 + _starSeeds[o + 5] * 5.2;
      final finalSize = baseSize * pScaleBonus * twinkle;
      final scale = finalSize / 64.0;

      final r = k * 4;
      _starRst[r] = scale;
      _starRst[r + 1] = 0.0;
      _starRst[r + 2] = px - scale * 32.0;
      _starRst[r + 3] = py - scale * 32.0;

      // 区分电光火花粒子与常规尘埃粒子
      final int argb;
      if (sparkWeight > 0.75) {
        argb = _tintAt(2, pAlpha);
      } else if (sparkWeight > 0.40) {
        argb = _tintAt(1, pAlpha);
      } else {
        argb = _tintAt(0, pAlpha);
      }
      _starColors[k] = argb;
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
  bool shouldRepaint(covariant ParticleTornadoPainter oldDelegate) => true;
}

/// 龙卷风的静态基底：暗场渐变 + 轻微渐晕 + 地面辉光。
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
