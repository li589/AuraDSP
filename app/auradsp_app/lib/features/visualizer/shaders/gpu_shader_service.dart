import 'dart:ui';

import '../../../core/error_sink.dart';

/// Available hardware-accelerated fragment shader types
enum GpuShaderType {
  aurora('shaders/aurora_wave.frag'),
  tunnel('shaders/neon_tunnel.frag');

  final String assetPath;
  const GpuShaderType(this.assetPath);
}

/// Service managing compilation and caching of Flutter GPU FragmentProgram shaders
class GpuShaderService {
  static final GpuShaderService instance = GpuShaderService._();
  GpuShaderService._();

  FragmentProgram? _auroraProgram;
  FragmentProgram? _tunnelProgram;
  bool _initialized = false;
  bool _failed = false;

  /// 每类着色器只创建一个 FragmentShader 实例并复用。
  /// 之前每帧调用 program.fragmentShader()，等于每秒新建几十个原生 shader 对象，
  /// 在 Windows/Skia 下会持续占用原生内存并触发频繁的着色器状态重建。
  final Map<GpuShaderType, FragmentShader> _shaderCache = {};

  bool get isReady => _initialized && !_failed;

  FragmentProgram? getProgram(GpuShaderType type) {
    switch (type) {
      case GpuShaderType.aurora:
        return _auroraProgram;
      case GpuShaderType.tunnel:
        return _tunnelProgram;
    }
  }

  /// 复用型 FragmentShader：调用方每帧只更新 uniform，不再新建对象。
  FragmentShader? shaderFor(GpuShaderType type) {
    final cached = _shaderCache[type];
    if (cached != null) return cached;
    final program = getProgram(type);
    if (program == null) return null;
    final shader = program.fragmentShader();
    _shaderCache[type] = shader;
    return shader;
  }

  /// Initialize and compile shaders asynchronously
  Future<bool> initialize() async {
    if (_initialized) return isReady;

    try {
      _auroraProgram = await FragmentProgram.fromAsset(GpuShaderType.aurora.assetPath);
      _tunnelProgram = await FragmentProgram.fromAsset(GpuShaderType.tunnel.assetPath);
      _initialized = true;
      _failed = false;
      return true;
    } catch (e, st) {
      // 无头测试环境或不支持的光栅器：留痕后降级为纯 CPU 渲染
      swallow(e, st);
      _failed = true;
      _initialized = true;
      return false;
    }
  }
}
