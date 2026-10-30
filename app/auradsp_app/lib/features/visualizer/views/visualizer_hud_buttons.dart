import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../models/visualizer_types.dart';

/// 模式下拉选择触发按钮
class VisualizerStyleDropdownButton extends StatelessWidget {
  final VisualizerStyle selectedStyle;
  final bool isOpen;
  final VoidCallback onTap;

  const VisualizerStyleDropdownButton({
    super.key,
    required this.selectedStyle,
    required this.isOpen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      child: AnimatedContainer(
        duration: AuraDur.fast,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isOpen
              ? p.accent.withValues(alpha: 0.18)
              : p.panelRaised.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(
            color: isOpen
                ? p.accent.withValues(alpha: 0.8)
                : p.hairline.withValues(alpha: 0.8),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selectedStyle.icon, size: 16, color: p.accent),
            const SizedBox(width: 8),
            Text(
              selectedStyle.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              isOpen
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: p.textDim,
            ),
          ],
        ),
      ),
    );
  }
}

/// 模式菜单项
class VisualizerMenuItem extends StatelessWidget {
  final VisualizerStyle style;
  final bool isSelected;
  final VoidCallback onTap;

  const VisualizerMenuItem({
    super.key,
    required this.style,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? p.accent.withValues(alpha: 0.16)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(
              style.icon,
              size: 15,
              color: isSelected ? p.accent : p.textDim,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                style.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? p.accent : p.text,
                ),
              ),
            ),
            if (isSelected)
              Icon(Icons.check_rounded, size: 15, color: p.accent),
          ],
        ),
      ),
    );
  }
}

/// 三档全屏分段控件：还原 / 软件全屏 / 仅视效沉浸
class VisualizerDisplayModeSwitcher extends StatelessWidget {
  final VisualizerDisplayMode mode;
  final ValueChanged<VisualizerDisplayMode> onChanged;

  const VisualizerDisplayModeSwitcher({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline.withValues(alpha: 0.7), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DisplayModeSegment(
            icon: VisualizerDisplayMode.restore.icon,
            tooltip: l.visualizerDisplayRestoreTip,
            selected: mode == VisualizerDisplayMode.restore,
            onTap: () => onChanged(VisualizerDisplayMode.restore),
          ),
          _DisplayModeSegment(
            icon: VisualizerDisplayMode.stage.icon,
            tooltip: l.visualizerDisplayStageTip,
            selected: mode == VisualizerDisplayMode.stage,
            onTap: () => onChanged(VisualizerDisplayMode.stage),
          ),
          _DisplayModeSegment(
            icon: VisualizerDisplayMode.immersive.icon,
            tooltip: l.visualizerDisplayImmersiveTip,
            selected: mode == VisualizerDisplayMode.immersive,
            onTap: () => onChanged(VisualizerDisplayMode.immersive),
          ),
        ],
      ),
    );
  }
}

class _DisplayModeSegment extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  const _DisplayModeSegment({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        mouseCursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: AuraDur.fast,
          curve: AuraCurve.standard,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? p.accent.withValues(alpha: 0.22)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AuraRadius.xs),
            border: Border.all(
              color: selected ? p.accent : Colors.transparent,
              width: 1,
            ),
          ),
          child: Icon(icon, size: 16, color: selected ? p.accent : p.textDim),
        ),
      ),
    );
  }
}

/// HUD 通用动作图标按钮
class VisualizerActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const VisualizerActionButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.active = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: active
                ? p.accent.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: active
                ? Border.all(color: p.accent.withValues(alpha: 0.4), width: 1)
                : null,
          ),
          child: Icon(icon, size: 18, color: active ? p.accent : p.textDim),
        ),
      ),
    );
  }
}
