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
double _clock = 0;

List<double> _activeBands() => List<double>.generate(64, (i) {
  final x = i / 63;
  final bass = 0.92 * math.exp(-x * 5.0);
  final mid = 0.68 * math.exp(-math.pow((x - 0.42) * 3.0, 2));
  final treble = 0.34 * (0.65 + 0.35 * math.sin(i * 1.7));
  return (bass + mid + treble).clamp(0.0, 1.0);
});

FluidDynamicsPainter _painter(List<double> bands) => FluidDynamicsPainter(
  bands: bands,
  palette: _palette,
  bloom: 0.5,
  animationTime: _clock,
);

double _nextTime() => _clock += 1 / 30;

void _paintStep(FluidDynamicsPainter painter, List<double> bands) {
  painter.setVisualizerTime(_nextTime());
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), _size);
  recorder.endRecording().dispose();
}

_FluidRecordingCanvas _paintRecorded(
  FluidDynamicsPainter painter,
  List<double> bands,
) {
  painter.setVisualizerTime(_nextTime());
  final canvas = _FluidRecordingCanvas();
  painter.paint(canvas, _size);
  return canvas;
}

Future<Uint8List> _rasterize(
  FluidDynamicsPainter painter,
  List<double> bands,
) async {
  painter.setVisualizerTime(_nextTime());
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
    'active audio keeps the bottom render row covered after warm-up',
    () async {
      final bands = List<double>.filled(64, 0.03);
      final painter = _painter(bands);
      for (var frame = 0; frame < 600; frame++) {
        _paintStep(painter, bands);
      }

      var minimumBottomDye = double.infinity;
      for (var x = 0; x < 128; x++) {
        minimumBottomDye = math.min(
          minimumBottomDye,
          FluidDynamicsPainter.debugDyeAt(x, 71),
        );
      }
      expect(
        minimumBottomDye,
        greaterThan(0.16),
        reason:
            'Every bottom cell must stay above the visible fluid threshold: '
            '$minimumBottomDye',
      );

      final canvas = _paintRecorded(painter, bands);
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

      final pixels = await _rasterize(painter, bands);
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

  test('a one-frame burst is smoothed and sustained audio ramps upward', () {
    final quiet = List<double>.filled(64, 0.0);
    final loud = _activeBands();
    final quietPainter = _painter(quiet);
    final loudPainter = _painter(loud);
    for (var frame = 0; frame < 150; frame++) {
      _paintStep(quietPainter, quiet);
    }
    final bandBuffer = FluidDynamicsPainter.debugSmoothedBands;

    final burst = _paintRecorded(loudPainter, loud);
    final burstBand = bandBuffer.isEmpty ? double.nan : bandBuffer.first;
    for (var frame = 0; frame < 90; frame++) {
      _paintStep(loudPainter, loud);
    }
    _paintStep(loudPainter, loud);
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
    expect(
      identical(FluidDynamicsPainter.debugSmoothedBands, bandBuffer),
      isTrue,
    );
    expect(
      sustainedBand,
      greaterThan(0.90),
      reason: 'target=${loud.first} burst=$burstBand sustained=$sustainedBand',
    );
    expect(
      identical(FluidDynamicsPainter.debugSmoothedBands, bandBuffer),
      isTrue,
    );

    _paintRecorded(quietPainter, quiet);
    expect(bandBuffer.first, greaterThan(0.70));
    for (var frame = 0; frame < 120; frame++) {
      _paintStep(quietPainter, quiet);
    }
    expect(bandBuffer.first, lessThan(0.02));
    expect(
      identical(FluidDynamicsPainter.debugSmoothedBands, bandBuffer),
      isTrue,
    );
  });

  test('render samples are sparse, soft-overlapped, and buffer-reusing', () {
    final bands = _activeBands();
    final painter = _painter(bands);
    for (var frame = 0; frame < 30; frame++) {
      _paintStep(painter, bands);
    }

    final first = _paintRecorded(painter, bands);
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
    expect(first.submittedCapacity, lessThanOrEqualTo(32 * 18));
    expect(first.sprites.length, lessThanOrEqualTo(32 * 18));
    expect(
      _median(overlaps),
      greaterThanOrEqualTo(2.3),
      reason: 'Soft sprite footprints must overlap by about 2.4x.',
    );

    for (var frame = 0; frame < 4; frame++) {
      final next = _paintRecorded(painter, bands);
      expect(identical(next.transforms, firstTransforms), isTrue);
      expect(identical(next.rects, firstRects), isTrue);
      expect(identical(next.colors, firstColors), isTrue);
      expect(next.submittedCapacity, first.submittedCapacity);
    }
  });
}
