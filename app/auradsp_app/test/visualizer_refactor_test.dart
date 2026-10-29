import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/controllers/peak_physics_engine.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/core/theme.dart';

void main() {
  group('VisualizerConfig & Models', () {
    test('Default configuration invariants', () {
      const cfg = VisualizerConfig();
      expect(cfg.style, VisualizerStyle.bars);
      expect(cfg.colorTheme, VisualizerColorTheme.system);
      expect(cfg.sensitivity, 1.0);
      expect(cfg.decayRate, 0.6);
      expect(cfg.gravity, 1.8);
      expect(cfg.barCount, 32);
      expect(cfg.bloom, 0.5);
      expect(cfg.showGrid, isTrue);
      expect(cfg.showPeaks, isTrue);
      expect(cfg.showDbScale, isTrue);
      expect(cfg.isMaximized, isFalse);
    });

    test('copyWith updates fields immutably', () {
      const cfg = VisualizerConfig();
      final updated = cfg.copyWith(
        style: VisualizerStyle.oscilloscope,
        colorTheme: VisualizerColorTheme.neonCyber,
        sensitivity: 2.5,
        isMaximized: true,
      );

      expect(updated.style, VisualizerStyle.oscilloscope);
      expect(updated.colorTheme, VisualizerColorTheme.neonCyber);
      expect(updated.sensitivity, 2.5);
      expect(updated.isMaximized, isTrue);
      expect(updated.decayRate, 0.6); // unchanged
    });

    test('Palette resolution across themes', () {
      final p = auraDark;
      for (final theme in VisualizerColorTheme.values) {
        final palette = VisualizerPalette.resolve(theme, p);
        expect(palette.gradient.length, greaterThanOrEqualTo(2));
        expect(palette.primary.a, greaterThan(0));
        expect(palette.grid.a, greaterThan(0));
        expect(palette.glow.a, greaterThan(0));
      }
    });
  });

  group('PeakPhysicsEngine', () {
    test('Updates peak values and respects hold/gravity', () {
      final engine = PeakPhysicsEngine();
      final input = List.filled(32, 0.8);

      final p1 = engine.update(input, targetBands: 32);
      expect(p1.length, 32);
      expect(p1[0], closeTo(0.8, 0.01));

      // Silent input: peaks should hold initially
      final silence = List.filled(32, 0.0);
      var pSilence = p1;
      for (var i = 0; i < 5; i++) {
        pSilence = engine.update(silence, targetBands: 32);
      }
      // Still in hold phase
      expect(pSilence[0], closeTo(0.8, 0.01));

      // After many frames, gravity should pull it down
      for (var i = 0; i < 40; i++) {
        pSilence = engine.update(silence, targetBands: 32);
      }
      expect(pSilence[0], lessThan(0.8));

      // Reset restores to zero
      engine.reset();
      final afterReset = engine.update(silence, targetBands: 32);
      expect(afterReset[0], 0.0);
    });

    test('Resampling between 32 and 64 bands', () {
      final engine = PeakPhysicsEngine();
      final input32 = List.generate(32, (i) => i / 31.0);

      final p64 = engine.update(input32, targetBands: 64);
      expect(p64.length, 64);
      expect(p64.first, 0.0);
      expect(p64.last, 1.0);
    });
  });

  group('WaveformSynthesizer', () {
    test('Synthesizes stereo waveform and Lissajous points', () {
      final synth = WaveformSynthesizer();
      final spectrum = List.generate(32, (i) => 0.5);

      synth.update(
        spectrum,
        levelLDbfs: -6.0,
        levelRDbfs: -6.0,
        sensitivity: 1.0,
      );

      expect(synth.waveL.length, WaveformSynthesizer.pointCount);
      expect(synth.waveR.length, WaveformSynthesizer.pointCount);
      expect(synth.lissajousPoints.length, WaveformSynthesizer.pointCount);

      // Verify bounds
      for (final val in synth.waveL) {
        expect(val, inInclusiveRange(-1.0, 1.0));
      }
      for (final pt in synth.lissajousPoints) {
        expect(pt.dx, inInclusiveRange(-1.5, 1.5));
        expect(pt.dy, inInclusiveRange(-1.5, 1.5));
      }
    });

    test('Zero output on silence', () {
      final synth = WaveformSynthesizer();
      synth.update(
        [],
        levelLDbfs: -120.0,
        levelRDbfs: -120.0,
      );

      expect(synth.waveL.every((v) => v == 0.0), isTrue);
      expect(synth.waveR.every((v) => v == 0.0), isTrue);
    });
  });
}
