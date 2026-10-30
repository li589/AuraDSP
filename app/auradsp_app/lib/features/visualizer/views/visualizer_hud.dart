import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../models/visualizer_types.dart';
import 'visualizer_hud_buttons.dart';

/// 视效舞台悬浮控制岛 (Floating HUD Dock)
class VisualizerHud extends StatefulWidget {
  final VisualizerConfig config;
  final VisualizerDisplayMode displayMode;
  final bool visible;
  final ValueChanged<VisualizerStyle> onStyleChanged;
  final ValueChanged<VisualizerDisplayMode> onDisplayModeChanged;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenDrawer;
  final VoidCallback onResetPeaks;

  const VisualizerHud({
    super.key,
    required this.config,
    this.displayMode = VisualizerDisplayMode.restore,
    required this.visible,
    required this.onStyleChanged,
    required this.onDisplayModeChanged,
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
    final l = l10nOf(context);

    return AnimatedSlide(
      offset: widget.visible ? Offset.zero : const Offset(0, 0.18),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 模式选择浮动菜单（直接居中锚定在底栏上方，随底栏自动收放）
              AnimatedSwitcher(
                duration: AuraDur.fast,
                switchInCurve: AuraCurve.emphasized,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: _menuOpen
                    ? Padding(
                        key: const ValueKey('visualizer-style-menu'),
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          width: 175,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: p.panel.withValues(alpha: 0.96),
                            borderRadius: BorderRadius.circular(AuraRadius.md),
                            border: Border.all(
                              color: p.hairline.withValues(alpha: 0.85),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: ConstrainedBox(
                            // 小屏（手机横屏/窄窗）时风格列表可滚动，避免溢出裁切
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.sizeOf(context).height * 0.45,
                            ),
                            child: SingleChildScrollView(
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
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('visualizer-style-menu-closed'),
                      ),
              ),

              // 主底栏容器
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: p.panel.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(AuraRadius.lg),
                  border: Border.all(
                    color: p.hairline.withValues(alpha: 0.6),
                    width: 1,
                  ),
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
                      tooltip: widget.config.showLyrics
                          ? l.visualizerHideLyricsTip
                          : l.visualizerShowLyricsTip,
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
                      tooltip: l.visualizerResetPeakTip,
                      onTap: () {
                        _closeMenu();
                        widget.onResetPeaks();
                      },
                    ),
                    const SizedBox(width: 4),

                    // 展开参数抽屉
                    VisualizerActionButton(
                      icon: Icons.tune_rounded,
                      tooltip: l.visualizerSettingsTip,
                      onTap: () {
                        _closeMenu();
                        widget.onOpenDrawer();
                      },
                    ),

                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      height: 20,
                      width: 1,
                      color: p.hairline,
                    ),

                    // 三档全屏：还原 / 软件全屏 / 仅视效沉浸
                    VisualizerDisplayModeSwitcher(
                      mode: widget.displayMode,
                      onChanged: (mode) {
                        _closeMenu();
                        widget.onDisplayModeChanged(mode);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
