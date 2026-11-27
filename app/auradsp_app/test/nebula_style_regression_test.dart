import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/shaders/gpu_shader_service.dart';
import 'package:auradsp_app/features/visualizer/styles/style_gpu_shader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _width = 720;
const _height = 480;
const _size = Size(720, 480);

// Black nebula colors isolate the real shader's additive star layer. The FBM
// and color mapping still execute, but cannot contaminate the star metrics.
const _blackPalette = VisualizerPalette(
  primary: Color(0xFF000000),
  secondary: Color(0xFF000000),
  peak: Color(0xFF000000),
  grid: Color(0xFF000000),
  glow: Color(0xFF000000),
  gradient: [Color(0xFF000000), Color(0xFF000000)],
);

const _palette = VisualizerPalette(
  primary: Color(0xFF00E5FF),
  secondary: Color(0xFFFF007F),
  peak: Color(0xFFFFFFFF),
  grid: Color(0x1A00E5FF),
  glow: Color(0x8000E5FF),
  gradient: [Color(0xFF0055FF), Color(0xFF00E5FF)],
);

typedef _Peak = ({int x, int y, double value});
typedef _TwinkleMetrics = ({int persistent, int brightened, int dimmed});
typedef _ShapeMetrics = ({int count, double cornerFill, double haloRatio});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    expect(
      await GpuShaderService.instance.ensureCompiled(GpuShaderType.nebula),
      isTrue,
      reason: 'The regression must rasterize the real nebula shader.',
    );
  });

  test('nebula vignette avoids undefined reversed smoothstep edges', () async {
    final source = await File('shaders/nebula_flow.frag').readAsString();
    expect(
      RegExp(r'smoothstep\(\s*1\.4\s*,\s*0\.35\s*,').hasMatch(source),
      isFalse,
      reason: 'GLSL smoothstep is undefined when edge0 is greater than edge1.',
    );
  });

  test(
    'persistent stars brighten and dim independently at fixed times',
    () async {
      final first = await _rasterize(0.20);
      final second = await _rasterize(0.45);
      _expectIndependentTwinkle(first, second);
    },
  );

  test('bright star footprints are round with a soft outer halo', () async {
    _expectRoundSoftStars(await _rasterize(0.0));
  });

  test('stars drift independently instead of staying on a fixed lattice', () async {
    final first = await _rasterize(8.0);
    final second = await _rasterize(16.0);
    final peaks = _isolatedPeaks(_findPeaks(first));
    final displacements = <({double x, double y})>[];

    for (final peak in peaks) {
      if (_patchMax(second, peak.x, peak.y, 7) < 0.012) continue;
      final before = _footprintCentroid(first, peak.x, peak.y, 7);
      final after = _footprintCentroid(second, peak.x, peak.y, 7);
      displacements.add((x: after.x - before.x, y: after.y - before.y));
    }

    final distances = displacements
        .map((move) => math.sqrt(move.x * move.x + move.y * move.y))
        .toList();
    final moving = distances.where((distance) => distance > 0.04).length;
    final median = _median(distances);
    final hasLeft = displacements.any((move) => move.x < -0.03);
    final hasRight = displacements.any((move) => move.x > 0.03);
    final hasUp = displacements.any((move) => move.y < -0.03);
    final hasDown = displacements.any((move) => move.y > 0.03);

    expect(
      displacements.length,
      greaterThan(12),
      reason: 'The drift sample needs enough isolated, visible stars.',
    );
    expect(
      moving,
      greaterThanOrEqualTo(math.max(4, (displacements.length * 0.35).round())),
      reason:
          'Slow per-star drift must move a substantial subset; '
          '$moving of ${displacements.length} stars moved, median $median px.',
    );
    expect(
      median,
      greaterThan(0.04),
      reason: 'Median star displacement was $median px.',
    );
    expect(
      hasLeft && hasRight && hasUp && hasDown,
      isTrue,
      reason:
          'Drift directions must vary rather than translate one rigid grid.',
    );
  });

  test('nebula raster keeps a luminous center with radial falloff', () async {
    final pixels = await _rasterize(0.0, palette: _palette);
    final center = _patchMean(pixels, _width ~/ 2, _height ~/ 2, 32);
    final edge =
        [
          _patchMean(pixels, 36, 36, 20),
          _patchMean(pixels, _width - 36, 36, 20),
          _patchMean(pixels, 36, _height - 36, 20),
          _patchMean(pixels, _width - 36, _height - 36, 20),
        ].reduce((a, b) => a + b) /
        4;

    expect(center, greaterThan(0.03));
    expect(
      center,
      greaterThan(edge * 1.1),
      reason:
          'The vignette must preserve the core and soften corners: '
          'center=$center edge=$edge',
    );
  });

  test('star raster controls distinguish squares and synchronized clocks', () {
    final round = _syntheticStars(square: false, synchronized: false);
    _expectRoundSoftStars(round);

    final square = _syntheticStars(square: true, synchronized: false);
    final squareMetrics = _measureStarShapes(square);
    expect(squareMetrics.count, greaterThan(12));
    expect(squareMetrics.cornerFill, greaterThan(0.06));
    expect(
      () => _expectRoundSoftStars(square),
      throwsA(isA<TestFailure>()),
      reason: 'The real shape thresholds must reject square control stars.',
    );

    final independentFirst = _syntheticStars(
      square: false,
      synchronized: false,
      time: 0.20,
    );
    final independentSecond = _syntheticStars(
      square: false,
      synchronized: false,
      time: 0.45,
    );
    _expectIndependentTwinkle(independentFirst, independentSecond);

    final synchronizedMetrics = _measureTwinkle(
      _syntheticStars(square: false, synchronized: true, time: 0.20),
      _syntheticStars(square: false, synchronized: true, time: 0.45),
    );
    expect(synchronizedMetrics.persistent, greaterThan(12));
    expect(synchronizedMetrics.dimmed, 0);
    expect(
      () => _expectIndependentTwinkle(
        _syntheticStars(square: false, synchronized: true, time: 0.20),
        _syntheticStars(square: false, synchronized: true, time: 0.45),
      ),
      throwsA(isA<TestFailure>()),
      reason: 'The real twinkle thresholds must reject synchronized controls.',
    );
  });
}

Future<Uint8List> _rasterize(
  double time, {
  VisualizerPalette palette = _blackPalette,
}) async {
  final painter = GpuShaderPainter(
    shaderType: GpuShaderType.nebula,
    bands: List<double>.filled(32, 0.0),
    palette: palette,
    time: time,
    sensitivity: 1.0,
  );
  final recorder = ui.PictureRecorder();
  painter.paint(ui.Canvas(recorder), _size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(_width, _height);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

_TwinkleMetrics _measureTwinkle(Uint8List first, Uint8List second) {
  var persistent = 0;
  var brightened = 0;
  var dimmed = 0;
  for (final peak in _findPeaks(first)) {
    final before = _patchMean(first, peak.x, peak.y, 3);
    final after = _patchMean(second, peak.x, peak.y, 3);
    if (before < 0.004 || after < 0.001) continue;
    persistent++;
    final delta = after - before;
    final visibleChange = math.max(0.001, before * 0.08);
    if (delta > visibleChange) brightened++;
    if (delta < -visibleChange) dimmed++;
  }
  return (persistent: persistent, brightened: brightened, dimmed: dimmed);
}

void _expectIndependentTwinkle(Uint8List first, Uint8List second) {
  final metrics = _measureTwinkle(first, second);
  expect(
    metrics.persistent,
    greaterThan(12),
    reason: 'The fixed-time sample must contain enough persistent stars.',
  );
  expect(
    metrics.brightened,
    greaterThanOrEqualTo(3),
    reason:
        'Independent clocks require some persistent stars to brighten; '
        'observed ${metrics.brightened} up / ${metrics.dimmed} down across '
        '${metrics.persistent} stars.',
  );
  expect(
    metrics.dimmed,
    greaterThanOrEqualTo(3),
    reason:
        'Independent clocks require other persistent stars to dim; '
        'observed ${metrics.brightened} up / ${metrics.dimmed} down across '
        '${metrics.persistent} stars.',
  );
}

_ShapeMetrics _measureStarShapes(Uint8List pixels) {
  final peaks = _isolatedPeaks(_findPeaks(pixels));
  final shapes = <({double cornerFill, double haloRatio})>[];
  for (final peak in peaks) {
    final shape = _footprintShape(pixels, peak);
    if (shape != null) shapes.add(shape);
  }
  return (
    count: shapes.length,
    cornerFill: _median(shapes.map((shape) => shape.cornerFill)),
    haloRatio: _median(shapes.map((shape) => shape.haloRatio)),
  );
}

void _expectRoundSoftStars(Uint8List pixels) {
  final metrics = _measureStarShapes(pixels);
  expect(metrics.count, greaterThan(12));
  expect(
    metrics.cornerFill,
    lessThan(0.03),
    reason:
        'A cell-clipped falloff fills the corners of a square footprint; '
        'median corner fill was ${metrics.cornerFill} across '
        '${metrics.count} stars.',
  );
  expect(
    metrics.haloRatio,
    greaterThan(1.8),
    reason:
        'The bright core needs a soft halo rather than a square plateau; '
        'median outer/core radius ratio was ${metrics.haloRatio}.',
  );
}

Uint8List _syntheticStars({
  required bool square,
  required bool synchronized,
  double time = 0,
}) {
  final pixels = Uint8List(_width * _height * 4);
  for (var star = 0; star < 16; star++) {
    final centerX = 100 + (star % 4) * 170;
    final centerY = 80 + (star ~/ 4) * 120;
    final phase = star * 2.399963229728653;
    final speed = 0.55 + (star % 5) * 0.20;
    final brightness = 0.18 + 0.14 * (star % 4) / 3;
    final twinkle = synchronized
        ? 0.55 + 0.45 * math.sin(time)
        : 0.55 + 0.45 * math.sin(time * speed + phase);
    for (var dy = -12; dy <= 12; dy++) {
      for (var dx = -12; dx <= 12; dx++) {
        final double core;
        final double halo;
        if (square) {
          final distance = math.max(dx.abs(), dy.abs());
          core = distance <= 2 ? 1.0 : 0.0;
          halo = math.max(0.0, 1.0 - distance / 10.0);
        } else {
          final distance = math.sqrt(dx * dx + dy * dy);
          core = math.max(0.0, 1.0 - distance / 2.2);
          halo = math.max(0.0, 1.0 - distance / 10.0);
        }
        final value = (core + 0.32 * halo * halo) * brightness * twinkle;
        final offset = ((centerY + dy) * _width + centerX + dx) * 4;
        final channel = (value * 255).round().clamp(0, 255);
        pixels[offset] = math.max(pixels[offset], channel);
        pixels[offset + 1] = math.max(pixels[offset + 1], channel);
        pixels[offset + 2] = math.max(pixels[offset + 2], channel);
        pixels[offset + 3] = 255;
      }
    }
  }
  return pixels;
}

double _luma(Uint8List pixels, int x, int y) {
  final i = (y * _width + x) * 4;
  return (pixels[i] + pixels[i + 1] + pixels[i + 2]) / (3.0 * 255.0);
}

List<_Peak> _findPeaks(Uint8List pixels) {
  final candidates = <_Peak>[];
  const margin = 14;
  for (var y = margin; y < _height - margin; y++) {
    for (var x = margin; x < _width - margin; x++) {
      final value = _luma(pixels, x, y);
      if (value < 0.012) continue;
      var isPeak = true;
      for (var dy = -1; dy <= 1 && isPeak; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          if (_luma(pixels, x + dx, y + dy) > value) {
            isPeak = false;
            break;
          }
        }
      }
      if (isPeak) candidates.add((x: x, y: y, value: value));
    }
  }
  candidates.sort((a, b) => b.value.compareTo(a.value));

  final peaks = <_Peak>[];
  for (final candidate in candidates) {
    final crowded = peaks.any((peak) {
      final dx = candidate.x - peak.x;
      final dy = candidate.y - peak.y;
      return dx * dx + dy * dy <= 36;
    });
    if (!crowded) peaks.add(candidate);
  }
  return peaks;
}

List<_Peak> _isolatedPeaks(List<_Peak> peaks) {
  return peaks.where((peak) {
    return peaks.every((other) {
      if (identical(peak, other)) return true;
      final dx = peak.x - other.x;
      final dy = peak.y - other.y;
      return dx * dx + dy * dy > 576;
    });
  }).toList();
}

double _patchMean(Uint8List pixels, int x, int y, int radius) {
  var sum = 0.0;
  var count = 0;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      sum += _luma(pixels, x + dx, y + dy);
      count++;
    }
  }
  return sum / count;
}

double _patchMax(Uint8List pixels, int x, int y, int radius) {
  var value = 0.0;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final sample = _luma(pixels, x + dx, y + dy);
      if (sample > value) value = sample;
    }
  }
  return value;
}

({double x, double y}) _footprintCentroid(
  Uint8List pixels,
  int x,
  int y,
  int radius,
) {
  final peak = _patchMax(pixels, x, y, radius);
  final threshold = math.max(1.0 / 255.0, peak * 0.03);
  var weight = 0.0;
  var sumX = 0.0;
  var sumY = 0.0;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final sample = _luma(pixels, x + dx, y + dy);
      if (sample < threshold) continue;
      weight += sample;
      sumX += (x + dx) * sample;
      sumY += (y + dy) * sample;
    }
  }
  return (x: sumX / weight, y: sumY / weight);
}

({double cornerFill, double haloRatio})? _footprintShape(
  Uint8List pixels,
  _Peak peak,
) {
  const radius = 12;
  final outerThreshold = peak.value * 0.01;
  final coreThreshold = peak.value * 0.25;
  final footprint = <({int x, int y, double radius})>[];
  var coreRadius = 0.5;

  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance > radius) continue;
      final value = _luma(pixels, peak.x + dx, peak.y + dy);
      if (value >= outerThreshold) {
        footprint.add((x: dx, y: dy, radius: distance));
      }
      if (value >= coreThreshold && distance > coreRadius) {
        coreRadius = distance;
      }
    }
  }
  if (footprint.length < 12) return null;

  final centerX =
      footprint.map((pixel) => pixel.x).reduce((a, b) => a + b) /
      footprint.length;
  final centerY =
      footprint.map((pixel) => pixel.y).reduce((a, b) => a + b) /
      footprint.length;
  final halfWidth = footprint
      .map((pixel) => (pixel.x - centerX).abs())
      .reduce((a, b) => a > b ? a : b);
  final halfHeight = footprint
      .map((pixel) => (pixel.y - centerY).abs())
      .reduce((a, b) => a > b ? a : b);
  final corners = footprint.where((pixel) {
    final dx = (pixel.x - centerX).abs();
    final dy = (pixel.y - centerY).abs();
    return dx >= halfWidth * 0.75 && dy >= halfHeight * 0.75;
  }).length;
  final outerRadius = footprint
      .map((pixel) => pixel.radius)
      .reduce((a, b) => a > b ? a : b);
  return (
    cornerFill: corners / footprint.length,
    haloRatio: outerRadius / coreRadius,
  );
}

double _median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return 0;
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}
