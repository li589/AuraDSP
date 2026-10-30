import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../models/visualizer_types.dart';
import 'visualizer_hud_buttons.dart';

/// 视效舞台悬浮控制岛 (Floating HUD Dock)
class VisualizerHud extends StatefulWidget {
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
  State<VisualizerHud> createState() => _VisualizerHudState();
}

class _VisualizerHudState extends State<VisualizerHud> {
  bool _menuOpen = false;

  @override
  void didUpdateWidget(VisualizerHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当底栏自动隐退时，模式菜单同步自动收起
    if (!widget.visible && _menuOpen) {
      _menuOpen = false;
    }
  }

  void _toggleMenu() {
    setState(() => _menuOpen = !_menuOpen);
  }

  void _closeMenu() {
    if (_menuOpen) setState(() => _menuOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return AnimatedOpacity(
      opacity: widget.visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 模式选择浮动菜单（直接锚定在底栏左侧上方 6px，绝对对齐下拉按钮，跟随底栏自动消失）
            if (_menuOpen) ...[
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Container(
                  width: 175,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: p.panel.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(AuraRadius.md),
                    border: Border.all(color: p.hairline.withValues(alpha: 0.85), width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final style in VisualizerStyle.values)
                        VisualizerMenuItem(
                          style: style,
                          isSelected: widget.config.style == style,
                          onTap: () {
                            widget.onStyleChanged(style);
                            _closeMenu();
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],

            // 主底栏容器
            Container(
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
                  // 模式下拉激活按钮
                  VisualizerStyleDropdownButton(
                    selectedStyle: widget.config.style,
                    isOpen: _menuOpen,
                    onTap: _toggleMenu,
                  ),

                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    height: 20,
                    width: 1,
                    color: p.hairline,
                  ),

                  // 歌词显示开关
                  VisualizerActionButton(
                    icon: Icons.lyrics_rounded,
                    tooltip: widget.config.showLyrics ? 'Hide Lyrics' : 'Show Lyrics',
                    active: widget.config.showLyrics,
                    onTap: () {
                      _closeMenu();
                      widget.onToggleLyrics();
                    },
                  ),
                  const SizedBox(width: 4),

                  // 复位峰值
                  VisualizerActionButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Reset Peak Hold',
                    onTap: () {
                      _closeMenu();
                      widget.onResetPeaks();
                    },
                  ),
                  const SizedBox(width: 6),

                  // 系统真全屏按钮（置于复位峰值右侧、高级选项左侧，带独立强调视觉）
                  VisualizerSystemFullscreenButton(
                    isSystemFullscreen: widget.isSystemFullscreen,
                    onTap: () {
                      _closeMenu();
                      widget.onToggleSystemFullscreen();
                    },
                  ),
                  const SizedBox(width: 6),

                  // 展开参数抽屉
                  VisualizerActionButton(
                    icon: Icons.tune_rounded,
                    tooltip: 'Visualizer Settings',
                    onTap: () {
                      _closeMenu();
                      widget.onOpenDrawer();
                    },
                  ),
                  const SizedBox(width: 4),

                  // 软件内舞台最大化切换
                  VisualizerActionButton(
                    icon: widget.config.isMaximized
                        ? Icons.close_fullscreen_rounded
                        : Icons.open_in_full_rounded,
                    tooltip: widget.config.isMaximized ? 'Exit Stage Maximize' : 'Maximize Stage',
                    onTap: () {
                      _closeMenu();
                      widget.onToggleFullscreen();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
