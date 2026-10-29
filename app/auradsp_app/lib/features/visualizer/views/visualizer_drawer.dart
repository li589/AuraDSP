import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/ui_helpers.dart';
import '../../effects_page.dart' show ValueSlider;
import '../models/visualizer_types.dart';

/// 可视化高级参数调节侧边抽屉面板
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

    return Container(
      width: 320,
      color: p.panel,
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
                    'Visualizer Settings',
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
                  tooltip: 'Close',
                  onPressed: onClose,
                ),
              ],
            ),
          ),

          // 参数列表
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                // 1. 色彩主题选择
                _SectionTitle(
                  title: 'COLOR PALETTE',
                  info: 'Select spectrum and waveform color theme',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final theme in VisualizerColorTheme.values)
                      ChoiceChip(
                        label: Text(theme.label),
                        selected: config.colorTheme == theme,
                        onSelected: (val) {
                          if (val) {
                            onConfigChanged(config.copyWith(colorTheme: theme));
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 20),

                // 2. 核心动态调节
                _SectionTitle(
                  title: 'DYNAMICS & DAMPING',
                  info: 'Configure audio energy response sensitivity and decay physics',
                ),
                const SizedBox(height: 6),
                ValueSlider(
                  label: 'Sensitivity',
                  value: config.sensitivity,
                  defaultValue: 1.0,
                  onResetToDefault: () =>
                      onConfigChanged(config.copyWith(sensitivity: 1.0)),
                  min: 0.2,
                  max: 3.0,
                  unit: 'x',
                  format: (v) => v.toStringAsFixed(1),
                  infoMessage: 'Audio energy scaling multiplier for visual bounce',
                  onChanged: (v) => onConfigChanged(config.copyWith(sensitivity: v)),
                  onChangedEnd: (v) => onConfigChanged(config.copyWith(sensitivity: v)),
                ),
                const SizedBox(height: 8),
                ValueSlider(
                  label: 'Falloff Decay',
                  value: config.decayRate,
                  defaultValue: 0.6,
                  onResetToDefault: () =>
                      onConfigChanged(config.copyWith(decayRate: 0.6)),
                  min: 0.1,
                  max: 0.95,
                  format: (v) => (v * 100).toStringAsFixed(0),
                  unit: '%',
                  infoMessage: 'Air damping resistance for peak and spectrum decay',
                  onChanged: (v) => onConfigChanged(config.copyWith(decayRate: v)),
                  onChangedEnd: (v) => onConfigChanged(config.copyWith(decayRate: v)),
                ),
                const SizedBox(height: 8),
                ValueSlider(
                  label: 'Gravity',
                  value: config.gravity,
                  defaultValue: 1.8,
                  onResetToDefault: () =>
                      onConfigChanged(config.copyWith(gravity: 1.8)),
                  min: 0.5,
                  max: 4.0,
                  unit: 'G',
                  format: (v) => v.toStringAsFixed(1),
                  infoMessage: 'Gravitational acceleration pulling peak meters downward',
                  onChanged: (v) => onConfigChanged(config.copyWith(gravity: v)),
                  onChangedEnd: (v) => onConfigChanged(config.copyWith(gravity: v)),
                ),
                const SizedBox(height: 20),

                // 3. 画面细节与辉光
                _SectionTitle(
                  title: 'VISUALS & GUIDES',
                  info: 'Fine-tune phosphor bloom, grid lines, and scales',
                ),
                const SizedBox(height: 6),
                ValueSlider(
                  label: 'Phosphor Bloom',
                  value: config.bloom,
                  defaultValue: 0.5,
                  onResetToDefault: () =>
                      onConfigChanged(config.copyWith(bloom: 0.5)),
                  min: 0.0,
                  max: 1.0,
                  format: (v) => (v * 100).toStringAsFixed(0),
                  unit: '%',
                  infoMessage: 'Cathode-ray persistence and LED glow intensity',
                  onChanged: (v) => onConfigChanged(config.copyWith(bloom: v)),
                  onChangedEnd: (v) => onConfigChanged(config.copyWith(bloom: v)),
                ),
                const SizedBox(height: 12),

                // 频段分度选择
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text('Bands Density', style: labelOf(p, color: p.text)),
                        const SizedBox(width: 6),
                        const InfoBadge(message: 'Select 32 or 64 frequency resolution bands'),
                      ],
                    ),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 32, label: Text('32')),
                        ButtonSegment(value: 64, label: Text('64')),
                      ],
                      selected: {config.barCount},
                      onSelectionChanged: (val) {
                        onConfigChanged(config.copyWith(barCount: val.first));
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 辅助线开关
                _ToggleRow(
                  label: 'Reference Grid',
                  value: config.showGrid,
                  info: 'Display 100Hz, 1kHz, 10kHz octave and horizontal dB lines',
                  onChanged: (v) => onConfigChanged(config.copyWith(showGrid: v)),
                ),
                _ToggleRow(
                  label: 'Peak Hold Lines',
                  value: config.showPeaks,
                  info: 'Retain physical gravity bounce lines on top of spectrum bars',
                  onChanged: (v) => onConfigChanged(config.copyWith(showPeaks: v)),
                ),
                _ToggleRow(
                  label: 'dBFS Vertical Scale',
                  value: config.showDbScale,
                  info: 'Show 0 to -60 dBFS acoustic scale along right border',
                  onChanged: (v) => onConfigChanged(config.copyWith(showDbScale: v)),
                ),
                const SizedBox(height: 12),

                // 4. 歌词与字幕选项
                _SectionTitle(
                  title: 'LYRICS & SUBTITLES',
                  info: 'Configure synchronized scrolling lyrics display',
                ),
                const SizedBox(height: 6),
                _ToggleRow(
                  label: 'Lyrics Overlay',
                  value: config.showLyrics,
                  info: 'Overlay synchronized lyrics above the visualizer stage',
                  onChanged: (v) => onConfigChanged(config.copyWith(showLyrics: v)),
                ),
                _ToggleRow(
                  label: 'Bilingual Translation',
                  value: config.showTranslation,
                  info: 'Display translated lyrics beneath primary line if available',
                  onChanged: (v) => onConfigChanged(config.copyWith(showTranslation: v)),
                ),
              ],
            ),
          ),

          // 抽屉底栏：出厂复位
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: p.hairline, width: 1)),
            ),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restore_rounded, size: 16),
              label: const Text('Reset Defaults'),
              onPressed: onResetToDefaults,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String info;

  const _SectionTitle({required this.title, required this.info});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: p.textDim,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(width: 6),
        InfoBadge(message: info),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final String info;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    required this.value,
    required this.info,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Text(label, style: labelOf(p, color: p.text)),
              const SizedBox(width: 6),
              InfoBadge(message: info),
            ],
          ),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
