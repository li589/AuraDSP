import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/shaders/gpu_shader_service.dart';
import 'package:auradsp_app/features/visualizer/styles/style_gpu_shader.dart';
import 'package:auradsp_app/features/visualizer/styles/style_tornado.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_sprite_atlas.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_time_aware.dart';
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

final _bands = List<double>.generate(32, (i) => 0.35 + 0.25 * ((i % 7) / 6));

typedef _AtlasBuffers = ({
  Float32List transforms,
  Float32List rects,
  Int32List colors,
  int spriteCount,
  int capacity,
});

typedef _ParticleMetrics = ({
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

CustomPainter _tornadoPainter({
  required GpuShaderService service,
  double time = 0.75,
  List<double>? bands,
  VisualizerConfig config = const VisualizerConfig(
    style: VisualizerStyle.tornado,
  ),
}) {
  return buildVisualizerPainter(
    style: VisualizerStyle.tornado,
    config: config,
    palette: _palette,
    rawBands: bands ?? _bands,
    peaks: List<double>.filled(32, 0.8),
    waveformSynth: WaveformSynthesizer(),
    time: time,
    service: service,
  );
}

// Keep the contract checks runtime-based so this suite compiles before the
// particle painter exists. The old route fails these assertions, not the
// compiler, which proves the regressions actually discriminate renderers.
dynamic _particlePainter(CustomPainter painter) {
  expect(
    painter,
    isNot(isA<GpuShaderPainter>()),
    reason: 'The primary tornado route must not be the mirrored raymarch.',
  );
  return painter;
}

Future<Uint8List> _rasterize(CustomPainter painter) async {
  const size = Size(480, 320);
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(480, 320);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

int _changedPixels(Uint8List a, Uint8List b) {
  var changed = 0;
  for (var i = 0; i < a.length; i += 4) {
    final delta =
        (a[i] - b[i]).abs() +
        (a[i + 1] - b[i + 1]).abs() +
        (a[i + 2] - b[i + 2]).abs() +
        (a[i + 3] - b[i + 3]).abs();
    if (delta > 16) changed++;
  }
  return changed;
}

// A bilateral renderer has (near) zero mismatch. Independent 3D particles
// leave different energy on opposite sides even when their envelope is a
// funnel. Compare only visible energy so transparent padding cannot dominate.
({double mismatch, double imbalance}) _mirrorSignature(Uint8List pixels) {
  const width = 480;
  const height = 320;
  var mismatch = 0.0;
  var leftEnergy = 0.0;
  var rightEnergy = 0.0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final j = (y * width + (width - 1 - x)) * 4;
      final energy =
          (pixels[i] + pixels[i + 1] + pixels[i + 2]) * pixels[i + 3] / 255.0;
      final mirrored =
          (pixels[j] + pixels[j + 1] + pixels[j + 2]) * pixels[j + 3] / 255.0;
      mismatch += (energy - mirrored).abs();
      if (x < width ~/ 2) {
        leftEnergy += energy;
      } else {
        rightEnergy += energy;
      }
    }
  }
  final total = leftEnergy + rightEnergy;
  return (
    mismatch: total == 0 ? 0 : mismatch / total,
    imbalance: total == 0 ? 0 : (leftEnergy - rightEnergy).abs() / total,
  );
}

Future<void> _pumpCapture(WidgetTester tester, CustomPainter painter) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: const Key('tornado-capture'),
          child: SizedBox(
            width: 480,
            height: 320,
            child: CustomPaint(
              painter: TornadoBackdropPainter(palette: _palette, bloom: 0.5),
              foregroundPainter: painter,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _AtlasCountingCanvas extends TestRecordingCanvas {
  int atlasCalls = 0;
  int submittedInstances = 0;

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
    submittedInstances = colors?.length ?? rstTransforms.length ~/ 4;
  }
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
    // Keeps the legacy asset independently testable without routing the
    // selected style through it. This also makes the RED run exercise the
    // real old shader rather than its unavailable/loading diagnostic.
    expect(
      await GpuShaderService.instance.ensureCompiled(GpuShaderType.tornado),
      isTrue,
    );
  });

  group('Particle tornado renderer', () {
    test(
      'dispatcher selects CPU particles without compiling tornado shader',
      () {
        final loaded = <String>[];
        final service = GpuShaderService.test(
          loader: (assetPath) async {
            loaded.add(assetPath);
            return ui.FragmentProgram.fromAsset(assetPath);
          },
        );
        final painter = _tornadoPainter(service: service);

        expect(painter, isNot(isA<GpuShaderPainter>()));
        expect(painter, isA<VisualizerTimeAware>());
        expect(loaded, isEmpty);
      },
    );

    test('rasterized particle flow breaks bilateral mirror symmetry', () async {
      final painter = _tornadoPainter(service: GpuShaderService.instance);
      final signature = _mirrorSignature(await _rasterize(painter));

      expect(
        signature.mismatch,
        greaterThan(0.75),
        reason:
            'A mirrored raymarch is not the approved particle distribution: '
            '$signature',
      );
      expect(
        signature.imbalance,
        greaterThan(0.02),
        reason:
            'Independent particles must not balance like a mirrored ray field.',
      );
    });

    test('visible particles move between nearby frames', () async {
      final painter = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      ) as CustomPainter;
      final first = await _rasterize(painter);
      (painter as VisualizerTimeAware).setVisualizerTime(0.90);
      final second = await _rasterize(painter);

      expect(_changedPixels(first, second), greaterThan(500));
    });

    test(
      '3D particles rise while the funnel centroid drifts asymmetrically',
      () {
        final dynamic painter = _particlePainter(
          _tornadoPainter(service: GpuShaderService.instance),
        );
        painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        final before = painter.debugParticleMetrics as _ParticleMetrics;
        final beforePositions = Float32List.fromList(
          painter.debugParticlePositions as Float32List,
        );
        painter.setVisualizerTime(2.0);
        painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        final after = painter.debugParticleMetrics as _ParticleMetrics;
        final afterPositions = painter.debugParticlePositions as Float32List;

        var risingParticles = 0;
        for (var i = 0; i < before.particleCount; i++) {
          if (afterPositions[i * 3 + 1] > beforePositions[i * 3 + 1]) {
            risingParticles++;
          }
        }
        expect(before.particleCount, inInclusiveRange(850, 950));
        expect(risingParticles, greaterThan(before.particleCount * 0.65));
        expect((after.centroidX - before.centroidX).abs(), greaterThan(0.01));
        expect(after.mirrorError, greaterThan(0.20));
      },
    );

    test(
      'painter reuses typed buffers and submits one atlas batch per frame',
      () {
        final dynamic painter = _particlePainter(
          _tornadoPainter(service: GpuShaderService.instance),
        );
        final canvas = _AtlasCountingCanvas();
        painter.paint(canvas, const Size(480, 320));
        final first = painter.debugAtlasBuffers as _AtlasBuffers;
        final firstTransforms = first.transforms;
        final firstRects = first.rects;
        final firstColors = first.colors;

        for (var frame = 1; frame <= 4; frame++) {
          painter.setVisualizerTime(0.75 + frame / 30);
          painter.paint(canvas, const Size(480, 320));
        }
        final last = painter.debugAtlasBuffers as _AtlasBuffers;
        final metrics = painter.debugParticleMetrics as _ParticleMetrics;

        expect(canvas.atlasCalls, 5);
        expect(canvas.submittedInstances, last.capacity);
        expect(last.spriteCount, greaterThan(metrics.particleCount * 2));
        expect(last.spriteCount, lessThan(last.capacity));
        expect(last.capacity, metrics.particleCount * 4);
        for (var i = last.spriteCount; i < last.capacity; i++) {
          expect(last.colors[i] >>> 24, 0);
        }
        expect(identical(last.transforms, firstTransforms), isTrue);
        expect(identical(last.rects, firstRects), isTrue);
        expect(identical(last.colors, firstColors), isTrue);
        expect(metrics.batchCount, 5);
      },
    );

    test('identical time/audio sequences are deterministic', () {
      final dynamic first = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      );
      final dynamic second = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      );
      for (var frame = 0; frame < 8; frame++) {
        final time = 0.75 + frame / 30;
        first.setVisualizerTime(time);
        second.setVisualizerTime(time);
        first.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        second.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      }
      final a = first.debugParticlePositions as Float32List;
      final b = second.debugParticlePositions as Float32List;
      expect(a, orderedEquals(b));
    });

    test('repainting the same timestamp does not advance particles', () {
      final dynamic painter = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      );
      painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      final before = Float32List.fromList(
        painter.debugParticlePositions as Float32List,
      );
      painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      final after = painter.debugParticlePositions as Float32List;
      expect(after, orderedEquals(before));
    });

    test('audio smoothly increases speed, spread, and brightness', () {
      final quietBands = List<double>.filled(32, 0.0);
      final loudBands = List<double>.filled(32, 1.0);
      final dynamic quiet = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance, bands: quietBands),
      );
      final dynamic loud = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance, bands: loudBands),
      );
      _ParticleMetrics? previousLoud;
      var largestLoudStep = 0.0;
      for (var frame = 0; frame < 16; frame++) {
        final time = 0.75 + frame / 30;
        quiet.setVisualizerTime(time);
        loud.setVisualizerTime(time);
        quiet.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        loud.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        final metrics = loud.debugParticleMetrics as _ParticleMetrics;
        if (previousLoud != null) {
          largestLoudStep = mathMax(
            largestLoudStep,
            (metrics.speed - previousLoud.speed).abs(),
          );
        }
        previousLoud = metrics;
      }
      final quietMetrics = quiet.debugParticleMetrics as _ParticleMetrics;
      final loudMetrics = loud.debugParticleMetrics as _ParticleMetrics;

      expect(loudMetrics.speed, greaterThan(quietMetrics.speed * 1.15));
      expect(loudMetrics.spread, greaterThan(quietMetrics.spread * 1.05));
      expect(
        loudMetrics.brightness,
        greaterThan(quietMetrics.brightness * 1.05),
      );
      expect(largestLoudStep, lessThan(0.12));
    });

    test(
      'dark backdrop stays smooth without a hard horizontal strip',
      () async {
        final pixels = await _rasterize(
          TornadoBackdropPainter(palette: _palette, bloom: 0.5),
        );
        final rowMeans = List<double>.generate(320, (y) {
          var sum = 0.0;
          for (var x = 0; x < 480; x++) {
            final i = (y * 480 + x) * 4;
            sum += (pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3.0;
          }
          return sum / 480.0;
        });
        var largestStep = 0.0;
        for (var y = 1; y < rowMeans.length; y++) {
          final step = (rowMeans[y] - rowMeans[y - 1]).abs();
          if (step > largestStep) largestStep = step;
        }
        expect(largestStep, lessThan(2.0));
        expect(rowMeans.reduce(mathMin), greaterThan(1.5));
      },
    );

    testWidgets('particle tornado matches a fixed-time software golden', (
      tester,
    ) async {
      final painter = _tornadoPainter(service: GpuShaderService.instance);
      await _pumpCapture(tester, painter);
      await expectLater(
        find.byKey(const Key('tornado-capture')),
        matchesGoldenFile('goldens/tornado_fixed_time.png'),
      );
    });
  });
}

double mathMax(double a, double b) => a > b ? a : b;

double mathMin(double a, double b) => a < b ? a : b;
