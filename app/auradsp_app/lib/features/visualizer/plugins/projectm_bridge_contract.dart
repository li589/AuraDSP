import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../../../engine/native_library_loader.dart';
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

typedef _CreateNative = Pointer<Void> Function(Int32 width, Int32 height, Float fps);
typedef _CreateDart = Pointer<Void> Function(int width, int height, double fps);

typedef _DestroyNative = Void Function(Pointer<Void> handle);
typedef _DestroyDart = void Function(Pointer<Void> handle);

typedef _ResizeNative = Void Function(Pointer<Void> handle, Int32 width, Int32 height);
typedef _ResizeDart = void Function(Pointer<Void> handle, int width, int height);

typedef _FeedPcmNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Float> pcm,
  Int32 frames,
  Int32 channels,
);
typedef _FeedPcmDart = int Function(
  Pointer<Void> handle,
  Pointer<Float> pcm,
  int frames,
  int channels,
);

typedef _LoadPresetNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Utf8> presetPath,
);
typedef _LoadPresetDart = int Function(
  Pointer<Void> handle,
  Pointer<Utf8> presetPath,
);

typedef _RenderPixelsNative = Int32 Function(
  Pointer<Void> handle,
  Pointer<Uint8> outRgba,
);
typedef _RenderPixelsDart = int Function(
  Pointer<Void> handle,
  Pointer<Uint8> outRgba,
);

/// Native C-ABI implementation of ProjectMBridge via libprojectM bridge DLL/so.
class NativeProjectMBridge implements ProjectMBridge {
  final DynamicLibrary _lib;
  final String libraryName;

  late final _CreateDart _createFn;
  late final _DestroyDart _destroyFn;
  late final _ResizeDart _resizeFn;
  late final _FeedPcmDart _feedPcmFn;
  late final _LoadPresetDart _loadPresetFn;
  late final _RenderPixelsDart _renderPixelsFn;

  Pointer<Void>? _handle;
  MilkdropPreset? _preset;
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  Pointer<Float>? _pcmBuffer;
  int _pcmBufferCapacity = 0;
  Pointer<Uint8>? _pixelBuffer;
  int _pixelBufferSize = 0;
  int _width = 1280;
  int _height = 720;
  bool _isDisposed = false;

  NativeProjectMBridge(this._lib, {required this.libraryName}) {
    _createFn = _lib.lookupFunction<_CreateNative, _CreateDart>(
      'auradsp_projectm_create',
    );
    _destroyFn = _lib.lookupFunction<_DestroyNative, _DestroyDart>(
      'auradsp_projectm_destroy',
    );
    _resizeFn = _lib.lookupFunction<_ResizeNative, _ResizeDart>(
      'auradsp_projectm_resize',
    );
    _feedPcmFn = _lib.lookupFunction<_FeedPcmNative, _FeedPcmDart>(
      'auradsp_projectm_feed_pcm',
    );
    _loadPresetFn = _lib.lookupFunction<_LoadPresetNative, _LoadPresetDart>(
      'auradsp_projectm_load_preset',
    );
    _renderPixelsFn = _lib
        .lookupFunction<_RenderPixelsNative, _RenderPixelsDart>(
          'auradsp_projectm_render_pixels',
        );
  }

  @override
  bool get isNative => true;

  @override
  bool get isAvailable => _handle != null && !_isDisposed;

  @override
  bool get isLoaded => _preset != null;

  @override
  String get statusDescription => 'libprojectM accelerated ($libraryName)';

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
  }) async {
    if (_isDisposed) return false;
    _width = width > 0 ? width : 1280;
    _height = height > 0 ? height : 720;
    try {
      _handle = _createFn(_width, _height, fps);
      _allocatePixelBuffer(_width, _height);
      return _handle != null && _handle != nullptr;
    } catch (_) {
      return false;
    }
  }

  void _allocatePixelBuffer(int w, int h) {
    final needed = w * h * 4;
    if (_pixelBuffer != null && _pixelBufferSize < needed) {
      calloc.free(_pixelBuffer!);
      _pixelBuffer = null;
    }
    if (_pixelBuffer == null) {
      _pixelBuffer = calloc<Uint8>(needed);
      _pixelBufferSize = needed;
    }
  }

  @override
  void resize(int width, int height) {
    if (_handle == null || _isDisposed || width <= 0 || height <= 0) return;
    _width = width;
    _height = height;
    _resizeFn(_handle!, width, height);
    _allocatePixelBuffer(width, height);
  }

  @override
  bool loadPreset(MilkdropPreset preset) {
    if (_handle == null || _isDisposed) return false;
    _preset = preset;
    final pathPtr = preset.filePath.toNativeUtf8();
    try {
      final res = _loadPresetFn(_handle!, pathPtr);
      return res == 0;
    } finally {
      calloc.free(pathPtr);
    }
  }

  @override
  void feedPcm(List<double> pcmFrames, {int channels = 2}) {
    if (_handle == null || _isDisposed) return;
    if (!isValidProjectMPcm(pcmFrames, channels: channels)) return;

    final framesPerChannel = pcmFrames.length ~/ channels;
    if (_pcmBuffer == null || _pcmBufferCapacity < pcmFrames.length) {
      if (_pcmBuffer != null) calloc.free(_pcmBuffer!);
      _pcmBuffer = calloc<Float>(pcmFrames.length);
      _pcmBufferCapacity = pcmFrames.length;
    }
    final buf = _pcmBuffer!.asTypedList(pcmFrames.length);
    for (var i = 0; i < pcmFrames.length; i++) {
      buf[i] = pcmFrames[i];
    }
    _feedPcmFn(_handle!, _pcmBuffer!, framesPerChannel, channels);
  }

  @override
  int renderFrame() {
    if (_handle == null || _pixelBuffer == null || _isDisposed) return -1;
    final res = _renderPixelsFn(_handle!, _pixelBuffer!);
    if (res == 0) {
      final bytes = Uint8List.fromList(
        _pixelBuffer!.asTypedList(_width * _height * 4),
      );
      ui.decodeImageFromPixels(
        bytes,
        _width,
        _height,
        ui.PixelFormat.rgba8888,
        (image) {
          if (!_isDisposed) {
            _frame.value?.dispose();
            _frame.value = image;
          } else {
            image.dispose();
          }
        },
      );
    }
    return res;
  }

  @override
  void dispose() {
    _isDisposed = true;
    if (_handle != null && _handle != nullptr) {
      _destroyFn(_handle!);
      _handle = null;
    }
    if (_pcmBuffer != null) {
      calloc.free(_pcmBuffer!);
      _pcmBuffer = null;
    }
    if (_pixelBuffer != null) {
      calloc.free(_pixelBuffer!);
      _pixelBuffer = null;
    }
    _frame.value?.dispose();
    _frame.dispose();
  }
}

/// Fallback bridge used when the optional native library is unavailable.
class MockProjectMBridge implements ProjectMBridge {
  final String _statusDescription;
  MilkdropPreset? _preset;
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);

  MockProjectMBridge({
    this._statusDescription = 'Procedural simulation',
  });

  @override
  bool get isNative => false;

  @override
  bool get isAvailable => false;

  @override
  bool get isLoaded => _preset != null;

  @override
  String get statusDescription => _statusDescription;

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

/// Central factory for discovering, binding and creating ProjectMBridge instances.
abstract final class ProjectMBridgeFactory {
  static ProjectMBridge? _instance;

  static ProjectMBridge get instance => _instance ??= create();

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
      String? matched;
      final lib = NativeLibraryLoader.openFirst(
        candidates,
        what: 'auradsp_projectm_bridge',
        onOpened: (name) => matched = name,
      );
      return NativeProjectMBridge(lib, libraryName: matched ?? candidates.first);
    } catch (_) {
      return MockProjectMBridge(
        statusDescription: 'Native library not found (procedural simulation)',
      );
    }
  }
}
