/*
 * visualizer_types.dart — 可视化配置模型（core 层唯一真相源）
 *
 * 2026-10-31 迁移：原 `features/visualizer/models/visualizer_types.dart` 升格到
 * core 层——可视化配置需要作为 AppModel 状态参与「预设系统 + 会话记忆」，
 * 而分层铁律（layering_guard_test）禁止 core/ 依赖 features/。
 * 旧路径保留为薄 export 壳，特性侧 import 无需改动。
 */
import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

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

  /// 极坐标谐波射线 (原错名 MilkDrop，现更名为 Harmonic Warp 消除与 projectM 引擎歧义)
  harmonicWarp(
    id: 'harmonicWarp',
    label: 'Harmonic Warp',
    icon: Icons.album_rounded,
    description: 'Polar spectrum harmonic rays and pulsing radial wave warp',
  ),

  /// 流体动力学：频谱驱动的二维不可压流场（Stable Fluids）
  fluidDynamics(
    id: 'fluidDynamics',
    label: 'Fluid Dynamics',
    icon: Icons.water_rounded,
    description:
        'Real-time 2D incompressible fluid simulation with spectral force injection',
  ),

  /// 粒子龙卷风：螺旋上升的确定性粒子风暴
  tornado(
    id: 'tornado',
    label: 'Particle Tornado',
    icon: Icons.cyclone_rounded,
    description: 'Coherent particle funnel vortex with depth-sorted orbiting dust',
  ),

  /// 星云：经典深空柔雾星云与漂移尘埃（多层流场漂移 + 恒星光芒）
  nebulaFlow(
    id: 'nebulaFlow',
    label: 'Nebula',
    icon: Icons.cloud_rounded,
    description: 'Deep cosmic nebula with drifting interstellar dust clouds and pulsating stellar fields',
  ),

  /// Winamp MilkDrop 2 / projectM 外部脚本视效引擎 (支持 .milk 预设脚本)
  projectM(
    id: 'projectM',
    label: 'MilkDrop (projectM)',
    icon: Icons.auto_awesome_motion_rounded,
    description: 'Winamp MilkDrop procedural script visualizer engine via libprojectM',
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

  /// 按持久化 id 解析（未知 id 回落到 bars）。
  ///
  /// 兼容旧 id：`mirrorWeave`（已下线的镜像织带）静默升级为星云流，
  /// 保证用户已保存的配置 / 预设 / 会话记忆仍可读回。
  static VisualizerStyle fromId(String? id) {
    if (id == 'mirrorWeave') return VisualizerStyle.nebulaFlow;
    if (id == 'milkDrop') return VisualizerStyle.harmonicWarp;
    return VisualizerStyle.values
        .firstWhere((e) => e.id == id, orElse: () => VisualizerStyle.bars);
  }
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
  ),
  emeraldMist(
    id: 'emeraldMist',
    label: 'Emerald Mist',
  );

  final String id;
  final String label;

  const VisualizerColorTheme({
    required this.id,
    required this.label,
  });

  static VisualizerColorTheme fromId(String? id) =>
      VisualizerColorTheme.values.firstWhere(
        (e) => e.id == id,
        orElse: () => VisualizerColorTheme.system,
      );
}

/// 在线歌词来源（R6，2026-10-31）：多个后端可切换，auto 为默认（依次回退）
enum LyricsSource {
  auto(
    id: 'auto',
    label: 'Auto (fallback chain)',
  ),
  lrclib(
    id: 'lrclib',
    label: 'LrcLib',
  ),
  netease(
    id: 'netease',
    label: 'NetEase Cloud Music',
  ),
  qq(
    id: 'qq',
    label: 'QQ Music',
  ),
  kugou(
    id: 'kugou',
    label: 'Kugou Music',
  );

  final String id;
  final String label;

  const LyricsSource({required this.id, required this.label});

  static LyricsSource fromId(String? id) => LyricsSource.values.firstWhere(
        (e) => e.id == id,
        orElse: () => LyricsSource.auto,
      );

  /// auto 模式的尝试顺序（国际源优先，国内源兜底）。
  static const List<LyricsSource> autoOrder = [
    LyricsSource.lrclib,
    LyricsSource.netease,
    LyricsSource.qq,
    LyricsSource.kugou,
  ];
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

  /// 在线歌词来源（R6）
  final LyricsSource lyricsSource;

  /// MilkDrop 脚本预设路径（.milk 文件路径，或 null 为内置预设）
  final String? milkdropPresetPath;

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
    this.lyricsSource = LyricsSource.auto,
    this.milkdropPresetPath,
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
    LyricsSource? lyricsSource,
    String? milkdropPresetPath,
    bool clearMilkdropPresetPath = false,
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
      lyricsSource: lyricsSource ?? this.lyricsSource,
      milkdropPresetPath: clearMilkdropPresetPath
          ? null
          : (milkdropPresetPath ?? this.milkdropPresetPath),
    );
  }

  /// 持久化（config.json / session_state.json / 预设 section）。
  Map<String, dynamic> toJson() => {
        'style': style.id,
        'colorTheme': colorTheme.id,
        'sensitivity': sensitivity,
        'decayRate': decayRate,
        'gravity': gravity,
        'barCount': barCount,
        'lineWidth': lineWidth,
        'bloom': bloom,
        'showGrid': showGrid,
        'showPeaks': showPeaks,
        'showDbScale': showDbScale,
        'showLyrics': showLyrics,
        'showTranslation': showTranslation,
        'lyricsSource': lyricsSource.id,
        'milkdropPresetPath': milkdropPresetPath,
      };

  /// 容错读取：坏值逐项回落出厂值，不因单键脏数据丢整份配置。
  factory VisualizerConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return const VisualizerConfig();
    double d(String key, double def, double lo, double hi) {
      final v = json[key];
      if (v is num && v.isFinite) return v.toDouble().clamp(lo, hi);
      return def;
    }

    bool b(String key, bool def) => json[key] is bool ? json[key] as bool : def;

    /// 类型安全取字符串：脏配置里非 String 值不得触发 TypeError
    /// （否则 ConfigManager.load 的 catch 会把整份配置覆盖成默认值）。
    String? s(String key) {
      final v = json[key];
      return v is String ? v : null;
    }

    final barCount = (json['barCount'] is num)
        ? (json['barCount'] as num).toInt()
        : 32;
    return VisualizerConfig(
      style: VisualizerStyle.fromId(s('style')),
      colorTheme: VisualizerColorTheme.fromId(s('colorTheme')),
      sensitivity: d('sensitivity', 1.0, 0.2, 3.0),
      decayRate: d('decayRate', 0.6, 0.1, 0.95),
      gravity: d('gravity', 1.8, 0.5, 4.0),
      barCount: (barCount == 64) ? 64 : 32,
      lineWidth: d('lineWidth', 1.5, 0.8, 3.5),
      bloom: d('bloom', 0.5, 0.0, 1.0),
      showGrid: b('showGrid', true),
      showPeaks: b('showPeaks', true),
      showDbScale: b('showDbScale', true),
      showLyrics: b('showLyrics', false),
      showTranslation: b('showTranslation', true),
      lyricsSource: LyricsSource.fromId(s('lyricsSource')),
      milkdropPresetPath: s('milkdropPresetPath'),
    );
  }

  /// 值相等：setVisualizerConfig 的「无变化不写盘」守卫依赖它。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VisualizerConfig &&
        other.style == style &&
        other.colorTheme == colorTheme &&
        other.sensitivity == sensitivity &&
        other.decayRate == decayRate &&
        other.gravity == gravity &&
        other.barCount == barCount &&
        other.lineWidth == lineWidth &&
        other.bloom == bloom &&
        other.showGrid == showGrid &&
        other.showPeaks == showPeaks &&
        other.showDbScale == showDbScale &&
        other.showLyrics == showLyrics &&
        other.showTranslation == showTranslation &&
        other.lyricsSource == lyricsSource &&
        other.milkdropPresetPath == milkdropPresetPath;
  }

  @override
  int get hashCode => Object.hash(
        style,
        colorTheme,
        sensitivity,
        decayRate,
        gravity,
        barCount,
        lineWidth,
        bloom,
        showGrid,
        showPeaks,
        showDbScale,
        showLyrics,
        showTranslation,
        lyricsSource,
        milkdropPresetPath,
      );
}

/// 每风格稀疏覆盖（2026-11-23 r64 裁定；2026-11-24 审查 Dart-F2
/// 落地）：只记与全局不同的调参字段，null = 跟随全局。此前覆盖表
/// 存整份生效快照——首次在预设档改任一滑块，该风格全部调参字段
/// 即被冻结，之后全局改动对该风格静默失效、预设值也被挡住。
/// 旧档整份 JSON 经 fromJson 读入时，在场调参字段一律视为覆盖
/// （加载时生效行为不变），下次写入即收敛为稀疏形态。
class VisualizerStyleOverride {
  final VisualizerColorTheme? colorTheme;
  final double? sensitivity;
  final double? decayRate;
  final double? gravity;
  final int? barCount;
  final double? lineWidth;
  final double? bloom;
  final bool? showGrid;
  final bool? showPeaks;
  final bool? showDbScale;

  const VisualizerStyleOverride({
    this.colorTheme,
    this.sensitivity,
    this.decayRate,
    this.gravity,
    this.barCount,
    this.lineWidth,
    this.bloom,
    this.showGrid,
    this.showPeaks,
    this.showDbScale,
  });

  bool get isEmpty =>
      colorTheme == null &&
      sensitivity == null &&
      decayRate == null &&
      gravity == null &&
      barCount == null &&
      lineWidth == null &&
      bloom == null &&
      showGrid == null &&
      showPeaks == null &&
      showDbScale == null;

  /// 写入端收敛：与当前全局逐字段 diff，只保留不同字段。
  factory VisualizerStyleOverride.diff(
      VisualizerConfig tuned, VisualizerConfig global) {
    return VisualizerStyleOverride(
      colorTheme: tuned.colorTheme != global.colorTheme ? tuned.colorTheme : null,
      sensitivity: tuned.sensitivity != global.sensitivity ? tuned.sensitivity : null,
      decayRate: tuned.decayRate != global.decayRate ? tuned.decayRate : null,
      gravity: tuned.gravity != global.gravity ? tuned.gravity : null,
      barCount: tuned.barCount != global.barCount ? tuned.barCount : null,
      lineWidth: tuned.lineWidth != global.lineWidth ? tuned.lineWidth : null,
      bloom: tuned.bloom != global.bloom ? tuned.bloom : null,
      showGrid: tuned.showGrid != global.showGrid ? tuned.showGrid : null,
      showPeaks: tuned.showPeaks != global.showPeaks ? tuned.showPeaks : null,
      showDbScale: tuned.showDbScale != global.showDbScale ? tuned.showDbScale : null,
    );
  }

  /// 合并端：非 null 字段替换全局，null 回落全局（copyWith 的
  /// ?? 语义恰好实现回落）。
  VisualizerConfig applyTo(VisualizerConfig global) {
    return global.copyWith(
      colorTheme: colorTheme,
      sensitivity: sensitivity,
      decayRate: decayRate,
      gravity: gravity,
      barCount: barCount,
      lineWidth: lineWidth,
      bloom: bloom,
      showGrid: showGrid,
      showPeaks: showPeaks,
      showDbScale: showDbScale,
    );
  }

  /// 只写非 null 字段（稀疏落盘）。
  Map<String, dynamic> toJson() => {
        if (colorTheme != null) 'colorTheme': colorTheme!.id,
        if (sensitivity != null) 'sensitivity': sensitivity,
        if (decayRate != null) 'decayRate': decayRate,
        if (gravity != null) 'gravity': gravity,
        if (barCount != null) 'barCount': barCount,
        if (lineWidth != null) 'lineWidth': lineWidth,
        if (bloom != null) 'bloom': bloom,
        if (showGrid != null) 'showGrid': showGrid,
        if (showPeaks != null) 'showPeaks': showPeaks,
        if (showDbScale != null) 'showDbScale': showDbScale,
      };

  /// 容错读取（与 VisualizerConfig.fromJson 同钳位口径）：在场且
  /// 合法的调参字段才记为覆盖，其余（含全局域键）忽略。
  factory VisualizerStyleOverride.fromJson(Map<String, dynamic> json) {
    double? d(String key, double lo, double hi) {
      final v = json[key];
      if (v is num && v.isFinite) return v.toDouble().clamp(lo, hi);
      return null;
    }

    bool? b(String key) => json[key] is bool ? json[key] as bool : null;
    final bc = json['barCount'];
    return VisualizerStyleOverride(
      colorTheme: json['colorTheme'] is String
          ? VisualizerColorTheme.fromId(json['colorTheme'] as String)
          : null,
      sensitivity: d('sensitivity', 0.2, 3.0),
      decayRate: d('decayRate', 0.1, 0.95),
      gravity: d('gravity', 0.5, 4.0),
      barCount: bc is num ? ((bc.toInt() == 64) ? 64 : 32) : null,
      lineWidth: d('lineWidth', 0.8, 3.5),
      bloom: d('bloom', 0.0, 1.0),
      showGrid: b('showGrid'),
      showPeaks: b('showPeaks'),
      showDbScale: b('showDbScale'),
    );
  }
}

/// 风格与配色的多语言显示名（枚举内 label 仅作英文兜底）
extension VisualizerStyleL10n on VisualizerStyle {
  String labelOf(AppLocalizations l) => switch (this) {
        VisualizerStyle.bars => l.visualizerStyleBars,
        VisualizerStyle.oscilloscope => l.visualizerStyleOscilloscope,
        VisualizerStyle.goniometer => l.visualizerStyleGoniometer,
        VisualizerStyle.cyberGrid => l.visualizerStyleCyberGrid,
        VisualizerStyle.pulseOrb => l.visualizerStylePulseOrb,
        VisualizerStyle.auroraShader => l.visualizerStyleAurora,
        VisualizerStyle.tunnelShader => l.visualizerStyleTunnel,
        VisualizerStyle.harmonicWarp => l.visualizerStyleHarmonicWarp,
        VisualizerStyle.fluidDynamics => l.visualizerStyleFluid,
        VisualizerStyle.tornado => l.visualizerStyleTornado,
        VisualizerStyle.nebulaFlow => l.visualizerStyleNebulaFlow,
        VisualizerStyle.projectM => l.visualizerStyleProjectM,
      };
}

extension VisualizerColorThemeL10n on VisualizerColorTheme {
  String labelOf(AppLocalizations l) => switch (this) {
        VisualizerColorTheme.system => l.visualizerThemeSystem,
        VisualizerColorTheme.neonCyber => l.visualizerThemeNeonCyber,
        VisualizerColorTheme.amberTube => l.visualizerThemeAmberTube,
        VisualizerColorTheme.matrixGreen => l.visualizerThemeMatrixGreen,
        VisualizerColorTheme.aurora => l.visualizerThemeAuroraGlow,
        VisualizerColorTheme.emeraldMist => l.visualizerThemeEmeraldMist,
      };
}

extension LyricsSourceL10n on LyricsSource {
  String labelOf(AppLocalizations l) => switch (this) {
        LyricsSource.auto => l.visualizerLyricsSourceAuto,
        LyricsSource.lrclib => l.visualizerLyricsSourceLrclib,
        LyricsSource.netease => l.visualizerLyricsSourceNetease,
        LyricsSource.qq => l.visualizerLyricsSourceQq,
        LyricsSource.kugou => l.visualizerLyricsSourceKugou,
      };
}
