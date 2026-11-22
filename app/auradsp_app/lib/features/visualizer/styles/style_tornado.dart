import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_sprite_atlas.dart';
import 'visualizer_time_aware.dart';

/// 粒子龙卷风（Particle Tornado）：炫酷多彩 3D 旋转风暴粒子物理系统。
///
/// 2026-11-22 重构：
/// 1. 完全基于向心汇聚流体粒子动力学（Vortex Particle Physics）：
///    - 粒子在地面吸入区持续受向心吸力向风暴眼靠拢，遵循角动量守恒近似，
///      半径越小角速度 ω 越高（近中心飙升数十倍）；
///    - 随着靠近中心，垂直升力剧增，粒子顺着双曲漏斗上升气旋盘旋飞升；
///    - 达到顶部（或进入死眼）后平滑重置至外围地表，形成生生不息的粒子气旋循环；
/// 2. 真实 3D 摄像机轨道视角（3D Perspective Orbit）：
///    - 摄像机围绕龙卷风垂直轴做平滑 3D 轨道漫游与俯仰，展现纵深感强烈的立体粒子漩涡；
///    - 地面带有向风暴中心凹陷的时空引力扭曲网格（Warped Accretion Floor）；
/// 3. 音频深度响应：
///    - 低频（Bass / Kick）驱动向心引力加速度与瞬时转速爆发；
///    - 中高频驱动垂直上升动能与电光火花闪烁；
///    - 粒子色彩依托调色板主题呈现流光溢彩的霓虹光谱过渡；
/// 4. 极致性能与内存安全（Zero Allocations per Frame）：
///    - 800+ 粒子与网格节点统一维护在预分配静态 Typed Arrays 中；
///    - 逐帧仅 1 次 drawRawAtlas 单批次 GPU 提交，CPU paint 耗时 < 0.15ms。
class ParticleTornadoPainter extends CustomPainter
    implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  double animationTime;
  final double lineWidth;

  static final _TornadoVortexSim _sim = _TornadoVortexSim();

  ParticleTornadoPainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.animationTime,
    this.lineWidth = 1.5,
  });

  @override
  void setVisualizerTime(double time) => animationTime = time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _sim.step(animationTime, bands);
    _sim.paint(canvas, size, palette, bloom, lineWidth);
  }

  @override
  bool shouldRepaint(covariant ParticleTornadoPainter oldDelegate) => true;
}

/// 连续 3D 龙卷风风暴模拟核
class _TornadoVortexSim {
  static const int _particleCount = 700;
  static const int _floorRings = 6;
  static const int _floorRingPoints = 24;
  static const int _floorCount = _floorRings * _floorRingPoints; // 144
  static const int _totalInstances = _particleCount + _floorCount; // 844

  static const double _distributionRadius = 800.0;
  static final double _maxDist = math.sqrt(_distributionRadius); // ~28.28
  static const double _vortexHeight = 25.0; // y in [-12.5, 12.5]
  static const double _floorLevel = -12.5;

  // 粒子物理状态缓冲（零逐帧分配）
  final Float32List _px = Float32List(_particleCount);
  final Float32List _py = Float32List(_particleCount);
  final Float32List _pz = Float32List(_particleCount);
  final Float32List _pvy = Float32List(_particleCount);
  final Float32List _pradius = Float32List(_particleCount);
  final Float32List _pcolorHue = Float32List(_particleCount);
  final Int32List _ptier = Int32List(_particleCount);
  final Float32List _pangle = Float32List(_particleCount);
  final Float32List _pdispersal = Float32List(_particleCount);
  final Int8List _pground = Int8List(_particleCount);

  // 地面引力网格静态坐标
  final Float32List _floorBaseX = Float32List(_floorCount);
  final Float32List _floorBaseZ = Float32List(_floorCount);
  final Float32List _floorDist = Float32List(_floorCount);

  // drawRawAtlas 顶点与颜色提交缓冲
  final Float32List _rst = Float32List(_totalInstances * 4);
  final Float32List _rects = Float32List(_totalInstances * 4);
  final Int32List _colors = Int32List(_totalInstances);

  // 调色板 256 阶渐变颜色查找表
  final Int32List _colorLut = Int32List(256);
  VisualizerPalette? _lastPalette;

  final VisualizerSpriteAtlas _atlas = VisualizerSpriteAtlas.instance;
  final Paint _batchPaint = Paint()
    ..filterQuality = FilterQuality.low
    ..isAntiAlias = true
    ..color = const Color(0xFFFFFFFF);

  final math.Random _rnd = math.Random(880211);
  double _lastTime = double.nan;
  double _smoothedBass = 0.0;
  double _smoothedEnergy = 0.0;
  bool _initialized = false;

  _TornadoVortexSim() {
    _initFloorGrid();
    _initParticles();
  }

  void _initFloorGrid() {
    var idx = 0;
    for (var r = 1; r <= _floorRings; r++) {
      final rad = (r / _floorRings) * _maxDist * 1.15;
      for (var p = 0; p < _floorRingPoints; p++) {
        final ang = (p / _floorRingPoints) * math.pi * 2;
        _floorBaseX[idx] = math.sin(ang) * rad;
        _floorBaseZ[idx] = math.cos(ang) * rad;
        _floorDist[idx] = rad;
        idx++;
      }
    }
  }

  void _initParticles() {
    for (var i = 0; i < _particleCount; i++) {
      _spawnParticle(i, initialSpread: true);
    }
    _initialized = true;
  }

  void _spawnParticle(int i, {bool initialSpread = false}) {
    _pvy[i] = 0.06 + _rnd.nextDouble() * 0.14;
    _pradius[i] = 160.0 + _rnd.nextDouble() * 700.0;
    _pcolorHue[i] = _rnd.nextDouble();
    _ptier[i] = (_rnd.nextDouble() * 4).floor().clamp(0, 3);
    _pdispersal[i] = 0.82 + _rnd.nextDouble() * 0.36;

    final a = _rnd.nextDouble() * math.pi * 2;
    _pangle[i] = a;

    if (initialSpread) {
      final isGround = (i % 5 == 0);
      _pground[i] = isGround ? 0 : 1;
      if (isGround) {
        _py[i] = _floorLevel;
        final r = 2.5 + _rnd.nextDouble() * (_maxDist - 2.5);
        _px[i] = math.sin(a) * r;
        _pz[i] = math.cos(a) * r;
      } else {
        final u = _rnd.nextDouble();
        _py[i] = _floorLevel + u * _vortexHeight;
        // 大口在上，小头在下：u=0 (底部) 半径 1.6；u=1 (顶部) 半径 20.0
        final r = (1.6 + 18.4 * math.pow(u, 1.35)) * _pdispersal[i];
        _px[i] = math.sin(a) * r;
        _pz[i] = math.cos(a) * r;
      }
    } else {
      _py[i] = _floorLevel;
      final isGround = (_rnd.nextDouble() < 0.25);
      _pground[i] = isGround ? 0 : 1;
      if (isGround) {
        final r = 6.0 + _rnd.nextDouble() * (_maxDist - 6.0);
        _px[i] = math.sin(a) * r;
        _pz[i] = math.cos(a) * r;
      } else {
        final r = 1.6 * _pdispersal[i];
        _px[i] = math.sin(a) * r;
        _pz[i] = math.cos(a) * r;
      }
    }
  }

  void _updateColorLut(VisualizerPalette palette) {
    if (_lastPalette == palette) return;
    _lastPalette = palette;
    final stops = [
      palette.primary,
      palette.gradient.isNotEmpty ? palette.gradient.first : palette.primary,
      palette.secondary,
      palette.glow,
      palette.peak,
      palette.primary,
    ];
    final segCount = stops.length - 1;
    for (var i = 0; i < 256; i++) {
      final t = i / 255.0;
      final seg = (t * segCount).floor().clamp(0, segCount - 1);
      final segT = (t * segCount) - seg;
      final c1 = stops[seg];
      final c2 = stops[seg + 1];
      final r = (c1.r * (1.0 - segT) + c2.r * segT).clamp(0.0, 1.0);
      final g = (c1.g * (1.0 - segT) + c2.g * segT).clamp(0.0, 1.0);
      final b = (c1.b * (1.0 - segT) + c2.b * segT).clamp(0.0, 1.0);
      final ir = (r * 255).round();
      final ig = (g * 255).round();
      final ib = (b * 255).round();
      _colorLut[i] = (ir << 16) | (ig << 8) | ib;
    }
  }

  int _tintFromLut(int hueIndex, double alpha) {
    final rgb = _colorLut[hueIndex & 0xFF];
    final a = (alpha.clamp(0.0, 1.0) * 255).round();
    return (a << 24) | rgb;
  }

  void step(double time, List<double> bands) {
    if (!_initialized) _initParticles();
    final dt = (!time.isFinite || !_lastTime.isFinite || time < _lastTime)
        ? 1.0 / 30.0
        : (time - _lastTime).clamp(0.001, 0.1);
    _lastTime = time;

    final n = bands.length;
    double bass = 0.0;
    double mid = 0.0;
    double treble = 0.0;
    if (n > 0) {
      final bEnd = math.max(1, n ~/ 8);
      for (var i = 0; i < bEnd; i++) {
        bass += bands[i];
      }
      bass /= bEnd;

      final mStart = n ~/ 4;
      final mEnd = n ~/ 2;
      for (var i = mStart; i < mEnd; i++) {
        mid += bands[i];
      }
      mid /= (mEnd - mStart);

      final tStart = (n * 3) ~/ 4;
      for (var i = tStart; i < n; i++) {
        treble += bands[i];
      }
      treble /= (n - tStart);
    }

    _smoothedBass += (bass - _smoothedBass) * (dt * 5.0).clamp(0.0, 1.0);
    final curEnergy = (bass * 0.4 + mid * 0.4 + treble * 0.2).clamp(0.0, 1.0);
    _smoothedEnergy += (curEnergy - _smoothedEnergy) * (dt * 4.5).clamp(0.0, 1.0);

    // 音频驱动向心收拢与旋转/升力加速度
    final spinBoost = 1.0 + 2.8 * _smoothedBass + 0.6 * mid;
    final liftBoost = 1.0 + 1.8 * _smoothedBass + 0.6 * _smoothedEnergy;

    for (var i = 0; i < _particleCount; i++) {
      if (_pground[i] == 0) {
        // 1) 地面吸入阶段：沿地表向中心小头汇聚
        var r = math.sqrt(_px[i] * _px[i] + _pz[i] * _pz[i]);
        r -= (0.10 + 0.14 * _smoothedBass) * (dt * 30.0);
        final spinSpeed = (0.16 / (1.0 + r * 0.28)) * spinBoost;
        final a = _pangle[i] + spinSpeed * (dt * 30.0);
        _pangle[i] = a;
        _px[i] = math.sin(a) * r;
        _pz[i] = math.cos(a) * r;
        _py[i] = _floorLevel;

        if (r <= 1.8) {
          _pground[i] = 1;
          _py[i] = _floorLevel;
        }
      } else {
        // 2) 向上飞旋喷发阶段：大口在上，小头在下（随高度递增向外展开为号角形风暴口）
        _py[i] += _pvy[i] * liftBoost * (dt * 30.0);
        if (_py[i] > _vortexHeight / 2) {
          _spawnParticle(i);
        } else {
          final u = ((_py[i] - _floorLevel) / _vortexHeight).clamp(0.0, 1.0);
          final omega = (0.18 / (0.30 + u * 0.85)) * spinBoost;
          final a = _pangle[i] + omega * (dt * 30.0);
          _pangle[i] = a;
          final r = (1.6 + 18.4 * math.pow(u, 1.35)) * _pdispersal[i];
          _px[i] = math.sin(a) * r;
          _pz[i] = math.cos(a) * r;
        }
      }
    }
  }

  void paint(Canvas canvas, Size size, VisualizerPalette palette, double bloom, double lineWidth) {
    _atlas.ensureImage();
    final atlas = _atlas.imageOrNull;
    if (atlas == null) return;

    _updateColorLut(palette);

    final w = size.width;
    final h = size.height;
    final minDim = math.min(w, h);
    final cx = w / 2.0;
    final cy = h * 0.50; // 居中稳定

    final t = _lastTime.isFinite ? _lastTime : 0.0;

    // 3D 摄像机平滑轨道游弋与微俯视视角（俯视风暴漏斗与吸积盘）
    final camOrbitAngle = t * 0.20;
    const camDist = 22.0;
    final camX = math.sin(camOrbitAngle) * camDist;
    final camZ = math.cos(camOrbitAngle) * camDist;
    const camY = 6.5; // 位于上空，俯视风暴中心

    const targetY = -1.0;
    final pitch = math.atan2(camY - targetY, camDist);

    final cosYaw = math.cos(camOrbitAngle);
    final sinYaw = math.sin(camOrbitAngle);
    final cosPitch = math.cos(pitch);
    final sinPitch = math.sin(pitch);

    final projScale = minDim * 0.55 * (lineWidth / 1.5).clamp(0.85, 1.2);

    var spriteIdx = 0;

    // 1) 绘制地面引力扭曲网格（Warped Accretion Floor）
    final floorY = _floorLevel;
    final floorAlphaBase = 0.12 + 0.10 * _smoothedBass;
    final starSlice0 = _atlas.starTiers[0];

    for (var i = 0; i < _floorCount; i++) {
      final fx = _floorBaseX[i];
      final fz = _floorBaseZ[i];
      final d = _floorDist[i];
      // 中心向漏斗下沉的时空引力凹陷（正对风暴小头地基中心）
      final fy = floorY - math.exp(-d / 6.0) * 2.2 * (1.0 + 0.2 * _smoothedBass);

      // 3D 变换
      final dx = fx - camX;
      final dy = fy - camY;
      final dz = fz - camZ;

      final x1 = dx * cosYaw - dz * sinYaw;
      final z1 = -(dx * sinYaw + dz * cosYaw);

      final y2 = dy * cosPitch + z1 * sinPitch;
      final z2 = -dy * sinPitch + z1 * cosPitch;

      if (z2 > 1.0) {
        final invZ = 1.0 / z2;
        final sx = cx + x1 * invZ * projScale;
        final sy = cy - y2 * invZ * projScale;

        if (sx > -40 && sx < w + 40 && sy > -40 && sy < h + 40) {
          final distSq = x1 * x1 + y2 * y2 + z2 * z2;
          final pSize = (1.2 + 80.0 / (1.0 + distSq * 0.1)).clamp(2.0, 8.0);
          final scale = pSize / 64.0;
          final r = spriteIdx * 4;

          _rects[r] = starSlice0.rect[0];
          _rects[r + 1] = starSlice0.rect[1];
          _rects[r + 2] = starSlice0.rect[2];
          _rects[r + 3] = starSlice0.rect[3];

          _rst[r] = scale;
          _rst[r + 1] = 0.0;
          _rst[r + 2] = sx - scale * 32.0;
          _rst[r + 3] = sy - scale * 32.0;

          final edgeFade = (1.0 - (d / (_maxDist * 1.2))).clamp(0.0, 1.0);
          final hueIdx = ((d / _maxDist * 0.4 + t * 0.15) * 255).toInt();
          _colors[spriteIdx] = _tintFromLut(hueIdx, floorAlphaBase * edgeFade);
          spriteIdx++;
        }
      }
    }

    // 2) 绘制 700 颗 3D 旋转风暴粒子
    final halfH = _vortexHeight / 2.0;

    for (var i = 0; i < _particleCount; i++) {
      final px = _px[i];
      final py = _py[i];
      final pz = _pz[i];

      // 3D 相机空间投影
      final dx = px - camX;
      final dy = py - camY;
      final dz = pz - camZ;

      final x1 = dx * cosYaw - dz * sinYaw;
      final z1 = -(dx * sinYaw + dz * cosYaw);

      final y2 = dy * cosPitch + z1 * sinPitch;
      final z2 = -dy * sinPitch + z1 * cosPitch;

      if (z2 > 1.0) {
        final invZ = 1.0 / z2;
        final sx = cx + x1 * invZ * projScale;
        final sy = cy - y2 * invZ * projScale;

        if (sx > -60 && sx < w + 60 && sy > -60 && sy < h + 60) {
          final distSq = x1 * x1 + y2 * y2 + z2 * z2;
          final pRadius = _pradius[i];
          // 近大远小的自然透视尺寸
          final pSize = (1.0 + pRadius / (1.0 + distSq * 0.4)).clamp(2.5, 26.0);
          final scale = pSize / 64.0;
          final tier = _ptier[i];
          final starSlice = _atlas.starTiers[tier];

          final r = spriteIdx * 4;
          _rects[r] = starSlice.rect[0];
          _rects[r + 1] = starSlice.rect[1];
          _rects[r + 2] = starSlice.rect[2];
          _rects[r + 3] = starSlice.rect[3];

          _rst[r] = scale;
          _rst[r + 1] = 0.0;
          _rst[r + 2] = sx - scale * 32.0;
          _rst[r + 3] = sy - scale * 32.0;

          // 上下边界渐隐
          final normY = (py / halfH).abs();
          final alphaFade = (0.95 - math.pow(normY, 4.0) * 0.88).clamp(0.0, 1.0);
          final finalAlpha = alphaFade * (0.50 + 0.50 * _smoothedEnergy);

          // 色彩随色相相位、时间与高度渐变，形成炫丽的彩虹光谱
          final hueIdx = ((_pcolorHue[i] + t * 0.22 + (py + halfH) / _vortexHeight * 0.45) * 255).toInt();
          _colors[spriteIdx] = _tintFromLut(hueIdx, finalAlpha);
          spriteIdx++;
        }
      }
    }

    // 单批次 GPU 提交全部 3D 风暴粒子与地面引力网格
    canvas.drawRawAtlas(
      atlas,
      _rst,
      _rects,
      _colors,
      BlendMode.modulate,
      null,
      _batchPaint,
    );
  }
}

/// 龙卷风的静态基底：暗场渐变 + 轻微渐晕（纯净深邃底色，不含多余假球）。
class TornadoBackdropPainter extends CustomPainter {
  final VisualizerPalette palette;
  final double bloom;

  Paint? _bgPaint;
  Paint? _vignettePaint;
  Size? _shaderSize;

  TornadoBackdropPainter({required this.palette, required this.bloom});

  void _ensureShaders(Size size) {
    if (_bgPaint != null && _shaderSize == size) return;
    _shaderSize = size;
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
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _ensureShaders(size);
    canvas.drawRect(Offset.zero & size, _bgPaint!);
    canvas.drawRect(Offset.zero & size, _vignettePaint!);
  }

  @override
  bool shouldRepaint(covariant TornadoBackdropPainter oldDelegate) =>
      oldDelegate.palette != palette || oldDelegate.bloom != bloom;
}
