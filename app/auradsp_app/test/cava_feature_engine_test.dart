import 'package:auradsp_app/features/visualizer/controllers/cava_feature_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CavaFeatureEngine Tests', () {
    test('Configures logarithmic bands dynamically', () {
      final engine = CavaFeatureEngine(barCount: 32);
      expect(engine.barCount, 32);

      engine.configure(barCount: 64);
      expect(engine.barCount, 64);

      final out64 = engine.process(List.filled(32, 0.5));
      expect(out64.length, 64);
    });

    test('Perceptual equal loudness weighting boosts higher frequencies', () {
      final engine = CavaFeatureEngine(barCount: 32, autosens: false);
      // Uniform input across all frequencies
      final uniformInput = List.filled(32, 0.3);
      final out = engine.process(uniformInput);

      expect(out.length, 32);
      // Higher frequencies receive greater perceptual weighting than lower
      expect(out[28], greaterThan(out[2]));
    });

    test('Gravity falloff and integral smoothing create continuous decay', () {
      final engine = CavaFeatureEngine(barCount: 32, autosens: false);

      // Frame 1: Pulse input
      final out1 = engine.process([1.0, ...List.filled(31, 0.0)]);
      expect(out1[0], greaterThan(0.08));

      // Frame 2: Silence input -> should smoothly fall off, not drop to zero
      final out2 = engine.process(List.filled(32, 0.0));
      final val2 = out2[0];
      expect(val2, greaterThan(0.0));

      // After multiple silence frames, gravity decay pulls it downwards
      late List<double> outDecayed;
      for (var i = 0; i < 40; i++) {
        outDecayed = engine.process(List.filled(32, 0.0));
      }
      expect(outDecayed[0], lessThan(val2));
    });

    test('Autosens AGC adapts gain on overshoot and silence', () {
      final engine = CavaFeatureEngine(barCount: 32, autosens: true);

      // Overshoot with very loud signal
      final initialSens = engine.currentSensitivity;
      for (var i = 0; i < 10; i++) {
        engine.process(List.filled(32, 2.0));
      }
      // Sensitivity should decrease to prevent clipping
      expect(engine.currentSensitivity, lessThan(initialSens));

      // Drain memory with silence
      for (var i = 0; i < 20; i++) {
        engine.process(List.filled(32, 0.0));
      }

      // Low volume signal should now recover sensitivity
      final reducedSens = engine.currentSensitivity;
      for (var i = 0; i < 50; i++) {
        engine.process(List.filled(32, 0.02));
      }
      expect(engine.currentSensitivity, greaterThan(reducedSens));
    });

    test('Clamps output values strictly between 0.0 and 1.0', () {
      final engine = CavaFeatureEngine(barCount: 32);
      final extreme = engine.process(List.filled(32, 999.0));
      for (final v in extreme) {
        expect(v, lessThanOrEqualTo(1.0));
        expect(v, greaterThanOrEqualTo(0.0));
      }
    });
  });
}
