import 'package:flutter/material.dart';

import '../controllers/waveform_synthesizer.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../plugins/milkdrop_preset.dart';
import '../shaders/gpu_shader_service.dart';
import 'style_cyber_grid.dart';
import 'style_fluid.dart';
import 'style_goniometer.dart';
import 'style_gpu_shader.dart';
import 'style_milkdrop.dart';
import 'style_oscilloscope.dart';
import 'style_pulse_orb.dart';
import 'style_spectrum_bars.dart';
import 'style_tornado.dart';

/// 可视化画笔分发器：按选中风格将音频特征状态路由至对应高性能 CustomPainter
CustomPainter buildVisualizerPainter({
  required VisualizerStyle style,
  required VisualizerConfig config,
  required VisualizerPalette palette,
  required List<double> rawBands,
  required List<double> peaks,
  required WaveformSynthesizer waveformSynth,
  required double time,
}) {
  switch (style) {
    case VisualizerStyle.oscilloscope:
      return OscilloscopePainter(
        waveL: waveformSynth.waveL,
        waveR: waveformSynth.waveR,
        palette: palette,
        showGrid: config.showGrid,
        bloom: config.bloom,
        lineWidth: config.lineWidth,
      );

    case VisualizerStyle.goniometer:
      return GoniometerPainter(
        points: waveformSynth.lissajousPoints,
        palette: palette,
        showGrid: config.showGrid,
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
      return GpuShaderPainter(
        shaderType: GpuShaderType.aurora,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
      );

    case VisualizerStyle.tunnelShader:
      return GpuShaderPainter(
        shaderType: GpuShaderType.tunnel,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
      );

    case VisualizerStyle.milkDrop:
      return MilkdropPainter(
        preset: MilkdropPreset.builtInPresets.first,
        bands: rawBands,
        palette: palette,
        time: time,
        sensitivity: config.sensitivity,
        lineWidth: config.lineWidth,
      );

    case VisualizerStyle.bars:
      return SpectrumBarsPainter(
        bands: rawBands,
        peaks: peaks,
        palette: palette,
        showGrid: config.showGrid,
        showPeaks: config.showPeaks,
        bloom: config.bloom,
      );

    case VisualizerStyle.fluid:
      return FluidSilkPainter(
        bands: rawBands,
        palette: palette,
        bloom: config.bloom,
        animationTime: time,
        lineWidth: config.lineWidth,
      );

    case VisualizerStyle.tornado:
      return ParticleTornadoPainter(
        bands: rawBands,
        palette: palette,
        bloom: config.bloom,
        animationTime: time,
        lineWidth: config.lineWidth,
      );
  }
}
