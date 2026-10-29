import 'package:flutter/material.dart';
import '../../../core/theme.dart';
import 'visualizer_types.dart';

/// 可视化专有配色方案解析与画笔生成
class VisualizerPalette {
  final Color primary;
  final Color secondary;
  final Color peak;
  final Color grid;
  final Color glow;
  final List<Color> gradient;

  const VisualizerPalette({
    required this.primary,
    required this.secondary,
    required this.peak,
    required this.grid,
    required this.glow,
    required this.gradient,
  });

  /// 根据全局主题与可视化专有配色生成调色板
  factory VisualizerPalette.resolve(
    VisualizerColorTheme theme,
    AuraPalette p,
  ) {
    switch (theme) {
      case VisualizerColorTheme.neonCyber:
        return const VisualizerPalette(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF007F),
          peak: Color(0xFFFFFFFF),
          grid: Color(0x1A00E5FF),
          glow: Color(0x8000E5FF),
          gradient: [
            Color(0xFF0055FF),
            Color(0xFF00E5FF),
            Color(0xFFFF00A0),
          ],
        );

      case VisualizerColorTheme.amberTube:
        return const VisualizerPalette(
          primary: Color(0xFFFF9500),
          secondary: Color(0xFFFF3B30),
          peak: Color(0xFFFFE57F),
          grid: Color(0x1AFF9500),
          glow: Color(0x66FF9500),
          gradient: [
            Color(0xFF8B2500),
            Color(0xFFFF7A00),
            Color(0xFFFFC043),
          ],
        );

      case VisualizerColorTheme.matrixGreen:
        return const VisualizerPalette(
          primary: Color(0xFF00FF66),
          secondary: Color(0xFF00CC44),
          peak: Color(0xFFD4FF00),
          grid: Color(0x1A00FF66),
          glow: Color(0x7300FF66),
          gradient: [
            Color(0xFF005522),
            Color(0xFF00CC44),
            Color(0xFF00FF88),
          ],
        );

      case VisualizerColorTheme.aurora:
        return const VisualizerPalette(
          primary: Color(0xFF7000FF),
          secondary: Color(0xFF00FFD1),
          peak: Color(0xFFF0F6FC),
          grid: Color(0x1A7000FF),
          glow: Color(0x6600FFD1),
          gradient: [
            Color(0xFF4A00E0),
            Color(0xFF8E2DE2),
            Color(0xFF00FFD1),
          ],
        );

      case VisualizerColorTheme.system:
        return VisualizerPalette(
          primary: p.vizSpectrum,
          secondary: p.accent,
          peak: p.text.withValues(alpha: 0.88),
          grid: p.vizGrid,
          glow: p.accent.withValues(alpha: 0.35),
          gradient: [
            p.vizSpectrum.withValues(alpha: 0.75),
            p.accent,
            p.accent.withValues(alpha: 0.9),
          ],
        );
    }
  }
}

