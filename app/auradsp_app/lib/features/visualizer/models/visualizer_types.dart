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
  ),

  /// GPU 硬件加速极光流体着色器 (FragmentProgram)
  auroraShader(
    id: 'auroraShader',
    label: 'Aurora Ribbon',
    icon: Icons.waves_rounded,
    description: 'GPU fragment shader generating waving northern lights ribbons',
  ),

  /// GPU 硬件加速霓虹穿梭隧道着色器 (FragmentProgram)
  tunnelShader(
    id: 'tunnelShader',
    label: 'Neon Tunnel',
    icon: Icons.filter_tilt_shift_rounded,
    description: 'GPU fragment shader rendering infinite audio-reactive warp tunnel',
  ),

  /// Winamp MilkDrop 2 / projectM 外部视效引擎
  milkDrop(
    id: 'milkDrop',
    label: 'MilkDrop',
    icon: Icons.album_rounded,
    description: 'Winamp MilkDrop 2 procedural music visualizer engine',
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

/// 可视化显示档位（单一状态机，替代「舞台最大化 + OS 全屏」双布尔）
enum VisualizerDisplayMode {
  /// 还原：标准页面布局（页头 + 舞台 + 电平表 + 应用外框）
  restore(
    id: 'restore',
    icon: Icons.close_fullscreen_rounded,
  ),

  /// 软件全屏：舞台铺满应用窗口，隐藏页头与电平表，窗口本身不变
  stage(
    id: 'stage',
    icon: Icons.open_in_full_rounded,
  ),

  /// 仅视效全屏：舞台铺满窗口并隐藏应用导航/顶栏，桌面端同时进入 OS 全屏
  immersive(
    id: 'immersive',
    icon: Icons.fullscreen_rounded,
  );

  final String id;
  final IconData icon;

  const VisualizerDisplayMode({
    required this.id,
    required this.icon,
  });

  /// 舞台是否脱离标准工作区（软件全屏与沉浸档均为铺满）。
  bool get isExpanded => this != VisualizerDisplayMode.restore;
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

  /// 线条粗细/光束粗细 (0.8 ~ 3.5px，出厂 1.5px)
  final double lineWidth;

  /// 辉光/余辉模糊度 (0.0 ~ 1.0)
  final double bloom;

  /// 是否显示网格背景
  final bool showGrid;

  /// 是否显示峰值保持线
  final bool showPeaks;

  /// 是否显示右侧 dBFS 刻度
  final bool showDbScale;

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
    this.lineWidth = 1.5,
    this.bloom = 0.5,
    this.showGrid = true,
    this.showPeaks = true,
    this.showDbScale = true,
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
    double? lineWidth,
    double? bloom,
    bool? showGrid,
    bool? showPeaks,
    bool? showDbScale,
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
      lineWidth: lineWidth ?? this.lineWidth,
      bloom: bloom ?? this.bloom,
      showGrid: showGrid ?? this.showGrid,
      showPeaks: showPeaks ?? this.showPeaks,
      showDbScale: showDbScale ?? this.showDbScale,
      showLyrics: showLyrics ?? this.showLyrics,
      showTranslation: showTranslation ?? this.showTranslation,
    );
  }
}
