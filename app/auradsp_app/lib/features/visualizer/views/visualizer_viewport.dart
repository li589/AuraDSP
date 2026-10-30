import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../ui/widgets.dart' show FreqAxis;
import '../controllers/peak_physics_engine.dart';
import '../controllers/waveform_synthesizer.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../styles/style_atmosphere.dart';
import '../styles/visualizer_painter_dispatcher.dart';
import 'visualizer_db_scale.dart';

/// 视效主舞台活跃渲染画布视口
class VisualizerCanvasViewport extends StatelessWidget {
  final Animation<double> animation;
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<double> levelL;
  final ValueListenable<double> levelR;
  final VisualizerConfig config;
  final VisualizerPalette palette;
  final PeakPhysicsEngine peakEngine;
  final WaveformSynthesizer waveformSynth;
  final double time;

  const VisualizerCanvasViewport({
    super.key,
    required this.animation,
    required this.spectrum,
    required this.levelL,
    required this.levelR,
    required this.config,
    required this.palette,
    required this.peakEngine,
    required this.waveformSynth,
    required this.time,
  });

  bool _usesAmbience(VisualizerStyle style) => switch (style) {
        // 自带完整背景构图（光晕/地面雾气）的风格不再叠加星尘氛围层，避免双层噪点
        VisualizerStyle.auroraShader ||
        VisualizerStyle.tunnelShader ||
        VisualizerStyle.milkDrop ||
        VisualizerStyle.fluidDynamics ||
        VisualizerStyle.tornado =>
          false,
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, _) => ValueListenableBuilder<List<double>>(
        valueListenable: spectrum,
        builder: (_, rawBands, _) {
          final peaks = peakEngine.update(
            rawBands,
            targetBands: config.barCount,
            sensitivity: config.sensitivity,
            gravity: config.gravity,
            decay: config.decayRate,
          );

          waveformSynth.update(
            rawBands,
            levelLDbfs: levelL.value,
            levelRDbfs: levelR.value,
            sensitivity: config.sensitivity,
          );

          final renderedBands = peakEngine.renderedBands.isNotEmpty
              ? peakEngine.renderedBands
              : rawBands;

          final painter = buildVisualizerPainter(
            style: config.style,
            config: config,
            palette: palette,
            rawBands: renderedBands,
            peaks: peaks,
            waveformSynth: waveformSynth,
            time: time,
          );

          Widget body;
          if (config.style == VisualizerStyle.bars) {
            body = Padding(
              padding: const EdgeInsets.fromLTRB(
                AuraSpace.xl,
                AuraSpace.lg,
                AuraSpace.xl,
                AuraSpace.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: painter,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                        if (config.showGrid) ...[
                          const SizedBox(height: AuraSpace.sm),
                          const FreqAxis(),
                        ],
                      ],
                    ),
                  ),
                  if (config.showDbScale) ...[
                    const SizedBox(width: AuraSpace.md),
                    const VisualizerDbScale(),
                  ],
                ],
              ),
            );
          } else {
            body = RepaintBoundary(
              child: CustomPaint(
                painter: painter,
                child: const SizedBox.expand(),
              ),
            );
          }

          if (_usesAmbience(config.style)) {
            body = Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: AtmospherePainter(
                        bands: renderedBands,
                        palette: palette,
                        animationTime: time,
                        intensity: 0.55 + config.bloom * 0.45,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                body,
              ],
            );
          }

          return body;
        },
      ),
    );
  }
}

/// 音频静音或停止时的待机占位视图
class VisualizerIdlePlaceholder extends StatelessWidget {
  final String emptyText;

  const VisualizerIdlePlaceholder({
    super.key,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_outlined, size: 40, color: p.textDim),
          const SizedBox(height: AuraSpace.md),
          Text(emptyText, style: captionOf(p)),
        ],
      ),
    );
  }
}
