import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../models/visualizer_types.dart';

/// 视效舞台悬浮控制岛 (Floating HUD Dock)
class VisualizerHud extends StatelessWidget {
  final VisualizerConfig config;
  final bool visible;
  final ValueChanged<VisualizerStyle> onStyleChanged;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenDrawer;
  final VoidCallback onResetPeaks;

  const VisualizerHud({
    super.key,
    required this.config,
    required this.visible,
    required this.onStyleChanged,
    required this.onToggleFullscreen,
    required this.onToggleLyrics,
    required this.onOpenDrawer,
    required this.onResetPeaks,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: IgnorePointer(
        ignoring: !visible,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: p.panel.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(AuraRadius.lg),
            border: Border.all(color: p.hairline.withValues(alpha: 0.5), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 模式快速切换按钮组
              for (final style in VisualizerStyle.values) ...[
                _StyleButton(
                  style: style,
                  isSelected: config.style == style,
                  onTap: () => onStyleChanged(style),
                ),
                const SizedBox(width: 4),
              ],
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                height: 20,
                width: 1,
                color: p.hairline,
              ),

              // 歌词显示开关
              _ActionButton(
                icon: Icons.lyrics_rounded,
                tooltip: config.showLyrics ? 'Hide Lyrics' : 'Show Lyrics',
                active: config.showLyrics,
                onTap: onToggleLyrics,
              ),
              const SizedBox(width: 4),

              // 复位峰值
              _ActionButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Reset Peak Hold',
                onTap: onResetPeaks,
              ),
              const SizedBox(width: 4),

              // 展开参数抽屉
              _ActionButton(
                icon: Icons.tune_rounded,
                tooltip: 'Visualizer Settings',
                onTap: onOpenDrawer,
              ),
              const SizedBox(width: 4),

              // 全屏切换
              _ActionButton(
                icon: config.isMaximized
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                tooltip: config.isMaximized ? 'Exit Stage' : 'Immersive Stage (F11)',
                onTap: onToggleFullscreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StyleButton extends StatelessWidget {
  final VisualizerStyle style;
  final bool isSelected;
  final VoidCallback onTap;

  const _StyleButton({
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
      child: AnimatedContainer(
        duration: AuraDur.fast,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? p.accent.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(
            color: isSelected ? p.accent.withValues(alpha: 0.6) : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              style.icon,
              size: 16,
              color: isSelected ? p.accent : p.textDim,
            ),
            const SizedBox(width: 6),
            Text(
              style.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? p.text : p.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _ActionButton({
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
