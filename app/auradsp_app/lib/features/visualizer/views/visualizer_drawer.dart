import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../../effects_page.dart' show ValueSlider;
import '../models/visualizer_types.dart';
import 'visualizer_drawer_widgets.dart';

/// 可视化高级参数调节侧边抽屉面板
///
/// 所有文案经 l10n（zh/en/ja），布局随窗口宽度自适应，底栏出厂复位按钮水平居中。
class VisualizerConfigDrawer extends StatelessWidget {
  final VisualizerConfig config;
  final ValueChanged<VisualizerConfig> onConfigChanged;
  final VoidCallback onClose;
  final VoidCallback onResetToDefaults;

  const VisualizerConfigDrawer({
    super.key,
    required this.config,
    required this.onConfigChanged,
    required this.onClose,
    required this.onResetToDefaults,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    // 桌面保持 320 逻辑像素；窄屏按 90% 宽度收缩，避免手机端溢出
    final drawerWidth = math.min(320.0, MediaQuery.sizeOf(context).width * 0.9);

    return Container(
      width: drawerWidth,
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: const BorderRadius.horizontal(
          left: Radius.circular(AuraRadius.lg),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(-8, 0),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抽屉顶栏
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.hairline, width: 1)),
              ),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, size: 18, color: p.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.visualizerDrawerTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: p.textDim,
                    visualDensity: VisualDensity.compact,
                    tooltip: l.visualizerDrawerCloseTip,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),

            // 参数列表
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                children: [
                  // 1. 色彩主题选择
                  VisualizerDrawerSectionTitle(
                    title: l.visualizerSectionPalette,
                    info: l.visualizerSectionPaletteInfo,
                  ),
                  const SizedBox(height: 8),
                  VisualizerThemeChips(
                    selectedTheme: config.colorTheme,
                    onSelected: (theme) =>
                        onConfigChanged(config.copyWith(colorTheme: theme)),
                  ),
                  const SizedBox(height: 20),

                  // 2. 核心动态调节
                  VisualizerDrawerSectionTitle(
                    title: l.visualizerSectionDynamics,
                    info: l.visualizerSectionDynamicsInfo,
                  ),
                  const SizedBox(height: 6),
                  ValueSlider(
                    label: l.visualizerSensitivity,
                    value: config.sensitivity,
                    defaultValue: 1.0,
                    onResetToDefault: () =>
                        onConfigChanged(config.copyWith(sensitivity: 1.0)),
                    min: 0.2,
                    max: 3.0,
                    unit: 'x',
                    format: (v) => v.toStringAsFixed(1),
                    infoMessage: l.visualizerSensitivityInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(sensitivity: v)),
                    onChangedEnd: (v) =>
                        onConfigChanged(config.copyWith(sensitivity: v)),
                  ),
                  const SizedBox(height: 8),
                  ValueSlider(
                    label: l.visualizerDecay,
                    value: config.decayRate,
                    defaultValue: 0.6,
                    onResetToDefault: () =>
                        onConfigChanged(config.copyWith(decayRate: 0.6)),
                    min: 0.1,
                    max: 0.95,
                    format: (v) => (v * 100).toStringAsFixed(0),
                    unit: '%',
                    infoMessage: l.visualizerDecayInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(decayRate: v)),
                    onChangedEnd: (v) =>
                        onConfigChanged(config.copyWith(decayRate: v)),
                  ),
                  const SizedBox(height: 8),
                  ValueSlider(
                    label: l.visualizerGravity,
                    value: config.gravity,
                    defaultValue: 1.8,
                    onResetToDefault: () =>
                        onConfigChanged(config.copyWith(gravity: 1.8)),
                    min: 0.5,
                    max: 4.0,
                    unit: 'G',
                    format: (v) => v.toStringAsFixed(1),
                    infoMessage: l.visualizerGravityInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(gravity: v)),
                    onChangedEnd: (v) =>
                        onConfigChanged(config.copyWith(gravity: v)),
                  ),
                  const SizedBox(height: 20),

                  // 3. 画面细节与辉光
                  VisualizerDrawerSectionTitle(
                    title: l.visualizerSectionVisuals,
                    info: l.visualizerSectionVisualsInfo,
                  ),
                  const SizedBox(height: 6),
                  ValueSlider(
                    label: l.visualizerBloom,
                    value: config.bloom,
                    defaultValue: 0.5,
                    onResetToDefault: () =>
                        onConfigChanged(config.copyWith(bloom: 0.5)),
                    min: 0.0,
                    max: 1.0,
                    format: (v) => (v * 100).toStringAsFixed(0),
                    unit: '%',
                    infoMessage: l.visualizerBloomInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(bloom: v)),
                    onChangedEnd: (v) =>
                        onConfigChanged(config.copyWith(bloom: v)),
                  ),
                  const SizedBox(height: 8),
                  ValueSlider(
                    label: l.visualizerLineWidth,
                    value: config.lineWidth,
                    defaultValue: 1.5,
                    onResetToDefault: () =>
                        onConfigChanged(config.copyWith(lineWidth: 1.5)),
                    min: 0.8,
                    max: 3.5,
                    format: (v) => v.toStringAsFixed(1),
                    unit: 'px',
                    infoMessage: l.visualizerLineWidthInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(lineWidth: v)),
                    onChangedEnd: (v) =>
                        onConfigChanged(config.copyWith(lineWidth: v)),
                  ),
                  const SizedBox(height: 12),

                  // 频段分度选择
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                l.visualizerBandsDensity,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: labelOf(p, color: p.text),
                              ),
                            ),
                            const SizedBox(width: 6),
                            InfoBadge(message: l.visualizerBandsDensityInfo),
                          ],
                        ),
                      ),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 32, label: Text('32')),
                          ButtonSegment(value: 64, label: Text('64')),
                        ],
                        selected: {config.barCount},
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onSelectionChanged: (val) {
                          onConfigChanged(config.copyWith(barCount: val.first));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 辅助线开关
                  VisualizerDrawerToggleRow(
                    label: l.visualizerToggleGrid,
                    value: config.showGrid,
                    info: l.visualizerToggleGridInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(showGrid: v)),
                  ),
                  VisualizerDrawerToggleRow(
                    label: l.visualizerTogglePeaks,
                    value: config.showPeaks,
                    info: l.visualizerTogglePeaksInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(showPeaks: v)),
                  ),
                  VisualizerDrawerToggleRow(
                    label: l.visualizerToggleDbScale,
                    value: config.showDbScale,
                    info: l.visualizerToggleDbScaleInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(showDbScale: v)),
                  ),
                  const SizedBox(height: 12),

                  // 4. 歌词与字幕选项
                  VisualizerDrawerSectionTitle(
                    title: l.visualizerSectionLyrics,
                    info: l.visualizerSectionLyricsInfo,
                  ),
                  const SizedBox(height: 6),
                  VisualizerDrawerToggleRow(
                    label: l.visualizerToggleLyrics,
                    value: config.showLyrics,
                    info: l.visualizerToggleLyricsInfo,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(showLyrics: v)),
                  ),
                  VisualizerDrawerToggleRow(
                    label: l.visualizerToggleTranslation,
                    value: config.showTranslation,
                    info: l.visualizerToggleTranslationInfo,
                    // 依赖歌词叠加，未开启歌词时置灰，避免无意义的空开关
                    enabled: config.showLyrics,
                    onChanged: (v) =>
                        onConfigChanged(config.copyWith(showTranslation: v)),
                  ),
                  const SizedBox(height: 10),
                  // R6（2026-10-31）：在线歌词来源可选（默认自动依次回退）
                  VisualizerLyricsSourcePicker(
                    value: config.lyricsSource,
                    onChanged: (source) => onConfigChanged(
                      config.copyWith(lyricsSource: source),
                    ),
                  ),
                ],
              ),
            ),

            // 抽屉底栏：出厂复位（水平居中）
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.hairline, width: 1)),
              ),
              child: Align(
                alignment: Alignment.center,
                child: Tooltip(
                  message: l.visualizerResetDefaultsTip,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.restore_rounded, size: 16),
                    label: Text(l.visualizerResetDefaults),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      foregroundColor: p.textDim,
                      side: BorderSide(color: p.hairline, width: 1),
                    ),
                    onPressed: onResetToDefaults,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
