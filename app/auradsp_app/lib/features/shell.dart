/*
 * shell.dart — 应用骨架：左栏导航 + 常驻状态顶栏 + 内容区
 *
 * 层级约定（自上而下三档）：
 *   左栏 = 导航（品牌 / 路由 / 本地装置信息）
 *   顶栏 = 常驻状态（引擎形态 + 三态徽标 + 延迟 + 配色快切），跨页不消失
 *   内容 = 页面（PageScaffold 统一留白）
 *
 * 页面切换走 AnimatedSwitcher（淡入 + 微位移），不再是无过渡地硬切。
 */
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'effects_page.dart';
import 'home_page.dart';
import 'liveprog_page.dart';
import 'settings_page.dart';
import 'visualizer_page.dart';
import 'widgets.dart';

class AppShell extends StatefulWidget {
  final AppModel model;
  const AppShell({super.key, required this.model});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _railCollapsed = false;

  static const _destinations = <({IconData icon, IconData active})>[
    (icon: Icons.home_outlined, active: Icons.home),
    (icon: Icons.tune_outlined, active: Icons.tune),
    (icon: Icons.code_rounded, active: Icons.code),
    (icon: Icons.bar_chart_outlined, active: Icons.bar_chart),
    (icon: Icons.settings_outlined, active: Icons.settings),
  ];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final m = widget.model;
    final l = l10nOf(context);
    final labels = [l.navHome, l.navEffects, l.navLiveprog, l.navVisualizer, l.navSettings];
    final eyebrows = [
      l.pageHomeEyebrow,
      l.pageEffectsEyebrow,
      l.pageLiveprogEyebrow,
      l.pageVisualizerEyebrow,
      l.pageSettingsEyebrow,
    ];

    final pages = [
      HomePage(model: m),
      EffectsPage(model: m),
      LiveprogPage(model: m),
      VisualizerPage(model: m),
      SettingsPage(model: m),
    ];

    return Scaffold(
      body: Row(
        children: [
          _Rail(
            labels: labels,
            destinations: _destinations,
            index: _index,
            onSelect: (i) => setState(() => _index = i),
            model: m,
            collapsed: _railCollapsed,
            onToggle: () => setState(() => _railCollapsed = !_railCollapsed),
          ),
          Container(width: 1, color: p.hairline),
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  eyebrow: eyebrows[_index],
                  model: m,
                  onCycleTheme: _cycleTheme,
                ),
                Container(height: 1, color: p.hairline),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AuraDur.page,
                    switchInCurve: AuraCurve.emphasized,
                    switchOutCurve: AuraCurve.emphasized,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.018),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    layoutBuilder: (current, previous) => Stack(
                      fit: StackFit.expand,
                      children: [
                        ...previous,
                        ?current,
                      ],
                    ),
                    child: KeyedSubtree(
                      key: ValueKey<int>(_index),
                      child: pages[_index],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _cycleTheme() {
    final all = AuraThemeId.values;
    final next = all[(widget.model.themeId.index + 1) % all.length];
    widget.model.setTheme(next);
  }
}

/* ==================== 左栏 ==================== */

class _Rail extends StatelessWidget {
  final List<String> labels;
  final List<({IconData icon, IconData active})> destinations;
  final int index;
  final ValueChanged<int> onSelect;
  final AppModel model;
  final bool collapsed;
  final VoidCallback onToggle;

  const _Rail({
    required this.labels,
    required this.destinations,
    required this.index,
    required this.onSelect,
    required this.model,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return AnimatedContainer(
      duration: AuraDur.base,
      curve: AuraCurve.emphasized,
      width: collapsed ? AuraSize.railMinW : AuraSize.railW,
      child: Column(
        crossAxisAlignment: collapsed
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          // 品牌（收起时只留几何标记 + 展开按钮）
          Padding(
            padding: EdgeInsets.fromLTRB(collapsed ? AuraSpace.sm : AuraSpace.lg,
                AuraSpace.xl + AuraSpace.xs, collapsed ? AuraSpace.sm : AuraSpace.lg, 0),
            child: collapsed
                ? Column(
                    children: [
                      _BrandMark(p: p),
                      const SizedBox(height: AuraSpace.sm),
                      _RailToggle(collapsed: true, onTap: onToggle),
                    ],
                  )
                : Row(
                    children: [
                      _BrandMark(p: p),
                      const SizedBox(width: AuraSpace.sm + 2),
                      Text('AuraDSP',
                          style: TextStyle(
                            fontFamily: 'AuraDisplay',
                            fontFamilyFallback: kDisplayCjkFallback,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                            color: p.text,
                          )),
                      const Spacer(),
                      _RailToggle(collapsed: false, onTap: onToggle),
                    ],
                  ),
          ),
          const SizedBox(height: AuraSpace.xl),
          // 导航
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: collapsed ? AuraSpace.sm : AuraSpace.lg),
            child: Column(
              children: [
                for (var i = 0; i < destinations.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                        bottom: i == destinations.length - 1 ? 0 : AuraSpace.xs),
                    child: _NavItem(
                      icon: destinations[i].icon,
                      activeIcon: destinations[i].active,
                      label: labels[i],
                      selected: index == i,
                      onTap: () => onSelect(i),
                      collapsed: collapsed,
                    ),
                  ),
              ],
            ),
          ),
          const Spacer(),
          // 底部装置信息（收起时隐藏）
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AuraSpace.lg, 0, AuraSpace.lg, AuraSpace.xl),
              child: ListenableBuilder(
                listenable: model,
                builder: (_, _) {
                  final info = model.info;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(height: 1, color: p.hairline),
                      const SizedBox(height: AuraSpace.md),
                      Text('ENGINES · DESKTOP',
                          style: monoOf(p, size: 10, color: p.textDim)),
                      const SizedBox(height: AuraSpace.xs + 2),
                      Text(
                        info == null
                            ? l.engineForm
                            : 'ABI v${info.abi} · ${info.deviceRate}Hz',
                        style: monoOf(p, size: 10,
                            color: p.textDim.withValues(alpha: 0.75)),
                      ),
                    ],
                  );
                },
              ),
            )
          else
            const SizedBox(height: AuraSpace.xl),
        ],
      ),
    );
  }
}

/// 同心方块几何标记（呼应 "aura" 的环）
class _BrandMark extends StatelessWidget {
  final AuraPalette p;
  const _BrandMark({required this.p});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: p.accent,
        borderRadius: BorderRadius.circular(AuraRadius.xs),
      ),
      child: Center(
        child: Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: p.bg,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
      ),
    );
  }
}

/// 左栏收起/展开按钮：实体化（浮层面板底 + hairline 边 + 常亮箭头），
/// 保证在 rail 空白背景上"看得见、知道能点"。28×32，hover 提亮 + accent 描边。
class _RailToggle extends StatefulWidget {
  final bool collapsed;
  final VoidCallback onTap;
  const _RailToggle({required this.collapsed, required this.onTap});

  @override
  State<_RailToggle> createState() => _RailToggleState();
}

class _RailToggleState extends State<_RailToggle> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Tooltip(
      message: widget.collapsed ? l10nOf(context).railExpandTip : l10nOf(context).railCollapseTip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            duration: AuraDur.instant,
            scale: _down ? 0.92 : 1.0,
            child: AnimatedContainer(
              duration: AuraDur.fast,
              width: 28,
              height: 32,
              decoration: BoxDecoration(
                // 收起态按钮悬浮在 rail 空白上，用浮层面板色 + 边框做出"实体感"
                color: _hover ? hoverOn(p, alpha: 0.10) : p.panelRaised,
                borderRadius: BorderRadius.circular(AuraRadius.sm),
                border: Border.all(
                  color: _hover ? p.accent.withValues(alpha: 0.6) : p.hairline,
                  width: 1,
                ),
              ),
              child: Icon(
                widget.collapsed
                    ? Icons.chevron_right_rounded
                    : Icons.chevron_left_rounded,
                size: 20,
                color: _hover ? p.accent : p.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool collapsed;
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final fg = widget.selected ? p.accent : (_hover ? p.text : p.textDim);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AuraDur.fast,
          curve: AuraCurve.standard,
          height: AuraSize.navItemH,
          decoration: BoxDecoration(
            color: widget.selected
                ? p.accent.withValues(alpha: 0.10)
                : (_hover ? hoverOn(p, alpha: 0.045) : Colors.transparent),
            borderRadius: BorderRadius.circular(AuraRadius.sm),
          ),
          child: widget.collapsed
              ? Center(
                  child: Icon(
                      widget.selected ? widget.activeIcon : widget.icon,
                      size: AuraSize.navIcon,
                      color: fg),
                )
              : Row(
                  children: [
                    // 选中指示条（伸缩动画）
                    AnimatedContainer(
                      duration: AuraDur.base,
                      curve: AuraCurve.emphasized,
                      width: 3,
                      height: widget.selected ? 18 : 0,
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: AuraSpace.md - 1),
                    Icon(widget.selected ? widget.activeIcon : widget.icon,
                        size: AuraSize.navIcon, color: fg),
                    const SizedBox(width: AuraSpace.md - 2),
                    Expanded(
                      child: AnimatedDefaultTextStyle(
                        duration: AuraDur.fast,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              widget.selected ? FontWeight.w600 : FontWeight.w500,
                          color: fg,
                        ),
                        child: Text(widget.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: AuraSpace.sm),
                  ],
                ),
        ),
      ),
    );
  }
}

/* ==================== 顶栏（常驻状态） ==================== */

class _TopBar extends StatelessWidget {
  final String eyebrow;
  final AppModel model;
  final VoidCallback onCycleTheme;
  const _TopBar({
    required this.eyebrow,
    required this.model,
    required this.onCycleTheme,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SizedBox(
      height: AuraSize.topBarH,
      child: Center(
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AuraSpace.contentMaxW),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AuraSpace.pageX),
            child: Row(
              children: [
                Text(eyebrow, style: eyebrowOf(p)),
                const SizedBox(width: AuraSpace.lg),
                Container(width: 1, height: 14, color: p.hairline),
                const SizedBox(width: AuraSpace.lg),
                // 引擎形态摘要（安静的一行等宽小字）
                ListenableBuilder(
                  listenable: model,
                  builder: (_, _) {
                    final info = model.info;
                    final text = info == null
                        ? l.engineForm
                        : '${l.engineForm} · ${info.deviceRate}Hz · ${info.deviceCh}ch';
                    return Expanded(
                      child: Text(text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoOf(p, size: 11, color: p.textDim)),
                    );
                  },
                ),
                const SizedBox(width: AuraSpace.lg),
                ListenableBuilder(
                  listenable: model,
                  builder: (_, _) => Row(
                    children: [
                      StateBadge(
                          engineState: model.engineState, playing: model.playing),
                      const SizedBox(width: AuraSpace.sm),
                      LatencyBadge(ms: model.latencyMs),
                      const SizedBox(width: AuraSpace.sm),
                      _IconAction(
                        icon: Icons.palette_outlined,
                        tooltip: l.themeSwitchTip,
                        onTap: onCycleTheme,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 32×32 的图标动作按钮：hover 有底、按下有缩放
class _IconAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          // opaque：32×32 整块可命中——透明底色（未 hover）时也必须能点
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            duration: AuraDur.instant,
            scale: _down ? 0.92 : 1.0,
            child: AnimatedContainer(
              duration: AuraDur.fast,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _hover ? hoverOn(p, alpha: 0.07) : Colors.transparent,
                borderRadius: BorderRadius.circular(AuraRadius.sm),
              ),
              child: Icon(widget.icon,
                  size: 18, color: _hover ? p.text : p.textDim),
            ),
          ),
        ),
      ),
    );
  }
}

/* ==================== 事件条 ==================== */

/// 引擎事件 → SnackBar（guard 拒绝 / 运行时错误）
class EventBanner extends StatelessWidget {
  final AppModel model;
  const EventBanner({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: model.eventSeq,
      builder: (ctx, seq, _) {
        if (seq == 0) return const SizedBox.shrink();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final messenger = ScaffoldMessenger.maybeOf(context);
          if (messenger == null) return;
          final p = paletteOf(context);
          final guard = model.lastGuard;
          final err = model.lastEngineError;
          final info = model.lastInfo;
          final text = guard != null
              ? guard.message
              : (err ?? info ?? '');
          if (text.isEmpty) return;
          final isError = guard == null && err != null;
          final isInfo = guard == null && err == null;
          final tint = isError
              ? p.error
              : (isInfo ? p.accent : p.warning);
          messenger.showSnackBar(SnackBar(
            showCloseIcon: true,
            closeIconColor: p.textDim,
            content: Row(
              children: [
                Icon(
                    isError
                        ? Icons.error_outline
                        : (isInfo ? Icons.info_outline : Icons.report_outlined),
                    size: 18,
                    color: tint),
                const SizedBox(width: AuraSpace.md),
                Expanded(
                  child: Text(text,
                      style: TextStyle(color: p.text, fontSize: 13, height: 1.45)),
                ),
              ],
            ),
            duration: const Duration(seconds: 4),
          ));
        });
        return const SizedBox.shrink();
      },
    );
  }
}
