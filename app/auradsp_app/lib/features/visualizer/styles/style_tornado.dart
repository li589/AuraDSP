import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/visualizer_themes.dart';
import 'visualizer_sprite_atlas.dart';
import 'visualizer_time_aware.dart';

typedef TornadoParticleMetrics = ({
  int particleCount,
  int trailSamples,
  int batchCount,
  double meanHeight,
  double centroidX,
  double mirrorError,
  double speed,
  double spread,
  double brightness,
});

typedef TornadoAtlasBuffers = ({
  Float32List transforms,
  Float32List rects,
  Int32List colors,
  int spriteCount,
  int capacity,
});

/// Deterministic 3D helical particle flow inspired by the reference canvas.
///
/// The painter owns one reusable simulation and one set of typed atlas buffers.
/// Frames do not allocate particle objects, projection lists, paths, or shaders.
class TornadoParticlePainter extends CustomPainter
    implements VisualizerTimeAware {
  final List<double> bands;
  final VisualizerPalette palette;
  final double bloom;
  final double sensitivity;
  double time;

  final _TornadoParticleField _field = _TornadoParticleField();

  TornadoParticlePainter({
    required this.bands,
    required this.palette,
    required this.bloom,
    required this.time,
    this.sensitivity = 1.0,
  });

  @override
  void setVisualizerTime(double time) => this.time = time;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _field.render(canvas, size, time, bands, palette, bloom, sensitivity);
  }

  @override
  bool shouldRepaint(covariant TornadoParticlePainter oldDelegate) => true;

  @visibleForTesting
  Float32List get debugParticlePositions => _field.positions;

  @visibleForTesting
  TornadoAtlasBuffers get debugAtlasBuffers => _field.debugAtlasBuffers;

  @visibleForTesting
  TornadoParticleMetrics get debugParticleMetrics => _field.debugMetrics;
}

/// Reusable CPU simulation, projection, and atlas submission seam.
class _TornadoParticleField {
  static const int particleCount = 900;
  static const int trailSamples = 3;
  static const int _spriteCapacity = particleCount * (trailSamples + 1);
  static const double _tau = math.pi * 2;
  static const double _floor = -6.0;
  static const double _height = 12.0;
  static const double _cameraDistance = 18.0;
  static const double _trailStep = 0.035;

  static final Float32List _radiusProfile = _buildRadiusProfile();

  final Float32List _heightU = Float32List(particleCount);
  final Float32List _angle = Float32List(particleCount);
  final Float32List _seedHeight = Float32List(particleCount);
  final Float32List _seedAngle = Float32List(particleCount);
  final Float32List _seedPositions = Float32List(particleCount * 3);
  final Float32List _radiusJitter = Float32List(particleCount);
  final Float32List _riseSpeed = Float32List(particleCount);
  final Float32List _spinBias = Float32List(particleCount);
  final Float32List _particleSize = Float32List(particleCount);
  final Float32List _baseBrightness = Float32List(particleCount);
  final Float32List _colorPhase = Float32List(particleCount);
  final Float32List _verticalVelocity = Float32List(particleCount);
  final Float32List _angularVelocity = Float32List(particleCount);
  final Int32List _tier = Int32List(particleCount);

  final Float32List positions = Float32List(particleCount * 3);
  final Float32List _depth = Float32List(particleCount);
  final Int32List _order = Int32List(particleCount);
  final Float32List _transforms = Float32List(_spriteCapacity * 4);
  final Float32List _rects = Float32List(_spriteCapacity * 4);
  final Int32List _colors = Int32List(_spriteCapacity);
  final Float32List _trailWorld = Float32List(3);
  final Float32List _mirrorBins = Float32List(32);

  final VisualizerSpriteAtlas _atlas = VisualizerSpriteAtlas.instance;
  final Paint _batchPaint = Paint()
    ..filterQuality = FilterQuality.low
    ..isAntiAlias = true
    ..color = const Color(0xFFFFFFFF);
  final Int32List _colorLut = Int32List(256);

  VisualizerPalette? _lutPalette;
  double _lastTime = double.nan;
  double _flow = 0.0;
  double _smoothedBass = 0.0;
  double _smoothedMid = 0.0;
  double _smoothedTreble = 0.0;
  double _smoothedEnergy = 0.0;
  double _speedFactor = 1.0;
  double _spreadFactor = 1.0;
  double _brightness = 0.62;
  double _meanHeight = 0.0;
  double _centroidX = 0.0;
  double _mirrorError = 0.0;
  int _spriteCount = 0;
  int _batchCount = 0;

  double _cosYaw = 1.0;
  double _sinYaw = 0.0;
  double _cosPitch = 1.0;
  double _sinPitch = 0.0;
  double _projectionScale = 1.0;
  double _pixelScale = 1.0;
  double _centerX = 0.0;
  double _centerY = 0.0;
  double _projectedX = 0.0;
  double _projectedY = 0.0;
  double _projectedDepth = 0.0;

  _TornadoParticleField() {
    final random = math.Random(0x70A0D);
    for (var i = 0; i < particleCount; i++) {
      _heightU[i] = random.nextDouble();
      _angle[i] = random.nextDouble() * _tau;
      _radiusJitter[i] = 0.76 + random.nextDouble() * 0.48;
      _riseSpeed[i] = 0.78 + random.nextDouble() * 0.44;
      _spinBias[i] = 0.82 + random.nextDouble() * 0.36;
      _particleSize[i] = random.nextDouble();
      _baseBrightness[i] = 0.52 + random.nextDouble() * 0.48;
      _colorPhase[i] = random.nextDouble();
      _tier[i] = (random.nextDouble() * 4).floor().clamp(0, 3);
      _order[i] = i;
    }
    for (var i = 0; i < particleCount; i++) {
      _writePosition(i, _heightU[i], _angle[i], 1.0, positions, i * 3);
    }
    _seedHeight.setAll(0, _heightU);
    _seedAngle.setAll(0, _angle);
    _seedPositions.setAll(0, positions);
  }

  static Float32List _buildRadiusProfile() {
    final profile = Float32List(256);
    for (var i = 0; i < profile.length; i++) {
      profile[i] = 0.20 + 3.85 * math.pow(i / 255.0, 0.82);
    }
    return profile;
  }

  void _reset() {
    _heightU.setAll(0, _seedHeight);
    _angle.setAll(0, _seedAngle);
    positions.setAll(0, _seedPositions);
    _flow = 0.0;
    _lastTime = double.nan;
    _smoothedBass = 0.0;
    _smoothedMid = 0.0;
    _smoothedTreble = 0.0;
    _smoothedEnergy = 0.0;
    _speedFactor = 1.0;
    _spreadFactor = 1.0;
    _brightness = 0.62;
  }

  void _step(double time, List<double> bands, double sensitivity) {
    if (!time.isFinite) time = 0.0;
    if (_lastTime.isFinite && time < _lastTime) _reset();
    final firstFrame = !_lastTime.isFinite;
    final dt = firstFrame ? 1.0 / 30.0 : (time - _lastTime).clamp(0.0, 0.1);
    _lastTime = time;
    if (!firstFrame && dt == 0.0) return;

    var bass = 0.0;
    var mid = 0.0;
    var treble = 0.0;
    final n = bands.length;
    if (n > 0) {
      final bassEnd = math.max(1, n ~/ 8);
      final midStart = n ~/ 4;
      final midEnd = math.max(midStart + 1, n ~/ 2);
      final trebleStart = (n * 3) ~/ 4;
      for (var i = 0; i < bassEnd; i++) {
        bass += bands[i].isFinite ? bands[i] : 0.0;
      }
      for (var i = midStart; i < midEnd; i++) {
        mid += bands[i].isFinite ? bands[i] : 0.0;
      }
      for (var i = trebleStart; i < n; i++) {
        treble += bands[i].isFinite ? bands[i] : 0.0;
      }
      bass = (bass / bassEnd * sensitivity).clamp(0.0, 1.25);
      mid = (mid / (midEnd - midStart) * sensitivity).clamp(0.0, 1.25);
      treble = (treble / (n - trebleStart) * sensitivity).clamp(0.0, 1.25);
    }
    final energy = (bass * 0.42 + mid * 0.38 + treble * 0.20).clamp(0.0, 1.0);
    if (firstFrame) {
      _smoothedBass = bass;
      _smoothedMid = mid;
      _smoothedTreble = treble;
      _smoothedEnergy = energy;
    } else {
      final audioEase = 1.0 - math.exp(-dt * 5.0);
      _smoothedBass += (bass - _smoothedBass) * audioEase;
      _smoothedMid += (mid - _smoothedMid) * audioEase;
      _smoothedTreble += (treble - _smoothedTreble) * audioEase;
      _smoothedEnergy += (energy - _smoothedEnergy) * audioEase;
    }

    final targetSpeed = 1.0 + _smoothedBass * 1.25 + _smoothedMid * 0.32;
    final targetSpread = 1.0 + _smoothedBass * 0.10 + _smoothedMid * 0.18;
    final targetBrightness = 0.62 + _smoothedEnergy * 0.38;
    if (firstFrame) {
      _speedFactor = targetSpeed;
      _spreadFactor = targetSpread;
      _brightness = targetBrightness;
    } else {
      final motionEase = 1.0 - math.exp(-dt * 4.0);
      _speedFactor += (targetSpeed - _speedFactor) * motionEase;
      _spreadFactor += (targetSpread - _spreadFactor) * motionEase;
      _brightness += (targetBrightness - _brightness) * motionEase;
    }
    _flow += dt * 0.50 * _speedFactor;

    for (var i = 0; i < particleCount; i++) {
      var u = _heightU[i] + dt * (0.058 + 0.022 * _riseSpeed[i]) * _speedFactor;
      if (u >= 1.0) u -= 1.0;
      _heightU[i] = u;
      _verticalVelocity[i] = (0.058 + 0.022 * _riseSpeed[i]) * _speedFactor;
      final omega =
          (1.15 / (0.38 + u * 1.25) + 0.35 * _spinBias[i]) * _speedFactor;
      _angularVelocity[i] = omega;
      final angle = (_angle[i] + dt * omega) % _tau;
      _angle[i] = angle;
      _writePosition(i, u, angle, _spreadFactor, positions, i * 3);
    }
    _measureDistribution();
  }

  void _writePosition(
    int i,
    double u,
    double angle,
    double spread,
    Float32List out,
    int offset,
  ) {
    u = u.clamp(0.0, 1.0);
    final profileIndex = (u * 255.0).round().clamp(0, 255);
    final radius = _radiusProfile[profileIndex] * _radiusJitter[i] * spread;
    final turbulence =
        math.sin(u * 13.0 + _colorPhase[i] * _tau + _flow * 0.7) * 0.09 +
        math.sin(u * 27.0 - _colorPhase[i] * 11.0 - _flow * 0.43) * 0.035;
    final bendX =
        math.sin(_flow * 0.82 + u * 2.4) * 0.48 +
        math.sin(u * 9.0 - _flow * 0.37) * 0.14;
    final bendZ =
        math.cos(_flow * 0.69 - u * 2.1) * 0.34 +
        math.cos(u * 8.1 + _flow * 0.41) * 0.12;
    final r = radius + turbulence * (0.70 + spread * 0.30);
    out[offset] = bendX + math.cos(angle) * r;
    out[offset + 1] = _floor + u * _height;
    out[offset + 2] = bendZ + math.sin(angle) * r * 0.88;
  }

  void _measureDistribution() {
    _mirrorBins.fillRange(0, _mirrorBins.length, 0.0);
    var heightSum = 0.0;
    var centroidSum = 0.0;
    for (var i = 0; i < particleCount; i++) {
      final offset = i * 3;
      final x = positions[offset];
      final u = (positions[offset + 1] - _floor) / _height;
      heightSum += u;
      centroidSum += x;
      final bin = ((x.abs() / 5.5) * (_mirrorBins.length - 1)).floor().clamp(
        0,
        _mirrorBins.length - 1,
      );
      _mirrorBins[bin] += x < 0 ? -1.0 : 1.0;
    }
    var mismatch = 0.0;
    var total = 0.0;
    for (var i = 0; i < _mirrorBins.length; i += 2) {
      final difference = (_mirrorBins[i] - _mirrorBins[i + 1]).abs();
      mismatch += difference;
      total += (_mirrorBins[i] + _mirrorBins[i + 1]).abs();
    }
    _meanHeight = heightSum / particleCount;
    _centroidX = centroidSum / particleCount;
    _mirrorError = total == 0 ? 0.0 : mismatch / total;
  }

  void render(
    Canvas canvas,
    Size size,
    double time,
    List<double> bands,
    VisualizerPalette palette,
    double bloom,
    double sensitivity,
  ) {
    _step(time, bands, sensitivity);
    _atlas.ensureImage();
    final image = _atlas.imageOrNull;
    if (image == null) return;

    _resolveColorLut(palette, bloom);
    final minDimension = math.min(size.width, size.height);
    final yaw = 0.22 + math.sin(_flow * 0.47) * 0.16;
    final pitch = 0.16 + math.sin(_flow * 0.19) * 0.025;
    _cosYaw = math.cos(yaw);
    _sinYaw = math.sin(yaw);
    _cosPitch = math.cos(pitch);
    _sinPitch = math.sin(pitch);
    _projectionScale = minDimension * 1.38;
    _pixelScale = math.sqrt(minDimension / 320.0).clamp(0.65, 1.8);
    _centerX = size.width * 0.5;
    _centerY = size.height * 0.50;

    for (var i = 0; i < particleCount; i++) {
      final offset = i * 3;
      _project(positions[offset], positions[offset + 1], positions[offset + 2]);
      _depth[i] = _projectedDepth;
    }
    _sortByDepth();

    _spriteCount = 0;
    // drawRawAtlas consumes the full typed buffers. Clear unused color slots so
    // a smaller visible count cannot reuse stale sprites from the prior frame.
    _colors.fillRange(0, _spriteCapacity, 0);
    for (var orderIndex = particleCount - 1; orderIndex >= 0; orderIndex--) {
      _renderParticle(_order[orderIndex], size);
    }
    if (_spriteCount == 0) return;

    canvas.drawRawAtlas(
      image,
      _transforms,
      _rects,
      _colors,
      BlendMode.modulate,
      null,
      _batchPaint,
    );
    _batchCount++;
  }

  bool _project(double x, double y, double z) {
    final rx = x * _cosYaw - z * _sinYaw;
    final rz = x * _sinYaw + z * _cosYaw;
    final depth = _cameraDistance - rz;
    if (depth <= 1.0) return false;
    final ry = y * _cosPitch - rz * _sinPitch;
    final perspective = _projectionScale / depth;
    _projectedX = _centerX + rx * perspective;
    _projectedY = _centerY - ry * perspective;
    _projectedDepth = depth;
    return true;
  }

  void _sortByDepth() {
    for (var start = (particleCount - 2) ~/ 2; start >= 0; start--) {
      _siftDown(start, particleCount);
    }
    for (var end = particleCount - 1; end > 0; end--) {
      final first = _order[0];
      _order[0] = _order[end];
      _order[end] = first;
      _siftDown(0, end);
    }
  }

  void _siftDown(int root, int count) {
    while (true) {
      var child = root * 2 + 1;
      if (child >= count) return;
      if (child + 1 < count &&
          _depth[_order[child + 1]] > _depth[_order[child]]) {
        child++;
      }
      if (_depth[_order[root]] >= _depth[_order[child]]) return;
      final swap = _order[root];
      _order[root] = _order[child];
      _order[child] = swap;
      root = child;
    }
  }

  void _renderParticle(int i, Size size) {
    final offset = i * 3;
    if (!_project(
      positions[offset],
      positions[offset + 1],
      positions[offset + 2],
    )) {
      return;
    }
    final x = _projectedX;
    final y = _projectedY;
    final depth = _projectedDepth;
    final diameter =
        ((1.35 + _particleSize[i] * 2.25) *
                (18.0 / depth) *
                _pixelScale *
                (1.0 + _smoothedTreble * 0.06))
            .clamp(1.1, 9.0);
    final margin = diameter * 2.0 + 8.0;
    if (x < -margin ||
        x > size.width + margin ||
        y < -margin ||
        y > size.height + margin) {
      return;
    }

    final u = _heightU[i];
    final slice = _atlas.starTiers[_tier[i]];
    final hue = ((_colorPhase[i] + u * 0.32 + _flow * 0.025) * 255.0)
        .toInt()
        .clamp(0, 255);
    final rgb = _colorLut[hue] & 0x00FFFFFF;
    final edgeFade =
        _smoothstep(0.0, 0.07, u) * (1.0 - _smoothstep(0.90, 1.0, u));
    final headAlpha = _baseBrightness[i] * _brightness * edgeFade;

    for (var trail = trailSamples; trail >= 1; trail--) {
      final trailU = u - _verticalVelocity[i] * _trailStep * trail;
      if (trailU < 0.0) continue;
      final trailAngle = _angle[i] - _angularVelocity[i] * _trailStep * trail;
      _writePosition(i, trailU, trailAngle, _spreadFactor, _trailWorld, 0);
      if (!_project(_trailWorld[0], _trailWorld[1], _trailWorld[2])) continue;
      final trailAlpha = switch (trail) {
        1 => 0.22,
        2 => 0.11,
        _ => 0.05,
      };
      _appendSprite(
        slice,
        _projectedX,
        _projectedY,
        diameter * (1.0 - trail * 0.22),
        _argb(rgb, headAlpha * trailAlpha),
      );
    }
    _appendSprite(slice, x, y, diameter, _argb(rgb, headAlpha));
  }

  void _appendSprite(
    SpriteSlice slice,
    double x,
    double y,
    double diameter,
    int color,
  ) {
    if (_spriteCount >= _spriteCapacity) return;
    final offset = _spriteCount * 4;
    _rects[offset] = slice.rect[0];
    _rects[offset + 1] = slice.rect[1];
    _rects[offset + 2] = slice.rect[2];
    _rects[offset + 3] = slice.rect[3];
    final scale = diameter / 64.0;
    _transforms[offset] = scale;
    _transforms[offset + 1] = 0.0;
    _transforms[offset + 2] = x - scale * 32.0;
    _transforms[offset + 3] = y - scale * 32.0;
    _colors[_spriteCount] = color;
    _spriteCount++;
  }

  int _argb(int rgb, double alpha) {
    final a = (alpha.clamp(0.0, 1.0) * 255.0).round();
    return (a << 24) | rgb;
  }

  double _smoothstep(double edge0, double edge1, double value) {
    final t = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  void _resolveColorLut(VisualizerPalette palette, double bloom) {
    if (identical(_lutPalette, palette) && _lutBloom == bloom) return;
    _lutPalette = palette;
    _lutBloom = bloom;
    final stops = <Color>[
      palette.primary,
      palette.gradient.isNotEmpty ? palette.gradient.first : palette.secondary,
      palette.secondary,
      palette.peak,
    ];
    for (var i = 0; i < _colorLut.length; i++) {
      final scaled = (i / 255.0) * (stops.length - 1);
      final low = scaled.floor().clamp(0, stops.length - 2);
      final color = Color.lerp(stops[low], stops[low + 1], scaled - low)!;
      _colorLut[i] = color.toARGB32() & 0x00FFFFFF;
    }
  }

  double? _lutBloom;

  TornadoAtlasBuffers get debugAtlasBuffers => (
    transforms: _transforms,
    rects: _rects,
    colors: _colors,
    spriteCount: _spriteCount,
    capacity: _spriteCapacity,
  );

  TornadoParticleMetrics get debugMetrics => (
    particleCount: particleCount,
    trailSamples: trailSamples,
    batchCount: _batchCount,
    meanHeight: _meanHeight,
    centroidX: _centroidX,
    mirrorError: _mirrorError,
    speed: _speedFactor,
    spread: _spreadFactor,
    brightness: _brightness,
  );
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
        // Opaque dark stops avoid a hard transparent band at the midpoint
        // while retaining the existing restrained teal/magenta dark field.
        colors: [
          Color.lerp(
            const Color(0xFF05090E),
            palette.primary,
            0.035 + bloom * 0.035,
          )!,
          const Color(0xFF04080D),
          Color.lerp(
            const Color(0xFF05090E),
            palette.secondary,
            0.070 + bloom * 0.050,
          )!,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Offset.zero & size);

    _vignettePaint = Paint()
      ..shader = RadialGradient(
        colors: const [Color(0x00000000), Color(0x12000000), Color(0x56000000)],
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
