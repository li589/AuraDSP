import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
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
          color: isOpen ? p.accent.withValues(alpha: 0.18) : p.panelRaised.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(
            color: isOpen ? p.accent.withValues(alpha: 0.8) : p.hairline.withValues(alpha: 0.8),
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
              isOpen ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
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
          color: isSelected ? p.accent.withValues(alpha: 0.16) : Colors.transparent,
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

/// 系统窗口真全屏按钮
class VisualizerSystemFullscreenButton extends StatelessWidget {
  final bool isSystemFullscreen;
  final VoidCallback onTap;

  const VisualizerSystemFullscreenButton({
    super.key,
    required this.isSystemFullscreen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Tooltip(
      message: isSystemFullscreen
          ? 'Exit OS Fullscreen (Esc / F11)'
          : 'System Fullscreen (OS Window)',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        child: AnimatedContainer(
          duration: AuraDur.fast,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: isSystemFullscreen
                ? p.accent.withValues(alpha: 0.28)
                : p.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(
              color: isSystemFullscreen
                  ? p.accent
                  : p.accent.withValues(alpha: 0.45),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSystemFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.aspect_ratio_rounded,
                size: 17,
                color: p.accent,
              ),
              const SizedBox(width: 4),
              Text(
                'OS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: p.accent,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
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
            color: active ? p.accent.withValues(alpha: 0.16) : Colors.transparent,
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
