import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/ui_helpers.dart';
import '../models/visualizer_types.dart';
import 'visualizer_drawer.dart';

/// 颜色主题选择标签组
class VisualizerThemeChips extends StatelessWidget {
  final VisualizerColorTheme selectedTheme;
  final ValueChanged<VisualizerColorTheme> onSelected;

  const VisualizerThemeChips({
    super.key,
    required this.selectedTheme,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final theme in VisualizerColorTheme.values)
          ChoiceChip(
            label: Text(theme.labelOf(l)),
            selected: selectedTheme == theme,
            visualDensity: VisualDensity.compact,
            showCheckmark: false,
            labelStyle: TextStyle(
              fontSize: 12,
              color: selectedTheme == theme ? p.accent : p.textDim,
              fontWeight: selectedTheme == theme
                  ? FontWeight.w600
                  : FontWeight.normal,
            ),
            side: BorderSide(
              color: selectedTheme == theme
                  ? p.accent.withValues(alpha: 0.55)
                  : p.hairline,
              width: 1,
            ),
            onSelected: (val) {
              if (val) onSelected(theme);
            },
          ),
      ],
    );
  }
}

/// 抽屉分节标题（带信息徽标）
class VisualizerDrawerSectionTitle extends StatelessWidget {
  final String title;
  final String info;

  const VisualizerDrawerSectionTitle({
    super.key,
    required this.title,
    required this.info,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Row(
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: p.textDim,
              letterSpacing: 0.6,
            ),
          ),
        ),
        const SizedBox(width: 6),
        InfoBadge(message: info),
      ],
    );
  }
}

/// 抽屉开关选项行
class VisualizerDrawerToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final String info;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const VisualizerDrawerToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.info,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelOf(
                      p,
                      color: enabled ? p.text : p.textDim,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InfoBadge(message: info),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

/// 浮动参数抽屉全屏覆盖层（带平滑动效与背景遮罩）
class VisualizerDrawerOverlay extends StatelessWidget {
  final bool open;
  final VisualizerConfig config;
  final ValueChanged<VisualizerConfig> onConfigChanged;
  final VoidCallback onClose;
  final VoidCallback onResetToDefaults;

  const VisualizerDrawerOverlay({
    super.key,
    required this.open,
    required this.config,
    required this.onConfigChanged,
    required this.onClose,
    required this.onResetToDefaults,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedSwitcher(
        duration: AuraDur.base,
        switchInCurve: AuraCurve.emphasized,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: open
            ? Stack(
                key: const ValueKey('visualizer-drawer'),
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: onClose,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: VisualizerConfigDrawer(
                      config: config,
                      onConfigChanged: onConfigChanged,
                      onClose: onClose,
                      onResetToDefaults: onResetToDefaults,
                    ),
                  ),
                ],
              )
            : const SizedBox.shrink(
                key: ValueKey('visualizer-drawer-closed'),
              ),
      ),
    );
  }
}
