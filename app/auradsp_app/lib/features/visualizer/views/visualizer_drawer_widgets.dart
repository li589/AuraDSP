import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
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
            // 对比度修复（2026-10-31）：主题 chip 选中态底色是全局
            // ChipTheme.selectedColor = accent，旧实现又把文字设成 accent，
            // 结果 accent on accent 完全看不清（所有配色主题都如此）。
            // 选中 → accentContrast 实底文字；未选中 → 正文色（非 textDim）。
            labelStyle: TextStyle(
              fontSize: 12,
              color: selectedTheme == theme ? p.accentContrast : p.text,
              fontWeight: selectedTheme == theme
                  ? FontWeight.w600
                  : FontWeight.w500,
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
          // 开关尺寸（2026-10-31）：默认 Switch 在紧凑抽屉里偏大，统一
          // 缩放 0.86 并收紧点击区，与 13pt 标签的视觉比重匹配。
          Transform.scale(
            scale: 0.86,
            alignment: Alignment.centerRight,
            child: Switch.adaptive(
              value: value,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 在线歌词来源选择（R6，2026-10-31）：自动 / LrcLib / 网易云 / QQ / 酷狗
class VisualizerLyricsSourcePicker extends StatelessWidget {
  final LyricsSource value;
  final ValueChanged<LyricsSource> onChanged;

  const VisualizerLyricsSourcePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                l.visualizerLyricsSource,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelOf(p, color: p.text),
              ),
            ),
            const SizedBox(width: 6),
            InfoBadge(message: l.visualizerLyricsSourceInfo),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: p.panelRaised,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: p.hairline),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<LyricsSource>(
              value: value,
              isExpanded: true,
              isDense: true,
              borderRadius: BorderRadius.circular(AuraRadius.sm),
              dropdownColor: p.panelRaised,
              icon: Icon(Icons.expand_more_rounded, size: 18, color: p.textDim),
              style: TextStyle(fontSize: 12.5, color: p.text),
              items: [
                for (final source in LyricsSource.values)
                  DropdownMenuItem<LyricsSource>(
                    value: source,
                    child: Text(
                      source.labelOf(l),
                      style: TextStyle(fontSize: 12.5, color: p.text),
                    ),
                  ),
              ],
              onChanged: (next) {
                if (next != null && next != value) onChanged(next);
              },
            ),
          ),
        ),
      ],
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
