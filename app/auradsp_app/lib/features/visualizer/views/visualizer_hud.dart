import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../models/visualizer_types.dart';

/// 视效舞台悬浮控制岛 (Floating HUD Dock)
class VisualizerHud extends StatelessWidget {
  final VisualizerConfig config;
  final bool visible;
  final bool isSystemFullscreen;
  final ValueChanged<VisualizerStyle> onStyleChanged;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleSystemFullscreen;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenDrawer;
  final VoidCallback onResetPeaks;

  const VisualizerHud({
    super.key,
    required this.config,
    required this.visible,
    this.isSystemFullscreen = false,
    required this.onStyleChanged,
    required this.onToggleFullscreen,
    required this.onToggleSystemFullscreen,
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: p.panel.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(AuraRadius.lg),
            border: Border.all(color: p.hairline.withValues(alpha: 0.6), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 模式下拉选择器（精简横向空间）
              _StyleDropdownSelector(
                selectedStyle: config.style,
                onSelected: onStyleChanged,
              ),

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
              const SizedBox(width: 6),

              // 系统真全屏按钮（置于复位峰值右侧、高级选项左侧，带独立强调视觉）
              _SystemFullscreenButton(
                isSystemFullscreen: isSystemFullscreen,
                onTap: onToggleSystemFullscreen,
              ),
              const SizedBox(width: 6),

              // 展开参数抽屉
              _ActionButton(
                icon: Icons.tune_rounded,
                tooltip: 'Visualizer Settings',
                onTap: onOpenDrawer,
              ),
              const SizedBox(width: 4),

              // 软件内舞台最大化切换
              _ActionButton(
                icon: config.isMaximized
                    ? Icons.close_fullscreen_rounded
                    : Icons.open_in_full_rounded,
                tooltip: config.isMaximized ? 'Exit Stage Maximize' : 'Maximize Stage',
                onTap: onToggleFullscreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StyleDropdownSelector extends StatelessWidget {
  final VisualizerStyle selectedStyle;
  final ValueChanged<VisualizerStyle> onSelected;

  const _StyleDropdownSelector({
    required this.selectedStyle,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return PopupMenuButton<VisualizerStyle>(
      tooltip: 'Select Visualizer Style',
      initialValue: selectedStyle,
      color: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AuraRadius.md),
        side: BorderSide(color: p.hairline),
      ),
      offset: const Offset(0, -360),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final style in VisualizerStyle.values)
          PopupMenuItem<VisualizerStyle>(
            value: style,
            height: 38,
            child: Row(
              children: [
                Icon(
                  style.icon,
                  size: 16,
                  color: selectedStyle == style ? p.accent : p.textDim,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    style.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selectedStyle == style
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: selectedStyle == style ? p.accent : p.text,
                    ),
                  ),
                ),
                if (selectedStyle == style)
                  Icon(Icons.check_rounded, size: 16, color: p.accent),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: p.panelRaised.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(color: p.hairline.withValues(alpha: 0.8), width: 1),
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
            Icon(Icons.unfold_more_rounded, size: 14, color: p.textDim),
          ],
        ),
      ),
    );
  }
}

class _SystemFullscreenButton extends StatelessWidget {
  final bool isSystemFullscreen;
  final VoidCallback onTap;

  const _SystemFullscreenButton({
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
