import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error_sink.dart';
import '../../../platform/platform_profile.dart';
import '../../../engine/native_library_loader.dart';
import 'milkdrop_preset.dart';
import 'projectm_bridge_contract.dart';

typedef _CreateC = Pointer<Void> Function(Int32, Int32, Float, Int32);
typedef _CreateDart = Pointer<Void> Function(int, int, double, int);
typedef _DestroyC = Int32 Function(Pointer<Void>);
typedef _DestroyDart = int Function(Pointer<Void>);
typedef _ResizeC = Int32 Function(Pointer<Void>, Int32, Int32);
typedef _ResizeDart = int Function(Pointer<Void>, int, int);
typedef _SetActiveC = Int32 Function(Pointer<Void>, Int32);
typedef _SetActiveDart = int Function(Pointer<Void>, int);
typedef _HasContextC = Int32 Function();
typedef _HasContextDart = int Function();
typedef _GetSizeC = Int32 Function(Pointer<Void>);
typedef _GetSizeDart = int Function(Pointer<Void>);
typedef _FeedC = Int32 Function(Pointer<Void>, Pointer<Float>, Int32, Int32);
typedef _FeedDart = int Function(Pointer<Void>, Pointer<Float>, int, int);
typedef _LoadC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _LoadDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _RequestLoadC = Uint64 Function(Pointer<Void>, Pointer<Utf8>);
typedef _RequestLoadDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _ReadLoadC = Int32 Function(
  Pointer<Void>,
  Uint64,
  Pointer<Utf8>,
  IntPtr,
);
typedef _ReadLoadDart = int Function(Pointer<Void>, int, Pointer<Utf8>, int);
typedef _RenderC = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _RenderDart = int Function(Pointer<Void>, Pointer<Uint8>);

typedef ProjectMCreateResult = ({int handle, int width, int height});
typedef ProjectMCreator = Future<ProjectMCreateResult> Function(
  int width,
  int height,
  double fps,
  bool active,
);

Future<void> _destroyProjectMOffUi(int address) {
  return Isolate.run(() {
    final library = NativeLibraryLoader.openFirst(
      PlatformProfile.projectMBridgeLibraryCandidates,
      what: 'projectM bridge',
    );
    final destroy = library.lookupFunction<_DestroyC, _DestroyDart>(
      'auradsp_projectm_destroy',
    );
    if (destroy(Pointer<Void>.fromAddress(address)) != 0) {
      throw StateError('projectM destroy failed');
    }
  });
}

Future<ProjectMCreateResult> _createProjectMOffUi(
  int width,
  int height,
  double fps,
  bool active,
) {
  return Isolate.run(() {
    final library = NativeLibraryLoader.openFirst(
      PlatformProfile.projectMBridgeLibraryCandidates,
      what: 'projectM bridge',
    );
    final hasContext = library.lookupFunction<_HasContextC, _HasContextDart>(
      'auradsp_projectm_has_current_gl_context',
    );
    if (hasContext() == 0) return (handle: 0, width: 0, height: 0);
    final create = library.lookupFunction<_CreateC, _CreateDart>(
      'auradsp_projectm_create_with_activity',
    );
    final getWidth = library.lookupFunction<_GetSizeC, _GetSizeDart>(
      'auradsp_projectm_get_width',
    );
    final getHeight = library.lookupFunction<_GetSizeC, _GetSizeDart>(
      'auradsp_projectm_get_height',
    );
    final handle = create(width, height, fps, active ? 1 : 0);
    if (handle == nullptr) return (handle: 0, width: 0, height: 0);
    return (
      handle: handle.address,
      width: getWidth(handle),
      height: getHeight(handle),
    );
  });
}

/// Real FFI implementation of the optional libprojectM bridge.
///
/// Context ownership (amended 2026-11-23, wiring round W3/W4): the
/// native bridge owns its GL context on its own render thread, so
/// the host no longer proves or provides any context — the previous
/// verifier gate could never pass from a Flutter host and kept the
/// whole chain permanently unavailable.
class ProjectMNativeBridge
    implements
        ProjectMBridge,
        ProjectMAsyncPresetBridge,
        ProjectMActivityController {
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);
  DynamicLibrary? _library;
  Pointer<Void> _handle = nullptr;
  int _width = 0;
  int _height = 0;
  MilkdropPreset? _preset;
  bool _disposed = false;
  bool _desiredActive = true;
  Future<bool>? _initializing;
  Pointer<Void>? _pendingHandle;
  Future<void>? _cleanupInFlight;
  Pointer<Void>? _cleanupHandle;
  final ProjectMCreator? creator;
  late _ResizeDart _resize;
  late _SetActiveDart _setActive;
  late _FeedDart _feed;
  late _LoadDart _load;
  late _RequestLoadDart _requestLoad;
  late _ReadLoadDart _readLoad;
  late _RenderDart _render;
  late _HasContextDart _hasCurrentGlContext;

  bool _ffiBound = false;

  ProjectMNativeBridge({this.creator});

  @override
  bool get isNative => true;

  @override
  bool get isAvailable => !_disposed && _library != null && _handle != nullptr;

  @override
  bool get isLoaded => _preset != null && isAvailable;

  @override
  String get statusDescription => isAvailable
      ? 'libprojectM hardware accelerated'
      : 'libprojectM bridge not initialized (procedural fallback)';

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
  }) {
    if (_disposed) return Future<bool>.value(false);
    if (isAvailable) {
      _applyActive();
      return Future<bool>.value(true);
    }
    final existing = _initializing;
    if (existing != null) return existing;
    final future = _initialize(width: width, height: height, fps: fps);
    _initializing = future;
    return future.whenComplete(() {
      if (identical(_initializing, future)) _initializing = null;
    });
  }

  Future<bool> _initialize({
    required int width,
    required int height,
    required double fps,
  }) async {
    if (_pendingHandle != null || _handle != nullptr) {
      await _cleanupPending();
      if (_pendingHandle != null || _handle != nullptr) return false;
    }
    try {
      final created = await (creator ?? _createProjectMOffUi)(
        width,
        height,
        fps,
        _desiredActive,
      );
      if (created.handle == 0) return false;
      final handle = Pointer<Void>.fromAddress(created.handle);
      _pendingHandle = handle;
      final library = NativeLibraryLoader.openFirst(
        PlatformProfile.projectMBridgeLibraryCandidates,
        what: 'projectM bridge',
      );
      _library = library;
      if (!_ffiBound) {
        _resize = library.lookupFunction<_ResizeC, _ResizeDart>(
          'auradsp_projectm_resize',
        );
        _setActive = library.lookupFunction<_SetActiveC, _SetActiveDart>(
          'auradsp_projectm_set_active',
        );
        _hasCurrentGlContext = library
            .lookupFunction<_HasContextC, _HasContextDart>(
              'auradsp_projectm_has_current_gl_context',
            );
        _feed = library.lookupFunction<_FeedC, _FeedDart>(
          'auradsp_projectm_feed_pcm',
        );
        _load = library.lookupFunction<_LoadC, _LoadDart>(
          'auradsp_projectm_load_preset',
        );
        _requestLoad = library.lookupFunction<_RequestLoadC, _RequestLoadDart>(
          'auradsp_projectm_request_preset_load',
        );
        _readLoad = library.lookupFunction<_ReadLoadC, _ReadLoadDart>(
          'auradsp_projectm_read_preset_load',
        );
        _render = library.lookupFunction<_RenderC, _RenderDart>(
          'auradsp_projectm_render_pixels',
        );
        _ffiBound = true;
      }
      if (_hasCurrentGlContext() == 0) {
        throw StateError('projectM GL platform is unavailable');
      }
      if (_disposed) {
        await _cleanupPending();
        return false;
      }
      _handle = handle;
      _pendingHandle = null;
      _width = created.width;
      _height = created.height;
      if (_width <= 0 || _height <= 0) {
        await _cleanupPending();
        return false;
      }
      _applyActive();
      return true;
    } catch (e, st) {
      swallow(e, st);
      await _cleanupPending();
      _library = null;
      return false;
    }
  }

  Future<void> _cleanupPending() async {
    final handle = _pendingHandle ?? _handle;
    if (handle == nullptr) return;
    try {
      await _cleanupNativeHandle(handle);
    } catch (e, st) {
      swallow(e, st);
      return;
    }
    if (identical(_pendingHandle, handle)) _pendingHandle = null;
    if (identical(_handle, handle)) _handle = nullptr;
  }

  Future<void> _cleanupNativeHandle(Pointer<Void> handle) {
    final existing = _cleanupInFlight;
    if (existing != null && identical(_cleanupHandle, handle)) return existing;
    final future = _destroyProjectMOffUi(handle.address);
    _cleanupHandle = handle;
    _cleanupInFlight = future;
    return future.whenComplete(() {
      if (identical(_cleanupInFlight, future)) {
        _cleanupInFlight = null;
        _cleanupHandle = null;
      }
    });
  }

  void _applyActive() {
    if (!isAvailable) return;
    _setActive(_handle, _desiredActive ? 1 : 0);
  }

  @override
  void resize(int width, int height) {
    if (!isAvailable || width <= 0 || height <= 0) return;
    if (_resize(_handle, width, height) != 0) return;
    _width = width;
    _height = height;
  }

  @override
  void setActive(bool active) {
    _desiredActive = active;
    _applyActive();
  }

  @override
  bool loadPreset(MilkdropPreset preset) {
    if (!isAvailable ||
        preset.filePath.isEmpty ||
        preset.filePath.startsWith('builtin:')) {
      return false;
    }
    final path = preset.filePath.toNativeUtf8();
    try {
      final result = _load(_handle, path);
      if (result == 0) _preset = preset;
      return result == 0;
    } finally {
      malloc.free(path);
    }
  }

  @override
  Future<PresetSelection> requestPresetLoad(
    MilkdropPreset preset, {
    required int generation,
  }) async {
    PresetSelection finish(
      PresetSelectionStatus status,
      String? currentPath,
      String? error,
    ) {
      return PresetSelection(
        requestedPath: preset.filePath,
        generation: generation,
        status: status,
        currentPath: currentPath,
        error: error,
      );
    }

    if (!isAvailable ||
        preset.filePath.isEmpty ||
        preset.filePath.startsWith('builtin:')) {
      return finish(
        PresetSelectionStatus.failed,
        _preset?.filePath,
        'Native preset path is unavailable',
      );
    }
    final path = preset.filePath.toNativeUtf8();
    final int requestId;
    try {
      requestId = _requestLoad(_handle, path);
    } finally {
      malloc.free(path);
    }
    if (requestId == 0) {
      return finish(
        PresetSelectionStatus.failed,
        _preset?.filePath,
        'Native preset request was rejected',
      );
    }

    const bufferSize = 32768;
    final current = calloc<Uint8>(bufferSize);
    final stopwatch = Stopwatch()..start();
    try {
      while (isAvailable && !_disposed) {
        current[0] = 0;
        final result = _readLoad(
          _handle,
          requestId,
          current.cast<Utf8>(),
          bufferSize,
        );
        final currentPath = current[0] == 0
            ? null
            : current.cast<Utf8>().toDartString();
        if (result == 0) {
          if (currentPath != preset.filePath) {
            return finish(
              PresetSelectionStatus.failed,
              currentPath,
              'Native current preset did not match the request',
            );
          }
          _preset = preset;
          return finish(PresetSelectionStatus.ready, currentPath, null);
        }
        if (result != 1) {
          final message = result == -4
              ? 'Native preset request was superseded'
              : 'Native preset load failed ($result)';
          return finish(
            PresetSelectionStatus.failed,
            currentPath ?? _preset?.filePath,
            message,
          );
        }
        if (stopwatch.elapsed >= const Duration(seconds: 5)) {
          return finish(
            PresetSelectionStatus.timedOut,
            _preset?.filePath,
            'Preset load timed out',
          );
        }
        // Only this cheap readback runs on the Flutter UI thread. Parse/load
        // executes on the native render queue after request_preset_load.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return finish(
        PresetSelectionStatus.failed,
        _preset?.filePath,
        'Native bridge was disposed during preset load',
      );
    } finally {
      calloc.free(current);
      stopwatch.stop();
    }
  }

  @override
  void feedPcm(List<double> pcmFrames, {int channels = 2}) {
    if (!isAvailable || !isValidProjectMPcm(pcmFrames, channels: channels)) {
      return;
    }
    final frames = pcmFrames.length ~/ channels;
    final pcm = calloc<Float>(pcmFrames.length);
    try {
      for (var i = 0; i < pcmFrames.length; i++) {
        pcm[i] = pcmFrames[i];
      }
      _feed(_handle, pcm, frames, channels);
    } finally {
      calloc.free(pcm);
    }
  }

  @override
  int renderFrame() {
    if (!isAvailable || _width <= 0 || _height <= 0) {
      return -2;
    }
    final pixels = calloc<Uint8>(_width * _height * 4);
    try {
      final result = _render(_handle, pixels);
      if (result != 0) return result;
      final copy = Uint8List.fromList(pixels.asTypedList(_width * _height * 4));
      final frameWidth = _width;
      final frameHeight = _height;
      ui.decodeImageFromPixels(
        copy,
        frameWidth,
        frameHeight,
        ui.PixelFormat.rgba8888,
        (image) {
          if (_disposed) {
            image.dispose();
            return;
          }
          final previous = _frame.value;
          _frame.value = image;
          previous?.dispose();
        },
        rowBytes: frameWidth * 4,
      );
      return 0;
    } finally {
      calloc.free(pixels);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _desiredActive = false;
    final handle = _pendingHandle ?? _handle;
    if (handle != nullptr) {
      unawaited(_cleanupNativeHandle(handle).then(
        (_) {
          if (identical(_pendingHandle, handle)) _pendingHandle = null;
          if (identical(_handle, handle)) _handle = nullptr;
        },
        onError: (Object error, StackTrace stack) {
          swallow(error, stack);
        },
      ));
    }
    _preset = null;
    final image = _frame.value;
    _frame.value = null;
    image?.dispose();
    _frame.dispose();
    _library = null;
  }
}

/// Central factory for discovering and creating ProjectMBridge instances.
///
/// Probes the platform library candidates once: when a native bridge
/// library exists, the result is the (still uninitialized)
/// [ProjectMNativeBridge] — it opens the library itself inside
/// `initialize` and creates its context-owning native instance.
/// When no library can be opened, the result is the procedural
/// [MockProjectMBridge]. `isNative` therefore means
/// "native library present"; only `isAvailable` (post-initialize)
/// means the native engine is actually rendering.
abstract final class ProjectMBridgeFactory {
  static ProjectMBridge? _instance;

  static ProjectMBridge get instance {
    final current = _instance;
    if (current == null ||
        (current is MockProjectMBridge && current.reprobeOnAccess)) {
      // A missing DLL may appear after application update or first-run asset
      // installation. Never make the first failed probe a permanent fallback.
      // Explicitly injected mocks remain stable for tests and host wiring.
      _instance = create();
    }
    return _instance!;
  }

  @visibleForTesting
  static set instance(ProjectMBridge bridge) => _instance = bridge;

  static ProjectMBridge create() {
    final candidates = PlatformProfile.projectMBridgeLibraryCandidates;
    if (candidates.isEmpty) {
      return MockProjectMBridge(
        statusDescription: 'Platform does not support native plugins',
      );
    }
    try {
      NativeLibraryLoader.openFirst(
        candidates,
        what: 'auradsp_projectm_bridge',
      );
      return ProjectMNativeBridge();
    } catch (e, st) {
      swallow(e, st);
      return MockProjectMBridge(
        statusDescription: 'Native library not found (procedural simulation)',
        reprobeOnAccess: true,
      );
    }
  }
}
