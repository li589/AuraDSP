import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/shaders/gpu_shader_service.dart';
import 'package:auradsp_app/features/visualizer/styles/style_gpu_shader.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';
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

class _CountingGpuShaderPainter extends GpuShaderPainter {
  _CountingGpuShaderPainter({required GpuShaderService service})
    : super(
        shaderType: GpuShaderType.tornado,
        bands: _bands,
        palette: _palette,
        time: 0.75,
        sensitivity: 1.0,
        service: service,
      );

  int paintCount = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paintCount++;
    super.paint(canvas, size);
  }
}

GpuShaderPainter _tornadoPainter({
  required GpuShaderService service,
  double time = 0.75,
}) {
  final synth = WaveformSynthesizer();
  final painter = buildVisualizerPainter(
    style: VisualizerStyle.tornado,
    config: const VisualizerConfig(style: VisualizerStyle.tornado),
    palette: _palette,
    rawBands: _bands,
    peaks: List<double>.filled(32, 0.8),
    waveformSynth: synth,
    time: time,
    service: service,
  );
  expect(painter, isA<GpuShaderPainter>());
  return painter as GpuShaderPainter;
}

Future<Uint8List> _rasterize(GpuShaderPainter painter) async {
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

Future<void> _pumpCapture(WidgetTester tester, GpuShaderPainter painter) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: const Key('tornado-capture'),
          child: SizedBox(
            width: 480,
            height: 320,
            child: CustomPaint(painter: painter),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Particle tornado renderer honesty', () {
    test('dispatcher selects the tornado shader, not a generic painter', () {
      final painter = _tornadoPainter(service: GpuShaderService.instance);
      expect(painter.shaderType, GpuShaderType.tornado);
      expect(painter.shaderType.assetPath, 'shaders/particle_tornado.frag');
    });

    test(
      'failed compilation exposes CPU fallback and the real error',
      () async {
        final service = GpuShaderService.test(
          loader: (assetPath) async =>
              throw StateError('deterministic compile failure'),
        );
        expect(await service.initialize(), isFalse);

        final painter = _tornadoPainter(service: service);
        expect(painter.compileStatus, GpuShaderCompileStatus.failed);
        expect(painter.rendererKind, VisualizerRendererKind.cpuPainter);
        expect(
          painter.statusDescription,
          contains('shaders/particle_tornado.frag'),
        );
        expect(
          painter.statusDescription,
          contains('deterministic compile failure'),
        );
      },
    );

    for (final succeed in [true, false]) {
      testWidgets(
        'delayed shader ${succeed ? 'success' : 'failure'} repaints the first frame once',
        (tester) async {
          final gate = Completer<ui.FragmentProgram>();
          ui.FragmentProgram? program;
          if (succeed) {
            program = await tester.runAsync(
              () =>
                  ui.FragmentProgram.fromAsset(GpuShaderType.tornado.assetPath),
            );
          }
          final service = GpuShaderService.test(
            loader: (assetPath) {
              if (assetPath == GpuShaderType.tornado.assetPath) {
                return gate.future;
              }
              throw StateError('unused shader: $assetPath');
            },
          );
          final painter = _CountingGpuShaderPainter(service: service);
          addTearDown(painter.dispose);
          late StateSetter rebuildHost;
          final initialization = service.initialize();
          initialization.then((_) => rebuildHost(() {}));

          await tester.pumpWidget(
            MaterialApp(
              home: StatefulBuilder(
                builder: (context, setState) {
                  rebuildHost = setState;
                  return SizedBox(
                    width: 480,
                    height: 320,
                    child: CustomPaint(painter: painter),
                  );
                },
              ),
            ),
          );
          await tester.pump();
          final paintsBeforeCompletion = painter.paintCount;
          expect(paintsBeforeCompletion, greaterThan(0));
          expect(
            painter.compileStatus,
            GpuShaderCompileStatus.compiling,
            reason:
                'The first frame must be painted before the loader completes.',
          );

          if (succeed) {
            gate.complete(program!);
          } else {
            gate.completeError(StateError('delayed compile failure'));
          }
          await tester.pump();
          await tester.pump();
          await initialization;

          expect(
            painter.compileStatus,
            succeed
                ? GpuShaderCompileStatus.compiled
                : GpuShaderCompileStatus.failed,
          );
          expect(
            painter.paintCount,
            greaterThan(paintsBeforeCompletion),
            reason:
                'The cached widget painter must invalidate its loading frame '
                'when asynchronous compilation completes.',
          );

          final settledPaintCount = painter.paintCount;
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            painter.paintCount,
            settledPaintCount,
            reason:
                'Status completion must not start a continuous redraw loop.',
          );
        },
      );
    }

    test('diagnostic TextPainter has deterministic owner teardown', () async {
      for (var cycle = 0; cycle < 3; cycle++) {
        final service = GpuShaderService.test(
          loader: (assetPath) async =>
              throw StateError('deterministic compile failure $cycle'),
        );
        await service.initialize();
        final painter = _tornadoPainter(service: service);
        await _rasterize(painter);
        final cachedText = painter.debugStatusTextPainter;
        expect(cachedText, isNotNull);

        // CustomPainter/RenderCustomPaint has no dispose hook; the owning
        // viewport releases these native text resources on style retirement
        // and teardown. Disposal is deliberately idempotent for teardown races.
        (painter as dynamic).dispose();
        expect(cachedText!.debugDisposed, isTrue);
        expect(painter.debugStatusTextPainter, isNull);
        painter.dispose();
      }
    });

    test('GPU resume disposes the cached diagnostic immediately', () async {
      final program = await ui.FragmentProgram.fromAsset(
        GpuShaderType.tornado.assetPath,
      );
      final gate = Completer<ui.FragmentProgram>();
      final service = GpuShaderService.test(
        loader: (assetPath) {
          if (assetPath == GpuShaderType.tornado.assetPath) {
            return gate.future;
          }
          throw StateError('unused shader: $assetPath');
        },
      );
      final painter = _tornadoPainter(service: service);
      final initialization = service.initialize();
      await _rasterize(painter);
      final cachedText = painter.debugStatusTextPainter;
      expect(cachedText, isNotNull);
      expect(painter.compileStatus, GpuShaderCompileStatus.compiling);

      gate.complete(program);
      await initialization;
      await _rasterize(painter);

      expect(painter.rendererKind, VisualizerRendererKind.gpuShader);
      expect(cachedText!.debugDisposed, isTrue);
      expect(painter.debugStatusTextPainter, isNull);
      painter.dispose();
    });

    test('failed shader never paints the legacy circular fallback', () async {
      final service = GpuShaderService.test(
        loader: (assetPath) async =>
            throw StateError('deterministic compile failure'),
      );
      await service.initialize();
      final painter = _tornadoPainter(service: service);
      addTearDown(painter.dispose);
      final pixels = await _rasterize(painter);

      // With the old implementation the bottom of its audio-reactive ring is
      // centered at (240, 282) for this fixed 480x320 frame and band input.
      var maxGreen = 0;
      for (var y = 279; y <= 284; y++) {
        for (var x = 237; x <= 242; x++) {
          final green = pixels[(y * 480 + x) * 4 + 1];
          if (green > maxGreen) maxGreen = green;
        }
      }
      expect(
        maxGreen,
        lessThan(100),
        reason:
            'A bright ring at the legacy radius would falsely look like '
            'the selected tornado instead of an honest failure notice.',
      );
    });

    testWidgets(
      'failed shader paints a diagnostic golden, never a fallback ring',
      (tester) async {
        final service = GpuShaderService.test(
          loader: (assetPath) async =>
              throw StateError('deterministic compile failure'),
        );
        await service.initialize();
        final painter = _tornadoPainter(service: service);
        addTearDown(painter.dispose);

        await _pumpCapture(tester, painter);
        await expectLater(
          find.byKey(const Key('tornado-capture')),
          matchesGoldenFile('goldens/tornado_shader_failure.png'),
        );
      },
    );

    test(
      'real tornado asset compiles and fixed-time frames show rotation',
      () async {
        final service = GpuShaderService.instance;
        final initialized = await service.initialize();
        expect(
          initialized,
          isTrue,
          reason:
              'This proves Flutter runtime-effect loading only; it is not a '
              'Win10 GPU driver compilation claim.',
        );
        expect(
          service.compileStatusFor(GpuShaderType.tornado),
          GpuShaderCompileStatus.compiled,
        );

        final first = _tornadoPainter(service: service, time: 0.75);
        final second = _tornadoPainter(service: service, time: 2.0);
        expect(first.rendererKind, VisualizerRendererKind.gpuShader);
        final a = await _rasterize(first);
        final b = await _rasterize(second);
        expect(
          _changedPixels(a, b),
          greaterThan(500),
          reason: 'The rotating vortex must not render as a static image.',
        );
      },
    );

    testWidgets('real tornado asset matches a fixed-time software golden', (
      tester,
    ) async {
      final service = GpuShaderService.instance;
      expect(await service.initialize(), isTrue);
      await _pumpCapture(tester, _tornadoPainter(service: service));
      await expectLater(
        find.byKey(const Key('tornado-capture')),
        matchesGoldenFile('goldens/tornado_fixed_time.png'),
      );
    });
  });
}
