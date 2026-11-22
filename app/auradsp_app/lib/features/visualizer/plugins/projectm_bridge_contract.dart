import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../platform/platform_profile.dart';
import 'milkdrop_preset.dart';

/// Dart-side mirror of the projectM PCM ABI guard.
///
/// PCM is interleaved and bounded before it reaches FFI. Native code repeats
/// the same checks because Dart validation is not a substitute for an ABI
/// boundary check.
bool isValidProjectMPcm(List<double> pcmFrames, {int channels = 2}) {
  if (pcmFrames.isEmpty || (channels != 1 && channels != 2)) return false;
  if (pcmFrames.length % channels != 0) return false;
  if (pcmFrames.length ~/ channels > 2048) return false;
  return pcmFrames.every(
    (sample) => sample.isFinite && sample >= -1.0 && sample <= 1.0,
  );
}

/// Dart contract for the AuraDSP projectM C ABI.
///
/// The native bridge owns the OpenGL context-bound projectM instance. Pixel
/// frames are exposed as a listenable image so the Flutter painter never calls
/// asynchronous image decoding from its paint method.
abstract interface class ProjectMBridge {
  bool get isAvailable;
  bool get isLoaded;
  MilkdropPreset? get currentPreset;
  ui.Image? get currentFrame;
  ValueListenable<ui.Image?> get frameListenable;

  Future<bool> initialize({
    int width = 1280,
    int height = 720,
    double fps = 60.0,
  });
  void resize(int width, int height);
  bool loadPreset(MilkdropPreset preset);
  void feedPcm(List<double> pcmFrames, {int channels = 2});
  int renderFrame();
  void dispose();
}

/// Fallback bridge used when the optional native library is unavailable.
class MockProjectMBridge implements ProjectMBridge {
  MilkdropPreset? _preset;
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  @override
  bool get isAvailable => PlatformProfile.supportsPlugins;

  @override
  bool get isLoaded => _preset != null;

  @override
  MilkdropPreset? get currentPreset => _preset;

  @override
  ui.Image? get currentFrame => _frame.value;

  @override
  ValueListenable<ui.Image?> get frameListenable => _frame;

  @override
  Future<bool> initialize({
    int width = 1280,
    int height = 720,
    double fps = 60.0,
  }) async => true;

  @override
  void resize(int width, int height) {}

  @override
  bool loadPreset(MilkdropPreset preset) {
    _preset = preset;
    return true;
  }

  @override
  void feedPcm(List<double> pcmFrames, {int channels = 2}) {
    if (!isValidProjectMPcm(pcmFrames, channels: channels)) return;
  }

  @override
  int renderFrame() => -2;

  @override
  void dispose() {
    _preset = null;
    _frame.dispose();
  }
}
