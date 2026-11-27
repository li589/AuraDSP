import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/controllers/peak_physics_engine.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/shaders/gpu_shader_service.dart';
import 'package:auradsp_app/features/visualizer/styles/style_gpu_shader.dart';
import 'package:auradsp_app/features/visualizer/styles/style_tornado.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_sprite_atlas.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_time_aware.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_viewport.dart';
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

const _lightPalette = VisualizerPalette(
  primary: Color(0xFF1565C0),
  secondary: Color(0xFF6A1B9A),
  peak: Color(0xFF101318),
  grid: Color(0x1A1565C0),
  glow: Color(0x801565C0),
  gradient: [Color(0xFF0D47A1), Color(0xFF1565C0)],
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
  double meanParticleDiameter,
  double colorShift,
});

typedef _CameraState = ({
  double progress,
  double distance,
  double yaw,
  double pitch,
  double projectionScale,
});

CustomPainter _tornadoPainter({
  required GpuShaderService service,
  double time = 0.75,
  List<double>? bands,
  VisualizerConfig config = const VisualizerConfig(
    style: VisualizerStyle.tornado,
  ),
  VisualizerPalette palette = _palette,
}) {
  return buildVisualizerPainter(
    style: VisualizerStyle.tornado,
    config: config,
    palette: palette,
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
        painter.setVisualizerTime(0.85);
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
        var centroidDrift = (after.centroidX - before.centroidX).abs();
        var mirrorError = after.mirrorError;
        for (var frame = 2; frame <= 38; frame++) {
          painter.setVisualizerTime(0.75 + frame / 30);
          painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
          final metrics = painter.debugParticleMetrics as _ParticleMetrics;
          centroidDrift = math.max(
            centroidDrift,
            (metrics.centroidX - before.centroidX).abs(),
          );
          mirrorError = math.max(mirrorError, metrics.mirrorError);
        }
        expect(
          centroidDrift,
          greaterThan(0.005),
          reason:
              'The contracting funnel must retain asymmetric centroid drift.',
        );
        expect(mirrorError, greaterThan(0.20));
      },
    );

    test('funnel is broad at the top and inner particles rise faster', () {
      final dynamic painter = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      );
      painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      final before = Float32List.fromList(
        painter.debugParticlePositions as Float32List,
      );
      painter.setVisualizerTime(0.75 + 1 / 30);
      painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      final after = painter.debugParticlePositions as Float32List;

      var lowerRadius = 0.0;
      var lowerCount = 0;
      var upperRadius = 0.0;
      var upperCount = 0;
      var outerRise = 0.0;
      var outerCount = 0;
      var innerRise = 0.0;
      var innerCount = 0;
      for (var i = 0; i < before.length ~/ 3; i++) {
        final offset = i * 3;
        final u = (before[offset + 1] + 6.0) / 12.0;
        final radius = math.sqrt(
          before[offset] * before[offset] +
              before[offset + 2] * before[offset + 2],
        );
        if (u < 1 / 3) {
          lowerRadius += radius;
          lowerCount++;
        } else if (u > 2 / 3) {
          upperRadius += radius;
          upperCount++;
        }

        final rise = after[offset + 1] - before[offset + 1];
        if (rise <= 0.0) continue;
        if (radius > 2.0) {
          outerRise += rise;
          outerCount++;
        } else if (radius < 1.5) {
          innerRise += rise;
          innerCount++;
        }
      }

      expect(lowerCount, greaterThan(100));
      expect(upperCount, greaterThan(100));
      expect(
        upperRadius / upperCount,
        greaterThan((lowerRadius / lowerCount) * 1.8),
        reason: 'The reference screen maps the wide spawning mouth to the top.',
      );
      expect(outerCount, greaterThan(100));
      expect(innerCount, greaterThan(100));
      expect(
        innerRise / innerCount,
        greaterThan((outerRise / outerCount) * 1.15),
        reason: 'The reference inner core rises faster while the outer ring stalls.',
      );
    });

    test('camera dollies in once, then locks at a legible scale', () {
      final dynamic painter = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      );
      painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      final initial = painter.debugCameraState as _CameraState;
      expect(initial.progress, lessThan(0.05));
      expect(initial.distance, greaterThan(27.0));

      for (var frame = 1; frame <= 90; frame++) {
        painter.setVisualizerTime(0.75 + frame / 30);
        painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      }
      final settled = painter.debugCameraState as _CameraState;
      expect(settled.progress, 1.0);
      expect(settled.distance, closeTo(18.0, 0.000001));
      expect(settled.yaw, closeTo(0.22, 0.000001));
      expect(settled.pitch, closeTo(0.16, 0.000001));
      expect(
        settled.projectionScale,
        greaterThan(initial.projectionScale * 1.4),
      );
      expect(
        (painter.debugParticleMetrics as _ParticleMetrics).meanParticleDiameter,
        greaterThan(2.8),
        reason: 'The settled camera must keep individual particles legible.',
      );

      for (var frame = 91; frame <= 150; frame++) {
        painter.setVisualizerTime(0.75 + frame / 30);
        painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      }
      expect(painter.debugCameraState as _CameraState, settled);
    });

    test('mirror error compares opposing sides within each radius bin', () {
      final dynamic painter = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      );
      painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      final positions = painter.debugParticlePositions as Float32List;
      final metrics = painter.debugParticleMetrics as _ParticleMetrics;
      final bins = Float32List(32);
      for (var i = 0; i < positions.length ~/ 3; i++) {
        final x = positions[i * 3];
        final bin = ((x.abs() / 5.5) * 31).floor().clamp(0, 31);
        bins[bin] += x < 0.0 ? -1.0 : 1.0;
      }
      var imbalance = 0.0;
      for (final value in bins) {
        imbalance += value.abs();
      }
      final expected = imbalance / (positions.length ~/ 3);

      expect(metrics.mirrorError, closeTo(expected, 0.000001));
      expect(metrics.mirrorError, inInclusiveRange(0.0, 1.0));
    });

    test('trail history stores actual prior particle positions', () {
      final dynamic painter = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance),
      );
      final snapshots = <Float32List>[];
      for (var frame = 0; frame < 4; frame++) {
        painter.setVisualizerTime(0.75 + frame / 30);
        painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        snapshots.add(
          Float32List.fromList(painter.debugParticlePositions as Float32List),
        );
      }
      final history = painter.debugTrailHistory as Float32List;
      final historyCount = painter.debugTrailHistoryCount as int;
      final stride = snapshots.first.length;

      expect(historyCount, 3);
      for (var sample = 0; sample < 3; sample++) {
        expect(
          history.sublist(sample * stride, (sample + 1) * stride),
          orderedEquals(snapshots[2 - sample]),
        );
      }
    });

    test(
      'screen-space trails stay registered after a long simulation step',
      () {
        final dynamic painter = _particlePainter(
          _tornadoPainter(service: GpuShaderService.instance),
        );
        for (var frame = 0; frame <= 90; frame++) {
          painter.setVisualizerTime(0.75 + frame / 30);
          painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        }
        for (var frame = 1; frame <= 3; frame++) {
          painter.setVisualizerTime(3.75 + frame / 30);
          painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        }
        final previousHeads = Float32List.fromList(
          painter.debugHeadScreenPositions as Float32List,
        );

        painter.setVisualizerTime(3.95);
        painter.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
        final heads = painter.debugHeadScreenPositions as Float32List;
        final trails = painter.debugTrailScreenPositions as Float32List;
        var compared = 0;
        var registered = 0;
        for (var i = 0; i < heads.length ~/ 2; i++) {
          final headOffset = i * 2;
          final trailOffset = i * 6;
          final previousX = previousHeads[headOffset];
          final previousY = previousHeads[headOffset + 1];
          final x = heads[headOffset];
          final y = heads[headOffset + 1];
          final trailX = trails[trailOffset];
          final trailY = trails[trailOffset + 1];
          if (!previousX.isFinite ||
              !previousY.isFinite ||
              !x.isFinite ||
              !y.isFinite ||
              !trailX.isFinite ||
              !trailY.isFinite) {
            continue;
          }
          final movement = math.sqrt(
            (x - previousX) * (x - previousX) +
                (y - previousY) * (y - previousY),
          );
          if (movement < 0.75) continue;
          final trailError = math.sqrt(
            (trailX - previousX) * (trailX - previousX) +
                (trailY - previousY) * (trailY - previousY),
          );
          compared++;
          if (trailError < movement * 0.35) registered++;
        }

        expect(compared, greaterThan(100));
        expect(registered / compared, greaterThan(0.80));
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
        final firstHistory = painter.debugTrailHistory as Float32List;

        for (var frame = 1; frame <= 4; frame++) {
          painter.setVisualizerTime(0.75 + frame / 30);
          painter.paint(canvas, const Size(480, 320));
        }
        final last = painter.debugAtlasBuffers as _AtlasBuffers;
        final metrics = painter.debugParticleMetrics as _ParticleMetrics;

        expect(canvas.atlasCalls, 5);
        expect(canvas.submittedInstances, last.capacity);
        expect(last.spriteCount, greaterThan(metrics.particleCount));
        expect(last.spriteCount, lessThanOrEqualTo(last.capacity));
        expect(last.capacity, metrics.particleCount * 4);
        for (var i = last.spriteCount; i < last.capacity; i++) {
          expect(last.colors[i] >>> 24, 0);
        }
        expect(identical(last.transforms, firstTransforms), isTrue);
        expect(identical(last.rects, firstRects), isTrue);
        expect(identical(last.colors, firstColors), isTrue);
        expect(identical(painter.debugTrailHistory, firstHistory), isTrue);
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
      expect(
        loudMetrics.colorShift,
        greaterThan(quietMetrics.colorShift + 0.15),
      );
      expect(largestLoudStep, lessThan(0.12));
    });

    test('theme and preset palettes drive particle colors', () {
      final dynamic bright = _particlePainter(
        _tornadoPainter(service: GpuShaderService.instance, palette: _palette),
      );
      final dynamic light = _particlePainter(
        _tornadoPainter(
          service: GpuShaderService.instance,
          palette: _lightPalette,
        ),
      );
      bright.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      light.paint(Canvas(ui.PictureRecorder()), const Size(480, 320));
      final a = bright.debugAtlasBuffers as _AtlasBuffers;
      final b = light.debugAtlasBuffers as _AtlasBuffers;
      expect(a.spriteCount, greaterThan(0));
      expect(b.spriteCount, a.spriteCount);
      var colorDelta = 0;
      for (var i = 0; i < a.spriteCount; i++) {
        final ac = a.colors[i] & 0x00FFFFFF;
        final bc = b.colors[i] & 0x00FFFFFF;
        colorDelta += ((ac & 0xFF) - (bc & 0xFF)).abs();
        colorDelta += (((ac >>> 8) & 0xFF) - ((bc >>> 8) & 0xFF)).abs();
        colorDelta += (((ac >>> 16) & 0xFF) - ((bc >>> 16) & 0xFF)).abs();
      }
      expect(colorDelta / a.spriteCount, greaterThan(30.0));
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

    test('backdrop follows peak luminance in light and dark themes', () async {
      final darkPixels = await _rasterize(
        TornadoBackdropPainter(palette: _palette, bloom: 0.5),
      );
      final lightPixels = await _rasterize(
        TornadoBackdropPainter(palette: _lightPalette, bloom: 0.5),
      );
      double meanBrightness(Uint8List pixels) {
        var sum = 0.0;
        for (var i = 0; i < pixels.length; i += 4) {
          sum += (pixels[i] + pixels[i + 1] + pixels[i + 2]) / 3.0;
        }
        return sum / (pixels.length ~/ 4);
      }

      final darkMean = meanBrightness(darkPixels);
      final lightMean = meanBrightness(lightPixels);
      expect(darkMean, lessThan(40.0));
      expect(lightMean, greaterThan(180.0));
      expect(lightMean, greaterThan(darkMean * 3.0));
    });

    testWidgets('camera does not replay after configuration changes', (
      tester,
    ) async {
      final time = ValueNotifier(0.0);
      final spectrum = ValueNotifier(List<double>.filled(64, 0.4));
      final levelL = ValueNotifier(-8.0);
      final levelR = ValueNotifier(-9.0);
      addTearDown(time.dispose);
      addTearDown(spectrum.dispose);
      addTearDown(levelL.dispose);
      addTearDown(levelR.dispose);
      final peakEngine = PeakPhysicsEngine();
      final synth = WaveformSynthesizer();

      Widget viewport(VisualizerConfig config, VisualizerPalette palette) =>
          MaterialApp(
            theme: withAuraExtension(ThemeData.dark(), auraDark),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 480,
                  height: 320,
                  child: VisualizerCanvasViewport(
                    time: time,
                    spectrum: spectrum,
                    levelL: levelL,
                    levelR: levelR,
                    config: config,
                    palette: palette,
                    peakEngine: peakEngine,
                    waveformSynth: synth,
                  ),
                ),
              ),
            ),
          );

      TornadoParticlePainter mainTornadoPainter() {
        for (final widget in tester.widgetList<CustomPaint>(
          find.byType(CustomPaint),
        )) {
          final dynamic painter = widget.painter;
          try {
            final main = painter.mainPainter;
            if (main is TornadoParticlePainter) return main;
          } on NoSuchMethodError {
            continue;
          }
        }
        throw StateError('Tornado painter not found');
      }

      final initialPalette = VisualizerPalette.resolve(
        VisualizerColorTheme.neonCyber,
        auraDark,
      );
      await tester.pumpWidget(
        viewport(
          const VisualizerConfig(
            style: VisualizerStyle.tornado,
            showGrid: false,
            bloom: 0.2,
            sensitivity: 1.0,
          ),
          initialPalette,
        ),
      );
      final first = mainTornadoPainter();
      final canvas = TestRecordingCanvas();
      for (var frame = 0; frame <= 90; frame++) {
        first.setVisualizerTime(frame / 30);
        first.paint(canvas, const Size(480, 320));
      }
      time.value = 3.0;
      final settledCamera = first.debugCameraState;
      expect(settledCamera.progress, 1.0);

      final changedPalette = VisualizerPalette.resolve(
        VisualizerColorTheme.amberTube,
        auraDark,
      );
      await tester.pumpWidget(
        viewport(
          const VisualizerConfig(
            style: VisualizerStyle.tornado,
            showGrid: false,
            bloom: 1.2,
            sensitivity: 1.8,
          ),
          changedPalette,
        ),
      );
      final updated = mainTornadoPainter();
      expect(updated, same(first));
      expect(updated.debugCameraState, settledCamera);
      expect(updated.bloom, 1.2);
      expect(updated.sensitivity, 1.8);
      expect(updated.palette, changedPalette);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('particle tornado matches a fixed-time software golden', (
      tester,
    ) async {
      final painter = _tornadoPainter(service: GpuShaderService.instance);
      for (var frame = 0; frame <= 90; frame++) {
        (painter as VisualizerTimeAware).setVisualizerTime(0.75 + frame / 30);
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), const Size(480, 320));
        recorder.endRecording().dispose();
      }
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
