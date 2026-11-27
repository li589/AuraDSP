import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/waveform_synthesizer.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../plugins/milkdrop_preset.dart';
import '../plugins/projectm_bridge_contract.dart';
import '../shaders/gpu_shader_service.dart';
import 'style_projectm.dart';
import 'style_cyber_grid.dart';
import 'style_fluid.dart';
import 'style_goniometer.dart';
import 'style_gpu_shader.dart';
import 'style_milkdrop.dart';
import 'style_oscilloscope.dart';
import 'style_pulse_orb.dart';
import 'style_spectrum_bars.dart';

/// 可视化画笔分发器：按选中风格将音频特征状态路由至对应高性能 CustomPainter
///
/// [showGrid] 为可选覆盖：P2-1 把静态网格抽到独立缓存层后，动态画笔不再
/// 自己绘制网格（传 `false`），避免每帧重绘这份不变内容。
CustomPainter buildVisualizerPainter({
  required VisualizerStyle style,
  required VisualizerConfig config,
  required VisualizerPalette palette,
  required List<double> rawBands,
  required List<double> peaks,
  required WaveformSynthesizer waveformSynth,
  required double time,
  bool? showGrid,
  ProjectMBridge? projectMBridge,
  GpuShaderService? service,
}) {
  final grid = showGrid ?? config.showGrid;
  final shaderService = service ?? GpuShaderService.instance;
  void ensureShader(GpuShaderType type) {
    unawaited(shaderService.ensureCompiled(type));
  }

  switch (style) {
    case VisualizerStyle.oscilloscope:
      return OscilloscopePainter(
        waveL: waveformSynth.waveL,
        waveR: waveformSynth.waveR,
        palette: palette,
        showGrid: grid,
        bloom: config.bloom,
        lineWidth: config.lineWidth,
      );

    case VisualizerStyle.goniometer:
      return GoniometerPainter(
        points: waveformSynth.lissajousXY,
        palette: palette,
        showGrid: grid,
        bloom: config.bloom,
        lineWidth: config.lineWidth,
      );

    case VisualizerStyle.cyberGrid:
      return CyberGridPainter(
        bands: rawBands,
        palette: palette,
        bloom: config.bloom,
        animationTime: time,
        lineWidth: config.lineWidth,
      );

    case VisualizerStyle.pulseOrb:
      return PulseOrbPainter(
        bands: rawBands,
        palette: palette,
        bloom: config.bloom,
        animationTime: time,
        lineWidth: config.lineWidth,
      );

    case VisualizerStyle.auroraShader:
      ensureShader(GpuShaderType.aurora);
      return GpuShaderPainter(
        shaderType: GpuShaderType.aurora,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
        service: shaderService,
      );

    case VisualizerStyle.tunnelShader:
      ensureShader(GpuShaderType.tunnel);
      return GpuShaderPainter(
        shaderType: GpuShaderType.tunnel,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
        service: shaderService,
      );

    case VisualizerStyle.harmonicWarp:
      ensureShader(GpuShaderType.harmonicWarp);
      return GpuShaderPainter(
        shaderType: GpuShaderType.harmonicWarp,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
        service: shaderService,
      );

    case VisualizerStyle.bars:
      return SpectrumBarsPainter(
        bands: rawBands,
        peaks: peaks,
        palette: palette,
        showGrid: grid,
        showPeaks: config.showPeaks,
        bloom: config.bloom,
      );

    case VisualizerStyle.fluidDynamics:
      return FluidDynamicsPainter(
        bands: rawBands,
        palette: palette,
        bloom: config.bloom,
        animationTime: time,
      );

    case VisualizerStyle.tornado:
      ensureShader(GpuShaderType.tornado);
      return GpuShaderPainter(
        shaderType: GpuShaderType.tornado,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
        service: shaderService,
      );

    case VisualizerStyle.nebulaFlow:
      ensureShader(GpuShaderType.nebula);
      return GpuShaderPainter(
        shaderType: GpuShaderType.nebula,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
        service: shaderService,
      );

    case VisualizerStyle.projectM:
      final bridge = projectMBridge;
      final nativePreset = bridge?.currentPreset;
      final requestedPath = config.milkdropPresetPath;
      final preset = requestedPath == null || requestedPath.isEmpty
          ? MilkdropPreset.builtInPresets.first
          : nativePreset ?? MilkdropPreset.lightweight(requestedPath);
      if (bridge != null &&
          bridge.isAvailable &&
          bridge.isLoaded &&
          nativePreset != null &&
          config.milkdropPresetPath != null &&
          config.milkdropPresetPath!.isNotEmpty) {
        return ProjectMPainter(
          bridge: bridge,
          fallbackPainter: MilkdropPainter(
            preset: preset,
            bands: rawBands,
            palette: palette,
            time: time,
            sensitivity: config.sensitivity,
            lineWidth: config.lineWidth,
          ),
        );
      }
      return MilkdropPainter(
        preset: preset,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
        lineWidth: config.lineWidth,
      );
  }
}
