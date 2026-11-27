import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

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

enum PresetSelectionStatus { idle, loading, ready, failed, timedOut }

/// Observable state of one requested preset generation.
@immutable
class PresetSelection {
  final String? requestedPath;
  final int generation;
  final PresetSelectionStatus status;
  final String? currentPath;
  final String? error;

  const PresetSelection({
    this.requestedPath,
    this.generation = 0,
    this.status = PresetSelectionStatus.idle,
    this.currentPath,
    this.error,
  });
}

/// Dart contract for the AuraDSP projectM C ABI.
///
/// The native bridge owns the OpenGL context-bound projectM instance. Pixel
/// frames are exposed as a listenable image so the Flutter painter never calls
/// asynchronous image decoding from its paint method.
abstract interface class ProjectMBridge {
  bool get isNative;
  bool get isAvailable;
  bool get isLoaded;
  String get statusDescription;
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

/// Implemented by bridges whose native preset parser runs off the Flutter UI
/// thread. Completion is a readback result, not merely request acceptance.
abstract interface class ProjectMAsyncPresetBridge {
  Future<PresetSelection> requestPresetLoad(
    MilkdropPreset preset, {
    required int generation,
  });
}

extension ProjectMBridgePresetRequest on ProjectMBridge {
  Future<PresetSelection> requestPresetSelection(
    MilkdropPreset preset, {
    required int generation,
  }) {
    final bridge = this;
    if (bridge is ProjectMAsyncPresetBridge) {
      return (bridge as ProjectMAsyncPresetBridge).requestPresetLoad(
        preset,
        generation: generation,
      );
    }
    // Compatibility for existing test injection and third-party bridges. The
    // production native bridge implements the asynchronous interface above.
    final accepted = loadPreset(preset);
    final currentPath = currentPreset?.filePath;
    final confirmed = accepted && currentPath == preset.filePath;
    return Future<PresetSelection>.value(
      PresetSelection(
        requestedPath: preset.filePath,
        generation: generation,
        status: confirmed
            ? PresetSelectionStatus.ready
            : PresetSelectionStatus.failed,
        currentPath: currentPath,
        error: confirmed ? null : 'Native current preset was not confirmed',
      ),
    );
  }
}

/// Forwards the newest requested generation immediately; the native render
/// queue serializes/coalesces loads. A request is ready only when native
/// readback confirms the same path.
class ProjectMPresetSelectionController {
  final ProjectMBridge bridge;
  final Duration timeout;
  final Duration retryCooldown;
  final ValueNotifier<PresetSelection> selection =
      ValueNotifier<PresetSelection>(const PresetSelection());

  Timer? _retryTimer;
  _PresetAttempt? _attempt;
  MilkdropPreset? _requestedPreset;
  String? _confirmedPath;
  int _generation = 0;
  bool _disposed = false;

  ProjectMPresetSelectionController(
    this.bridge, {
    this.timeout = const Duration(seconds: 5),
    this.retryCooldown = const Duration(seconds: 5),
  });

  String? get confirmedPath => _confirmedPath;

  void select(MilkdropPreset preset) {
    if (_disposed) return;
    final path = preset.filePath;
    if (path.isEmpty || path.startsWith('builtin:')) {
      clear();
      return;
    }
    if (_requestedPreset?.filePath == path) {
      if (_attempt != null) return;
      switch (selection.value.status) {
        case PresetSelectionStatus.loading:
          return;
        case PresetSelectionStatus.ready:
          if (_confirmedPath == path) return;
        case PresetSelectionStatus.failed:
        case PresetSelectionStatus.timedOut:
          if (_retryTimer?.isActive ?? false) return;
        case PresetSelectionStatus.idle:
          break;
      }
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelAttempt();
    _requestedPreset = preset;
    final generation = ++_generation;
    selection.value = PresetSelection(
      requestedPath: path,
      generation: generation,
      status: PresetSelectionStatus.loading,
      currentPath: _confirmedPath,
    );
    _startLatest();
  }

  void retry() {
    if (_disposed || _requestedPreset == null || _attempt != null) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    final path = _requestedPreset!.filePath;
    selection.value = PresetSelection(
      requestedPath: path,
      generation: ++_generation,
      status: PresetSelectionStatus.loading,
      currentPath: _confirmedPath,
    );
    _startLatest();
  }

  void clear() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelAttempt();
    _requestedPreset = null;
    selection.value = PresetSelection(
      generation: ++_generation,
      currentPath: _confirmedPath,
    );
  }

  /// Invalidates completions belonging to a destroyed native instance.
  void reset() {
    if (_disposed) return;
    _confirmedPath = null;
    clear();
  }

  void _startLatest() {
    if (_disposed || _attempt != null) return;
    final preset = _requestedPreset;
    if (preset == null) return;
    final attempt = _PresetAttempt(_generation, preset);
    _attempt = attempt;
    attempt.timeoutTimer = Timer(timeout, () {
      _completeError(
        attempt,
        TimeoutException('Preset load timed out', timeout),
      );
    });
    Future<PresetSelection> future;
    try {
      future = bridge.requestPresetSelection(
        preset,
        generation: attempt.generation,
      );
    } catch (error) {
      _completeError(attempt, error);
      return;
    }
    future.then(
      (result) => _complete(attempt, result),
      onError: (Object error) => _completeError(attempt, error),
    );
  }

  void _complete(_PresetAttempt attempt, PresetSelection result) {
    if (!identical(_attempt, attempt)) return;
    attempt.timeoutTimer?.cancel();
    _attempt = null;
    if (_disposed) return;
    if (attempt.generation != _generation ||
        _requestedPreset?.filePath != attempt.preset.filePath) {
      _startLatest();
      return;
    }
    final resultMatches =
        result.generation == attempt.generation &&
        result.requestedPath == attempt.preset.filePath;
    final confirmed =
        resultMatches &&
        result.status == PresetSelectionStatus.ready &&
        result.currentPath == attempt.preset.filePath;
    if (confirmed) {
      _confirmedPath = attempt.preset.filePath;
      selection.value = PresetSelection(
        requestedPath: attempt.preset.filePath,
        generation: attempt.generation,
        status: PresetSelectionStatus.ready,
        currentPath: _confirmedPath,
      );
      return;
    }
    final timedOut =
        resultMatches && result.status == PresetSelectionStatus.timedOut;
    selection.value = PresetSelection(
      requestedPath: attempt.preset.filePath,
      generation: attempt.generation,
      status: timedOut
          ? PresetSelectionStatus.timedOut
          : PresetSelectionStatus.failed,
      currentPath: _confirmedPath,
      error: resultMatches
          ? result.error ??
                'Native current preset did not match the requested path'
          : 'Native preset result did not match the request generation or path',
    );
    _scheduleRetry(attempt.generation);
  }

  void _completeError(_PresetAttempt attempt, Object error) {
    if (!identical(_attempt, attempt)) return;
    attempt.timeoutTimer?.cancel();
    _attempt = null;
    if (_disposed) return;
    if (attempt.generation != _generation) {
      _startLatest();
      return;
    }
    final timedOut = error is TimeoutException;
    selection.value = PresetSelection(
      requestedPath: attempt.preset.filePath,
      generation: attempt.generation,
      status: timedOut
          ? PresetSelectionStatus.timedOut
          : PresetSelectionStatus.failed,
      currentPath: _confirmedPath,
      error: timedOut ? 'Preset load timed out' : '$error',
    );
    _scheduleRetry(attempt.generation);
  }

  void _scheduleRetry(int generation) {
    _retryTimer?.cancel();
    _retryTimer = Timer(retryCooldown, () {
      if (_disposed || generation != _generation) return;
      retry();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _cancelAttempt();
    _requestedPreset = null;
    selection.dispose();
  }

  void _cancelAttempt() {
    _attempt?.timeoutTimer?.cancel();
    _attempt = null;
  }
}

class _PresetAttempt {
  final int generation;
  final MilkdropPreset preset;
  Timer? timeoutTimer;
  _PresetAttempt(this.generation, this.preset);
}

/// Fallback bridge used when the optional native library is unavailable.
class MockProjectMBridge implements ProjectMBridge {
  @override
  final String statusDescription;

  /// Whether this fallback represents a failed native discovery that should be
  /// retried on the next factory access. Explicitly injected mocks return false.
  final bool reprobeOnAccess;
  MilkdropPreset? _preset;
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  MockProjectMBridge({
    this.statusDescription = 'Procedural simulation',
    this.reprobeOnAccess = false,
  });

  @override
  bool get isNative => false;

  @override
  bool get isAvailable => false;

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
