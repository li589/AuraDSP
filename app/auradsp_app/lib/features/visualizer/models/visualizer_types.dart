import 'package:flutter/material.dart';

/// 可视化展示风格
enum VisualizerStyle {
  /// 经典对数频段柱状谱 + 物理保持线
  bars(
    id: 'bars',
    label: 'Spectrum Bars',
    icon: Icons.bar_chart_rounded,
    description: 'IEC logarithmic multi-band spectrum with gravitational peak decay and bounce',
  ),

  /// 双通道实时示波器（波形与余辉衰减）
  oscilloscope(
    id: 'oscilloscope',
    label: 'Oscilloscope',
    icon: Icons.show_chart_rounded,
    description: 'Analog cathode-ray phosphor persistence tracking dynamic stereo time-domain waveforms',
  ),

  /// 利萨如图形与立体声相位仪 (Goniometer)
  goniometer(
    id: 'goniometer',
    label: 'Phase Scope',
    icon: Icons.radio_button_checked_rounded,
    description: 'Mid/Side 45-degree Lissajous phase pattern monitoring stereo width and phase correlation',
  ),

  /// 赛博朋克 3D 地形音频网格
  cyberGrid(
    id: 'cyberGrid',
    label: 'Cyber Grid',
    icon: Icons.grid_4x4_rounded,
    description: 'Perspective 3D terrain wireframe deforming to low-frequency impact and transients',
  ),

  /// 反应式音频光环与星云粒子
  pulseOrb(
    id: 'pulseOrb',
    label: 'Pulse Nebula',
    icon: Icons.lens_blur_rounded,
    description: 'Tri-band decomposed acoustic energy orb with surrounding orbital particle nebula',
  );

  final String id;
  final String label;
  final IconData icon;
  final String description;

  const VisualizerStyle({
    required this.id,
    required this.label,
    required this.icon,
    required this.description,
  });
}

/// 可视化色彩主题
enum VisualizerColorTheme {
  system(
    id: 'system',
    label: 'System Theme',
  ),
  neonCyber(
    id: 'neonCyber',
    label: 'Cyber Neon',
  ),
  amberTube(
    id: 'amberTube',
    label: 'Amber Tube',
  ),
  matrixGreen(
    id: 'matrixGreen',
    label: 'Matrix Phosphor',
  ),
  aurora(
    id: 'aurora',
    label: 'Aurora Glow',
  );

  final String id;
  final String label;

  const VisualizerColorTheme({
    required this.id,
    required this.label,
  });
}

/// 可视化综合参数配置状态
class VisualizerConfig {
  /// 当前激活的可视化风格
  final VisualizerStyle style;

  /// 配色主题
  final VisualizerColorTheme colorTheme;

  /// 动态灵敏度放大系数 (0.2 ~ 3.0，出厂 1.0)
  final double sensitivity;

  /// 下落阻尼/平滑度 (0.1 ~ 0.95，出厂 0.6)
  final double decayRate;

  /// 物理重力加速度 (0.5 ~ 4.0，出厂 1.8)
  final double gravity;

  /// 频段细分数量 (32 或 64)
  final int barCount;

  /// 辉光/余辉模糊度 (0.0 ~ 1.0)
  final double bloom;

  /// 是否显示网格背景
  final bool showGrid;

  /// 是否显示峰值保持线
  final bool showPeaks;

  /// 是否显示右侧 dBFS 刻度
  final bool showDbScale;

  /// 是否独占最大化舞台（隐去外层留白）
  final bool isMaximized;

  /// 是否开启实时歌词覆盖显示
  final bool showLyrics;

  /// 是否显示歌词双语翻译
  final bool showTranslation;

  const VisualizerConfig({
    this.style = VisualizerStyle.bars,
    this.colorTheme = VisualizerColorTheme.system,
    this.sensitivity = 1.0,
    this.decayRate = 0.6,
    this.gravity = 1.8,
    this.barCount = 32,
    this.bloom = 0.5,
    this.showGrid = true,
    this.showPeaks = true,
    this.showDbScale = true,
    this.isMaximized = false,
    this.showLyrics = false,
    this.showTranslation = true,
  });

  VisualizerConfig copyWith({
    VisualizerStyle? style,
    VisualizerColorTheme? colorTheme,
    double? sensitivity,
    double? decayRate,
    double? gravity,
    int? barCount,
    double? bloom,
    bool? showGrid,
    bool? showPeaks,
    bool? showDbScale,
    bool? isMaximized,
    bool? showLyrics,
    bool? showTranslation,
  }) {
    return VisualizerConfig(
      style: style ?? this.style,
      colorTheme: colorTheme ?? this.colorTheme,
      sensitivity: sensitivity ?? this.sensitivity,
      decayRate: decayRate ?? this.decayRate,
      gravity: gravity ?? this.gravity,
      barCount: barCount ?? this.barCount,
      bloom: bloom ?? this.bloom,
      showGrid: showGrid ?? this.showGrid,
      showPeaks: showPeaks ?? this.showPeaks,
      showDbScale: showDbScale ?? this.showDbScale,
      isMaximized: isMaximized ?? this.isMaximized,
      showLyrics: showLyrics ?? this.showLyrics,
      showTranslation: showTranslation ?? this.showTranslation,
    );
  }
}
