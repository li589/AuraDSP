import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/styles/style_fluid.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_sprite_atlas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _palette = VisualizerPalette(
  primary: Color(0xFF00E5FF),
  secondary: Color(0xFFFF007F),
  peak: Color(0xFFFFFFFF),
  grid: Color(0x1A00E5FF),
  glow: Color(0x8000E5FF),
  gradient: [Color(0xFF0055FF), Color(0xFF00E5FF)],
);

const _size = Size(960, 540);
const _lightStageBackground = Color(0xFFF4F7FB);

class _FrameClock {
  double _time = 0;

  double get current => _time;

  double next() => _time += 1 / 30;

  void reset() => _time = 0;
}

List<double> _activeBands() => List<double>.generate(64, (i) {
  final x = i / 63;
  final bass = 0.92 * math.exp(-x * 5.0);
  final mid = 0.68 * math.exp(-math.pow((x - 0.42) * 3.0, 2));
  final treble = 0.34 * (0.65 + 0.35 * math.sin(i * 1.7));
  return (bass + mid + treble).clamp(0.0, 1.0);
});

FluidDynamicsPainter _painter(
  List<double> bands,
  _FrameClock clock, {
  VisualizerPalette palette = _palette,
  int? pressureIterations,
  Color? backgroundColor,
}) => FluidDynamicsPainter(
  bands: bands,
  palette: palette,
  bloom: 0.5,
  animationTime: clock.current,
  pressureIterations: pressureIterations,
  backgroundColor: backgroundColor,
);

void _paintAt(FluidDynamicsPainter painter, double time, {Size size = _size}) {
  painter.setVisualizerTime(time);
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  recorder.endRecording().dispose();
}

void _paintStep(
  FluidDynamicsPainter painter,
  _FrameClock clock, {
  Size size = _size,
}) => _paintAt(painter, clock.next(), size: size);

_FluidRecordingCanvas _paintRecorded(
  FluidDynamicsPainter painter,
  _FrameClock clock, {
  Size size = _size,
}) {
  painter.setVisualizerTime(clock.next());
  final canvas = _FluidRecordingCanvas();
  painter.paint(canvas, size);
  return canvas;
}

Future<Uint8List> _rasterize(
  FluidDynamicsPainter painter,
  _FrameClock clock,
) async {
  painter.setVisualizerTime(clock.next());
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), _size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

class _SpriteSample {
  const _SpriteSample({
    required this.color,
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
  });

  final int color;
  final double centerX;
  final double centerY;
  final double width;
  final double height;

  int get alpha => (color >>> 24) & 0xFF;
}

class _FluidRecordingCanvas extends TestRecordingCanvas {
  int atlasCalls = 0;
  int submittedCapacity = 0;
  ui.FilterQuality? filterQuality;
  Float32List? transforms;
  Float32List? rects;
  Int32List? colors;
  final List<_SpriteSample> sprites = [];

  @override
  void drawRawAtlas(
    ui.Image atlas,
    Float32List rstTransforms,
    Float32List rects,
    Int32List? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    atlasCalls++;
    submittedCapacity = colors?.length ?? rstTransforms.length ~/ 4;
    filterQuality = paint.filterQuality;
    transforms = rstTransforms;
    this.rects = rects;
    this.colors = colors;
    sprites.clear();
    for (var i = 0; i < submittedCapacity; i++) {
      final color = colors?[i] ?? 0xFFFFFFFF;
      if (((color >>> 24) & 0xFF) == 0) continue;
      final o = i * 4;
      final scale = rstTransforms[o];
      final width = rects[o + 2] * scale;
      final height = rects[o + 3] * scale;
      sprites.add(
        _SpriteSample(
          color: color,
          centerX: rstTransforms[o + 2] + width * 0.5,
          centerY: rstTransforms[o + 3] + height * 0.5,
          width: width,
          height: height,
        ),
      );
    }
  }
}

List<_SpriteSample> _bottomRow(_FluidRecordingCanvas canvas) {
  if (canvas.sprites.isEmpty) return const [];
  final bottom = canvas.sprites
      .map((sprite) => sprite.centerY)
      .reduce(math.max);
  return canvas.sprites
      .where((sprite) => (sprite.centerY - bottom).abs() < 0.5)
      .toList();
}

double _meanAlpha(Iterable<_SpriteSample> sprites) {
  var sum = 0.0;
  var count = 0;
  for (final sprite in sprites) {
    sum += sprite.alpha / 255.0;
    count++;
  }
  return count == 0 ? 0 : sum / count;
}

double _median(List<double> values) {
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final atlas = VisualizerSpriteAtlas.instance;
    atlas.ensureImage();
    for (var i = 0; i < 200 && atlas.imageOrNull == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(atlas.imageOrNull, isNotNull);
  });

  test(
    'active audio keeps a smooth covered bottom row profile after warm-up',
    () async {
      final bands = List<double>.filled(64, 0.03);
      final clock = _FrameClock();
      final painter = _painter(bands, clock);
      for (var frame = 0; frame < 600; frame++) {
        _paintStep(painter, clock);
      }

      var minimumBottomDye = double.infinity;
      for (var x = 0; x < 128; x++) {
        minimumBottomDye = math.min(
          minimumBottomDye,
          painter.debugDyeAt(x, 71),
        );
      }
      expect(
        minimumBottomDye,
        greaterThan(0.16),
        reason:
            'Every bottom cell must stay above the visible fluid threshold: '
            '$minimumBottomDye',
      );

      var minimumSideDye = double.infinity;
      for (var y = 0; y < 72; y++) {
        minimumSideDye = math.min(minimumSideDye, painter.debugDyeAt(0, y));
        minimumSideDye = math.min(minimumSideDye, painter.debugDyeAt(127, y));
      }
      expect(
        minimumSideDye,
        greaterThan(0.15),
        reason: 'The left and right edge cells must not expose dark gaps.',
      );

      final rowProfile = <double>[];
      for (var y = 66; y < 72; y++) {
        var rowMinimum = double.infinity;
        for (var x = 0; x < 128; x++) {
          rowMinimum = math.min(rowMinimum, painter.debugDyeAt(x, y));
        }
        rowProfile.add(rowMinimum);
      }
      expect(
        rowProfile.where((value) => value >= rowProfile.last * 0.5).length,
        greaterThanOrEqualTo(4),
        reason:
            'Bottom coverage must fall off across multiple rows: $rowProfile',
      );
      final nearBottom = rowProfile.sublist(rowProfile.length - 3);
      expect(
        nearBottom[1],
        greaterThanOrEqualTo(nearBottom.last * 0.75),
        reason:
            'The row above the bottom must continue the smooth falloff: '
            '$rowProfile',
      );
      expect(
        nearBottom.first,
        greaterThanOrEqualTo(nearBottom.last * 0.5),
        reason: 'Bottom coverage must span more than two rows: $rowProfile',
      );

      final canvas = _paintRecorded(painter, clock);
      final bottom = _bottomRow(canvas);
      final rows = <double, List<_SpriteSample>>{};
      for (final sprite in canvas.sprites) {
        rows.putIfAbsent(sprite.centerY, () => <_SpriteSample>[]).add(sprite);
      }
      final fullestRow = rows.values.map((row) => row.length).reduce(math.max);

      expect(
        bottom.length,
        fullestRow,
        reason: 'Bottom-edge zero-alpha gaps: ${fullestRow - bottom.length}',
      );
      expect(bottom.length, greaterThanOrEqualTo(32));
      expect(
        bottom.first.centerY + bottom.first.height * 0.5,
        greaterThanOrEqualTo(_size.height),
        reason: 'The bottom sample row must extend beyond the viewport edge.',
      );

      final pixels = await _rasterize(painter, clock);
      var longestUncoveredRun = 0;
      for (var x = 0; x < _size.width.toInt(); x++) {
        var covered = false;
        for (var y = _size.height.toInt() - 2; y < _size.height.toInt(); y++) {
          if (pixels[(y * _size.width.toInt() + x) * 4 + 3] > 8) {
            covered = true;
            break;
          }
        }
        longestUncoveredRun = covered ? 0 : longestUncoveredRun + 1;
      }
      expect(
        longestUncoveredRun,
        lessThan(8),
        reason:
            'Persistent transparent run along the bottom edge: '
            '$longestUncoveredRun px',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('each frame clears unused atlas color slots', () {
    final bands = _activeBands();
    final clock = _FrameClock();
    final painter = _painter(bands, clock);
    for (var frame = 0; frame < 30; frame++) {
      _paintStep(painter, clock);
    }
    expect(_paintRecorded(painter, clock).sprites.length, greaterThan(128));

    bands.fillRange(0, bands.length, 0);
    painter.debugClearDye();
    final colors = painter.debugAtlasColors;
    colors.fillRange(0, colors.length, 0xFFFFFFFF);
    final frame = _paintRecorded(painter, clock);
    expect(frame.atlasCalls, 1);
    expect(frame.sprites.length, greaterThan(0));
    expect(frame.sprites.length, lessThan(frame.submittedCapacity));
    expect(
      colors
          .skip(frame.sprites.length)
          .every((color) => ((color >>> 24) & 0xFF) == 0),
      isTrue,
      reason: 'Stale dense-frame colors must not survive in the atlas tail.',
    );
  });

  test('painters keep independent envelopes at identical explicit times', () {
    final clock = _FrameClock();
    final loudPainter = _painter(_activeBands(), clock);
    final quietPainter = _painter(List<double>.filled(64, 0), clock);

    _paintAt(loudPainter, 0);
    final loudBuffer = loudPainter.debugSmoothedBands;
    _paintAt(quietPainter, 0);
    final quietBuffer = quietPainter.debugSmoothedBands;

    expect(
      identical(loudBuffer, quietBuffer),
      isFalse,
      reason: 'A painter must own its simulation and envelope buffers.',
    );
    expect(loudBuffer.first, greaterThan(0));
    expect(quietBuffer.first, 0);
  });

  test(
    'explicit clocks isolate frame order, resize, and fresh-state reset',
    () {
      final loud = _painter(
        _activeBands(),
        _FrameClock(),
        pressureIterations: 12,
      );
      final quiet = _painter(
        List<double>.filled(64, 0),
        _FrameClock(),
        pressureIterations: 12,
      );
      final referenceLoud = _painter(
        _activeBands(),
        _FrameClock(),
        pressureIterations: 12,
      );
      final referenceQuiet = _painter(
        List<double>.filled(64, 0),
        _FrameClock(),
        pressureIterations: 12,
      );
      List<double>? firstLoudEnvelope;
      Float32List? firstLoudDye;

      for (var frame = 0; frame < 6; frame++) {
        final time = (frame + 1) / 30;
        if (frame.isEven) {
          _paintAt(loud, time, size: frame == 2 ? const Size(480, 270) : _size);
          _paintAt(quiet, time);
        } else {
          _paintAt(quiet, time);
          _paintAt(loud, time);
        }
        _paintAt(referenceLoud, time);
        _paintAt(referenceQuiet, time);

        for (var band = 0; band < 64; band++) {
          expect(
            loud.debugSmoothedBands[band],
            closeTo(referenceLoud.debugSmoothedBands[band], 1e-6),
          );
          expect(
            quiet.debugSmoothedBands[band],
            closeTo(referenceQuiet.debugSmoothedBands[band], 1e-6),
          );
        }
        expect(loud.debugPressureIterations, 12);
        expect(quiet.debugPressureIterations, 12);
        expect(loud.debugDyeField, orderedEquals(referenceLoud.debugDyeField));
        expect(
          quiet.debugDyeField,
          orderedEquals(referenceQuiet.debugDyeField),
        );
        firstLoudEnvelope ??= List<double>.of(referenceLoud.debugSmoothedBands);
        firstLoudDye ??= Float32List.fromList(referenceLoud.debugDyeField);
      }

      final fresh = _painter(
        _activeBands(),
        _FrameClock(),
        pressureIterations: 12,
      );
      expect(fresh.debugSmoothedBands, isEmpty);
      _paintAt(fresh, 0);
      for (var band = 0; band < 64; band++) {
        expect(
          fresh.debugSmoothedBands[band],
          closeTo(firstLoudEnvelope![band], 1e-6),
        );
      }
      expect(fresh.debugDyeField, orderedEquals(firstLoudDye!));
    },
  );

  test('a one-frame burst is smoothed and sustained audio ramps upward', () {
    final loud = _activeBands();
    final clock = _FrameClock();
    final loudPainter = _painter(loud, clock);
    expect(loudPainter.debugSmoothedBands, isEmpty);

    final burst = _paintRecorded(loudPainter, clock);
    final bandBuffer = loudPainter.debugSmoothedBands;
    final burstBand = bandBuffer.isEmpty ? double.nan : bandBuffer.first;
    for (var frame = 0; frame < 90; frame++) {
      _paintStep(loudPainter, clock);
    }
    _paintStep(loudPainter, clock);
    final sustainedBand = bandBuffer.isEmpty ? double.nan : bandBuffer.first;

    final burstBottom = _meanAlpha(_bottomRow(burst));

    expect(
      burstBottom,
      greaterThan(0.10),
      reason: 'The burst must remain visible immediately.',
    );
    expect(
      burstBottom,
      lessThan(0.45),
      reason: 'A transient must not hit at full strength: burst=$burstBottom',
    );
    expect(bandBuffer, isA<Float32List>());
    expect(bandBuffer.length, 64);
    expect(burstBand, lessThan(0.75));
    expect(burstBand, greaterThan(0.0));
    expect(identical(loudPainter.debugSmoothedBands, bandBuffer), isTrue);
    expect(
      sustainedBand,
      greaterThan(0.90),
      reason: 'target=${loud.first} burst=$burstBand sustained=$sustainedBand',
    );
    expect(identical(loudPainter.debugSmoothedBands, bandBuffer), isTrue);

    final decayingBands = _activeBands();
    final decayingPainter = _painter(decayingBands, clock);
    for (var frame = 0; frame < 90; frame++) {
      _paintStep(decayingPainter, clock);
    }
    final decayingBuffer = decayingPainter.debugSmoothedBands;
    decayingBands.fillRange(0, decayingBands.length, 0);
    _paintRecorded(decayingPainter, clock);
    expect(decayingBuffer.first, greaterThan(0.70));
    for (var frame = 0; frame < 120; frame++) {
      _paintStep(decayingPainter, clock);
    }
    expect(decayingBuffer.first, lessThan(0.02));
    expect(
      identical(decayingPainter.debugSmoothedBands, decayingBuffer),
      isTrue,
    );
    expect(
      loudPainter.debugSmoothedBands.first,
      greaterThan(0.90),
      reason: 'Decay in another painter must not mutate the sustained field.',
    );
  });

  test('render samples are sparse, soft-overlapped, and buffer-reusing', () {
    final bands = _activeBands();
    final clock = _FrameClock();
    final painter = _painter(bands, clock);
    for (var frame = 0; frame < 30; frame++) {
      _paintStep(painter, clock);
    }

    final first = _paintRecorded(painter, clock);
    final firstTransforms = first.transforms;
    final firstRects = first.rects;
    final firstColors = first.colors;
    final rows = <double, List<_SpriteSample>>{};
    for (final sprite in first.sprites) {
      rows.putIfAbsent(sprite.centerY, () => <_SpriteSample>[]).add(sprite);
    }
    final overlaps = <double>[];
    for (final row in rows.values) {
      row.sort((a, b) => a.centerX.compareTo(b.centerX));
      var minGap = double.infinity;
      for (var i = 1; i < row.length; i++) {
        final gap = row[i].centerX - row[i - 1].centerX;
        if (gap > 1) minGap = math.min(minGap, gap);
      }
      if (minGap.isFinite) overlaps.add(row.first.width / minGap);
    }

    expect(first.atlasCalls, 1);
    expect(
      first.filterQuality,
      FilterQuality.low,
      reason: 'The shared atlas budget must not allocate a mipmap chain.',
    );
    expect(first.submittedCapacity, lessThanOrEqualTo(32 * 18));
    expect(first.sprites.length, lessThanOrEqualTo(32 * 18));
    expect(
      _median(overlaps),
      greaterThanOrEqualTo(2.3),
      reason: 'Soft sprite footprints must overlap by about 2.4x.',
    );

    for (var frame = 0; frame < 4; frame++) {
      final next = _paintRecorded(painter, clock);
      expect(identical(next.transforms, firstTransforms), isTrue);
      expect(identical(next.rects, firstRects), isTrue);
      expect(identical(next.colors, firstColors), isTrue);
      expect(next.submittedCapacity, first.submittedCapacity);
    }
  });

  test('stage background controls fluid contrast for fixed presets', () {
    final lightClock = _FrameClock();
    final darkClock = _FrameClock();
    final light = _painter(
      _activeBands(),
      lightClock,
      backgroundColor: _lightStageBackground,
    );
    final dark = _painter(_activeBands(), darkClock);
    for (var frame = 0; frame < 30; frame++) {
      _paintStep(light, lightClock);
      _paintStep(dark, darkClock);
    }
    final lightFrame = _paintRecorded(light, lightClock);
    final darkFrame = _paintRecorded(dark, darkClock);
    expect(lightFrame.sprites.length, greaterThan(0));
    expect(lightFrame.sprites.length, darkFrame.sprites.length);

    double meanRgb(Iterable<_SpriteSample> sprites) {
      var sum = 0.0;
      for (final sprite in sprites) {
        sum +=
            (sprite.color & 0xFF) +
            ((sprite.color >>> 8) & 0xFF) +
            ((sprite.color >>> 16) & 0xFF);
      }
      return sum / (sprites.length * 3);
    }

    expect(
      meanRgb(lightFrame.sprites),
      lessThan(meanRgb(darkFrame.sprites) * 0.85),
      reason:
          'A light stage needs darker ink even when a preset peak is light.',
    );
  });
}
