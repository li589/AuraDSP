import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../../../platform/platform_profile.dart';
import '../../../engine/native_library_loader.dart';
import 'milkdrop_preset.dart';
import 'projectm_bridge_contract.dart';

typedef _CreateC = Pointer<Void> Function(Int32, Int32, Float);
typedef _CreateDart = Pointer<Void> Function(int, int, double);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);
typedef _ResizeC = Void Function(Pointer<Void>, Int32, Int32);
typedef _ResizeDart = void Function(Pointer<Void>, int, int);
typedef _GetSizeC = Int32 Function(Pointer<Void>);
typedef _GetSizeDart = int Function(Pointer<Void>);
typedef _FeedC = Int32 Function(Pointer<Void>, Pointer<Float>, Int32, Int32);
typedef _FeedDart = int Function(Pointer<Void>, Pointer<Float>, int, int);
typedef _LoadC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _LoadDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _RenderC = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _RenderDart = int Function(Pointer<Void>, Pointer<Uint8>);

/// Real FFI implementation of the optional libprojectM bridge.
class ProjectMNativeBridge implements ProjectMBridge {
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);
  DynamicLibrary? _library;
  Pointer<Void> _handle = nullptr;
  int _width = 0;
  int _height = 0;
  MilkdropPreset? _preset;
  bool _disposed = false;
  late final _CreateDart _create;
  late final _DestroyDart _destroy;
  late final _ResizeDart _resize;
  late final _GetSizeDart _getWidth;
  late final _GetSizeDart _getHeight;
  late final _FeedDart _feed;
  late final _LoadDart _load;
  late final _RenderDart _render;

  @override
  bool get isAvailable => _library != null && _handle != nullptr;

  @override
  bool get isLoaded => _preset != null && isAvailable;

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
    if (_disposed) return false;
    if (isAvailable) return true;
    try {
      final library = NativeLibraryLoader.openFirst(
        PlatformProfile.projectMBridgeLibraryCandidates,
        what: 'projectM bridge',
      );
      _library = library;
      _create = library.lookupFunction<_CreateC, _CreateDart>(
        'auradsp_projectm_create',
      );
      _destroy = library.lookupFunction<_DestroyC, _DestroyDart>(
        'auradsp_projectm_destroy',
      );
      _resize = library.lookupFunction<_ResizeC, _ResizeDart>(
        'auradsp_projectm_resize',
      );
      _getWidth = library.lookupFunction<_GetSizeC, _GetSizeDart>(
        'auradsp_projectm_get_width',
      );
      _getHeight = library.lookupFunction<_GetSizeC, _GetSizeDart>(
        'auradsp_projectm_get_height',
      );
      _feed = library.lookupFunction<_FeedC, _FeedDart>(
        'auradsp_projectm_feed_pcm',
      );
      _load = library.lookupFunction<_LoadC, _LoadDart>(
        'auradsp_projectm_load_preset',
      );
      _render = library.lookupFunction<_RenderC, _RenderDart>(
        'auradsp_projectm_render_pixels',
      );
      _handle = _create(width, height, fps);
      if (_handle == nullptr) {
        _library = null;
        return false;
      }
      _width = _getWidth(_handle);
      _height = _getHeight(_handle);
      return _width > 0 && _height > 0;
    } catch (_) {
      if (_handle != nullptr) {
        _destroy(_handle);
        _handle = nullptr;
      }
      _library = null;
      return false;
    }
  }

  @override
  void resize(int width, int height) {
    if (!isAvailable || width <= 0 || height <= 0) return;
    _resize(_handle, width, height);
    _width = width;
    _height = height;
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
  void feedPcm(List<double> pcmFrames, {int channels = 2}) {
    if (!isAvailable || pcmFrames.isEmpty || channels < 1 || channels > 2) {
      return;
    }
    final pcm = calloc<Float>(pcmFrames.length);
    try {
      for (var i = 0; i < pcmFrames.length; i++) {
        pcm[i] = pcmFrames[i].clamp(-1.0, 1.0);
      }
      final sampleCount = pcmFrames.length - pcmFrames.length % channels;
      if (sampleCount == 0) return;
      _feed(_handle, pcm, sampleCount ~/ channels, channels);
    } finally {
      calloc.free(pcm);
    }
  }

  @override
  int renderFrame() {
    if (!isAvailable || _width <= 0 || _height <= 0) return -2;
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
    if (_handle != nullptr) {
      _destroy(_handle);
      _handle = nullptr;
    }
    _preset = null;
    final image = _frame.value;
    _frame.value = null;
    image?.dispose();
    _frame.dispose();
    _library = null;
  }
}
