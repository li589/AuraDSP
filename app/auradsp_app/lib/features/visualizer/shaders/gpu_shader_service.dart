import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../../core/error_sink.dart';

/// Available hardware-accelerated fragment shader types
enum GpuShaderType {
  aurora('shaders/aurora_wave.frag'),
  tunnel('shaders/neon_tunnel.frag'),
  tornado('shaders/particle_tornado.frag'),
  nebula('shaders/nebula_flow.frag'),
  harmonicWarp('shaders/harmonic_warp.frag');

  final String assetPath;
  const GpuShaderType(this.assetPath);
}

enum GpuShaderCompileStatus { idle, compiling, compiled, failed }

typedef FragmentProgramLoader = Future<FragmentProgram> Function(
  String assetPath,
);

/// Service managing compilation and caching of Flutter GPU FragmentProgram shaders
class GpuShaderService extends ChangeNotifier {
  static final GpuShaderService instance = GpuShaderService._();

  final FragmentProgramLoader _loader;
  final Map<GpuShaderType, FragmentProgram> _programs = {};
  final Map<GpuShaderType, GpuShaderCompileStatus> _compileStatus = {
    for (final type in GpuShaderType.values) type: GpuShaderCompileStatus.idle,
  };
  final Map<GpuShaderType, String> _errors = {};
  bool _initialized = false;

  GpuShaderService._() : _loader = FragmentProgram.fromAsset;

  /// Deterministic failure injection for renderer tests. Production uses [instance].
  factory GpuShaderService.test({required FragmentProgramLoader loader}) {
    return GpuShaderService._withLoader(loader);
  }

  GpuShaderService._withLoader(this._loader);

  /// 每类着色器只创建一个 FragmentShader 实例并复用。
  /// 之前每帧调用 program.fragmentShader()，等于每秒新建几十个原生 shader 对象，
  /// 在 Windows/Skia 下会持续占用原生内存并触发频繁的着色器状态重建。
  final Map<GpuShaderType, FragmentShader> _shaderCache = {};

  bool get isReady =>
      _initialized &&
      _compileStatus.values.every(
        (status) => status == GpuShaderCompileStatus.compiled,
      );

  FragmentProgram? getProgram(GpuShaderType type) => _programs[type];

  GpuShaderCompileStatus compileStatusFor(GpuShaderType type) =>
      _compileStatus[type]!;

  String? errorFor(GpuShaderType type) => _errors[type];

  /// 复用型 FragmentShader：调用方每帧只更新 uniform，不再新建对象。
  FragmentShader? shaderFor(GpuShaderType type) {
    final cached = _shaderCache[type];
    if (cached != null) return cached;
    final program = getProgram(type);
    if (program == null ||
        _compileStatus[type] == GpuShaderCompileStatus.failed) {
      return null;
    }
    try {
      final shader = program.fragmentShader();
      _shaderCache[type] = shader;
      return shader;
    } catch (e, st) {
      swallow(e, st);
      _compileStatus[type] = GpuShaderCompileStatus.failed;
      _errors[type] = e.toString();
      return null;
    }
  }

  /// Initialize shaders independently: one broken asset must not hide the status
  /// of the others or prevent already compiled shaders from rendering.
  Future<bool> initialize() async {
    if (_initialized) return isReady;

    for (final type in GpuShaderType.values) {
      _compileStatus[type] = GpuShaderCompileStatus.compiling;
      try {
        _programs[type] = await _loader(type.assetPath);
        _compileStatus[type] = GpuShaderCompileStatus.compiled;
        _errors.remove(type);
        notifyListeners();
      } catch (e, st) {
        swallow(e, st);
        _programs.remove(type);
        _shaderCache.remove(type);
        _compileStatus[type] = GpuShaderCompileStatus.failed;
        _errors[type] = e.toString();
        notifyListeners();
      }
    }
    _initialized = true;
    return isReady;
  }
}
