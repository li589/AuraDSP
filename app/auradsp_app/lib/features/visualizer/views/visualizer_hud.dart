import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../models/visualizer_types.dart';
import '../plugins/milkdrop_preset.dart';
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
  final VoidCallback? onPickMilkdropFile;
  final VoidCallback? onPickMilkdropFolder;
  final List<MilkdropPreset>? milkdropPresets;
  final ValueChanged<MilkdropPreset>? onSelectMilkdropPreset;
  final bool isProjectMNativeActive;

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
    this.onPickMilkdropFile,
    this.onPickMilkdropFolder,
    this.milkdropPresets,
    this.onSelectMilkdropPreset,
    this.isProjectMNativeActive = false,
  });

  @override
  State<VisualizerHud> createState() => _VisualizerHudState();
}

class _VisualizerHudState extends State<VisualizerHud> {
  bool _menuOpen = false;
  int _categoryTab = 0;

  @override
  void didUpdateWidget(VisualizerHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当底栏自动隐退时，模式菜单同步自动收起
    if (!widget.visible && _menuOpen) {
      _menuOpen = false;
    }
  }

  void _toggleMenu() {
    setState(() {
      _menuOpen = !_menuOpen;
      if (_menuOpen) {
        _categoryTab = widget.config.style == VisualizerStyle.projectM ? 1 : 0;
      }
    });
  }

  void _closeMenu() {
    if (_menuOpen) setState(() => _menuOpen = false);
  }

  String? get _activeMilkdropPresetName {
    final path = widget.config.milkdropPresetPath;
    if (path != null && path.isNotEmpty) {
      return path.split(RegExp(r'[/\\]')).last.replaceAll('.milk', '');
    }
    if (widget.milkdropPresets != null && widget.milkdropPresets!.isNotEmpty) {
      return widget.milkdropPresets!.first.name;
    }
    return null;
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
                        child: _GlassSurface(
                          borderRadius: BorderRadius.circular(AuraRadius.md),
                          child: Container(
                            width: math.min(
                              270.0,
                              MediaQuery.sizeOf(context).width * 0.92,
                            ),
                            decoration: BoxDecoration(
                              color: p.panel.withValues(alpha: 0.96),
                              borderRadius: BorderRadius.circular(
                                AuraRadius.md,
                              ),
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
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 分类选择器选项卡 (Native vs MilkDrop)
                                Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    8,
                                    8,
                                    6,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(
                                        color: p.hairline.withValues(
                                          alpha: 0.6,
                                        ),
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: CategoryTabButton(
                                          title: l.visualizerCategoryNative,
                                          count: VisualizerStyle.values
                                              .where(
                                                (s) =>
                                                    s !=
                                                    VisualizerStyle.projectM,
                                              )
                                              .length,
                                          selected: _categoryTab == 0,
                                          onTap: () =>
                                              setState(() => _categoryTab = 0),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: CategoryTabButton(
                                          title: l.visualizerCategoryMilkdrop,
                                          count:
                                              widget.milkdropPresets?.length ??
                                              3,
                                          selected: _categoryTab == 1,
                                          onTap: () =>
                                              setState(() => _categoryTab = 1),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // 列表内容
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight:
                                        MediaQuery.sizeOf(context).height *
                                        0.44,
                                  ),
                                  child: _categoryTab == 0
                                      // Tab 0: 原生视效
                                      ? SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              for (final style
                                                  in VisualizerStyle.values)
                                                if (style !=
                                                    VisualizerStyle.projectM)
                                                  VisualizerMenuItem(
                                                    style: style,
                                                    isSelected:
                                                        widget.config.style ==
                                                        style,
                                                    onTap: () {
                                                      widget.onStyleChanged(
                                                        style,
                                                      );
                                                      _closeMenu();
                                                    },
                                                  ),
                                            ],
                                          ),
                                        )
                                      // Tab 1: MilkDrop 预设
                                      : Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // 诚实状态指示徽章 (Honesty badge)
                                            Container(
                                              margin: const EdgeInsets.fromLTRB(
                                                8,
                                                6,
                                                8,
                                                4,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                color:
                                                    (widget.isProjectMNativeActive
                                                            ? p.accent
                                                            : p.textDim)
                                                        .withValues(
                                                          alpha: 0.12,
                                                        ),
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      AuraRadius.xs,
                                                    ),
                                                border: Border.all(
                                                  color:
                                                      (widget.isProjectMNativeActive
                                                              ? p.accent
                                                              : p.hairline)
                                                          .withValues(
                                                            alpha: 0.4,
                                                          ),
                                                  width: 0.8,
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    widget.isProjectMNativeActive
                                                        ? Icons.bolt_rounded
                                                        : Icons
                                                              .info_outline_rounded,
                                                    size: 13,
                                                    color:
                                                        widget
                                                            .isProjectMNativeActive
                                                        ? p.accent
                                                        : p.textDim,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      widget.isProjectMNativeActive
                                                          ? l.visualizerEngineNativeActive
                                                          : l.visualizerEngineFallbackActive,
                                                      style: TextStyle(
                                                        fontSize: 10.5,
                                                        color:
                                                            widget
                                                                .isProjectMNativeActive
                                                            ? p.accent
                                                            : p.textDim,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),

                                            // 预设列表
                                            Flexible(
                                              child: SingleChildScrollView(
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    if (widget.milkdropPresets !=
                                                            null &&
                                                        widget
                                                            .milkdropPresets!
                                                            .isNotEmpty)
                                                      for (final preset
                                                          in widget
                                                              .milkdropPresets!)
                                                        MilkdropPresetMenuItem(
                                                          preset: preset,
                                                          isSelected:
                                                              widget
                                                                      .config
                                                                      .style ==
                                                                  VisualizerStyle
                                                                      .projectM &&
                                                              ((widget
                                                                          .config
                                                                          .milkdropPresetPath ==
                                                                      preset
                                                                          .filePath) ||
                                                                  (widget.config.milkdropPresetPath ==
                                                                          null &&
                                                                      preset ==
                                                                          widget
                                                                              .milkdropPresets!
                                                                              .first)),
                                                          onTap: () {
                                                            widget
                                                                .onSelectMilkdropPreset
                                                                ?.call(preset);
                                                            _closeMenu();
                                                          },
                                                        )
                                                    else
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              12,
                                                            ),
                                                        child: Text(
                                                          l.visualizerMilkdropPresetEmpty,
                                                          textAlign:
                                                              TextAlign.center,
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            color: p.textDim,
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),

                                            // 底部快速操作栏：打开预设 / 导入目录
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                border: Border(
                                                  top: BorderSide(
                                                    color: p.hairline
                                                        .withValues(alpha: 0.6),
                                                  ),
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: OutlinedButton.icon(
                                                      icon: const Icon(
                                                        Icons.file_open_rounded,
                                                        size: 13,
                                                      ),
                                                      label: Text(
                                                        l.visualizerPickMilkdropFile,
                                                        style: const TextStyle(
                                                          fontSize: 10.5,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      style: OutlinedButton.styleFrom(
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 4,
                                                              vertical: 6,
                                                            ),
                                                        foregroundColor: p.text,
                                                        side: BorderSide(
                                                          color: p.hairline,
                                                        ),
                                                      ),
                                                      onPressed: () {
                                                        _closeMenu();
                                                        widget
                                                            .onPickMilkdropFile
                                                            ?.call();
                                                      },
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: OutlinedButton.icon(
                                                      icon: const Icon(
                                                        Icons
                                                            .folder_open_rounded,
                                                        size: 13,
                                                      ),
                                                      label: Text(
                                                        l.visualizerPickMilkdropFolder,
                                                        style: const TextStyle(
                                                          fontSize: 10.5,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      style: OutlinedButton.styleFrom(
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 4,
                                                              vertical: 6,
                                                            ),
                                                        foregroundColor: p.text,
                                                        side: BorderSide(
                                                          color: p.hairline,
                                                        ),
                                                      ),
                                                      onPressed: () {
                                                        _closeMenu();
                                                        widget
                                                            .onPickMilkdropFolder
                                                            ?.call();
                                                      },
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('visualizer-style-menu-closed'),
                      ),
              ),

              // 主底栏容器（毛玻璃悬浮效果）
              _GlassSurface(
                borderRadius: BorderRadius.circular(AuraRadius.lg),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: p.panel.withValues(alpha: 0.86),
                    borderRadius: BorderRadius.circular(AuraRadius.lg),
                    border: Border.all(
                      color: p.hairline.withValues(alpha: 0.65),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.38),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  // P3：窄屏横排会溢出（360px 下约 479px 内容），改 Wrap 折行，
                  // 全部控件保持可见；桌面仍是单行 Row，观感不变。
                  child: Builder(
                    builder: (ctx) {
                      // mobile 档（<600）折行：整条 HUD 实宽约 480px，
                      // 只按 480 视口判断会低估浮层内边距后的可用宽度。
                      final compact = ctx.isMobile;
                      final sep = Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        height: 20,
                        width: 1,
                        color: p.hairline,
                      );
                      final items = <Widget>[
                        // 模式下拉激活按钮
                        VisualizerStyleDropdownButton(
                          selectedStyle: widget.config.style,
                          activeMilkdropPresetName: _activeMilkdropPresetName,
                          isOpen: _menuOpen,
                          onTap: _toggleMenu,
                        ),
                        if (widget.config.style == VisualizerStyle.projectM &&
                            widget.onPickMilkdropFile != null) ...[
                          if (!compact) const SizedBox(width: 4),
                          VisualizerActionButton(
                            icon: Icons.folder_open_rounded,
                            tooltip: l.visualizerPickMilkdropFile,
                            onTap: () {
                              _closeMenu();
                              widget.onPickMilkdropFile!();
                            },
                          ),
                        ],
                        if (!compact) sep,
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
                        if (!compact) const SizedBox(width: 4),
                        // 复位峰值
                        VisualizerActionButton(
                          icon: Icons.refresh_rounded,
                          tooltip: l.visualizerResetPeakTip,
                          onTap: () {
                            _closeMenu();
                            widget.onResetPeaks();
                          },
                        ),
                        if (!compact) const SizedBox(width: 4),
                        // 展开参数抽屉
                        VisualizerActionButton(
                          icon: Icons.tune_rounded,
                          tooltip: l.visualizerSettingsTip,
                          onTap: () {
                            _closeMenu();
                            widget.onOpenDrawer();
                          },
                        ),
                        if (!compact) sep,
                        // 三档全屏：还原 / 软件全屏 / 仅视效沉浸
                        VisualizerDisplayModeSwitcher(
                          mode: widget.displayMode,
                          onChanged: (mode) {
                            _closeMenu();
                            widget.onDisplayModeChanged(mode);
                          },
                        ),
                      ];
                      if (!compact) {
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: items,
                        );
                      }
                      return Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: items,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 平台自适应磨砂面板容器。
/// P0-3：全平台走无模糊路径。BackdropFilter 每次合成都要对整块背景做
/// sigma=12 的卷积并额外持有离屏纹理（本机实测 HUD 可见时 RSS +77 MB、
/// GPU 3D +16pp）；面板本身 alpha 0.94 已接近不透明，去掉模糊观感差异
/// 很小。Linux 原本就因 llvmpipe 开销走这条路径，此处统一。
class _GlassSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;
  const _GlassSurface({required this.borderRadius, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(borderRadius: borderRadius, child: child);
  }
}
