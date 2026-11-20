/*
 * shell.dart — 应用骨架：左栏导航 + 常驻状态顶栏 + 内容区
 *
 * 层级约定（自上而下三档）：
 *   左栏 = 导航（品牌 / 路由 / 本地装置信息）
 *   顶栏 = 常驻状态（引擎形态 + 三态徽标 + 延迟 + 配色快切），跨页不消失
 *   内容 = 页面（PageScaffold 统一留白）
 *
 * 页面切换走 IndexedStack（P0-1，2026-10-23：原 AnimatedSwitcher 会销毁
 * 非当前页——切页全量重建 + initState 重跑；保活后切页零重建、状态保留，
 * 离屏代价由 hbTick 级联 + visiblePage 定时器门控 + TickerMode 抵消）。
 */
import 'package:flutter/material.dart';

import '../core/debug/debug_trace.dart';
import '../core/design.dart';
import '../core/nav.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import '../platform/platform_profile.dart';
import '../ui/aura_dialog.dart';
import 'chain_page.dart';
import 'effects_page.dart';
import 'home_page.dart';
import 'liveprog_page.dart';
import 'plugins_page.dart';
import 'settings_page.dart';
import 'visualizer_page.dart';
import 'widgets.dart';

/// 底栏高度（内容区下留位与底栏自身共用同一常量，避免两处漂移）。
const double _kBottomNavH = 60.0;

class AppShell extends StatefulWidget {
  final AppModel model;
  const AppShell({super.key, required this.model});

  @override
  State<AppShell> createState() => _AppShellState();
}

/// 页面级平滑过渡组件：为 IndexedStack 子项赋予淡入淡出与微小位移
class _PageTransitionChild extends StatelessWidget {
  final bool active;
  final Widget child;

  const _PageTransitionChild({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: active ? Offset.zero : const Offset(0, 0.012),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: active ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    );
  }
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _railCollapsed = false;

  // 页面实例缓存（P0-1）：IndexedStack 保活——切页复用既有 State
  // （保滚动/折叠态、避免 initState 重跑），也避免 build 每帧构造页面对象。
  //
  // 惰性实例化（2026-10-29）：启动只构建首屏 Home；其余五页在首次访问时
  // 才 mount，之后照旧保活。原实现 6 页全量 initState（含 Liveprog 编辑器、
  // 插件表、效果器全量卡片）是启动峰值内存/CPU 的主要来源之一。
  late final List<Widget?> _pages;

  static const _destinations = <({IconData icon, IconData active})>[
    (icon: Icons.home_outlined, active: Icons.home),
    (icon: Icons.tune_outlined, active: Icons.tune),
    (icon: Icons.code_rounded, active: Icons.code),
    (icon: Icons.extension, active: Icons.extension),
    (icon: Icons.swap_vert, active: Icons.swap_vert),
    (icon: Icons.bar_chart_outlined, active: Icons.bar_chart),
  ];

  @override
  void initState() {
    super.initState();
    final m = widget.model;
    _pages = [
      HomePage(model: m), // 首屏立即构建
      null, // Effects
      null, // Liveprog
      null, // Plugins
      null, // Chain
      null, // Visualizer
    ];
  }

  /// 取（必要时创建）指定页实例；创建结果写回缓存，后续切页零重建。
  Widget _pageAt(int i) {
    final cached = _pages[i];
    if (cached != null) return cached;
    final m = widget.model;
    final created = switch (i) {
      0 => HomePage(model: m),
      1 => EffectsPage(model: m),
      2 => LiveprogPage(model: m),
      3 => PluginsPage(model: m),
      4 => ChainPage(model: m),
      _ => VisualizerPage(model: m),
    };
    _pages[i] = created;
    return created;
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final m = widget.model;
    final l = l10nOf(context);
    final labels = [
      l.navHome,
      l.navEffects,
      l.navLiveprog,
      l.navPlugins,
      l.navChain,
      l.navVisualizer,
    ];
    final isMobile = context.isMobile;
    final railWidth = _railCollapsed ? AuraSize.railMinW : AuraSize.railW;

    return Scaffold(
      // SafeArea 在桌面无 padding 时零副作用；Android 竖屏用来避开
      // 状态栏/手势条，底部导航因此不会压到系统手势区。
      body: SafeArea(
        child: ValueListenableBuilder<bool>(
          valueListenable: m.visualizerImmersive,
          builder: (_, immersive, _) {
            final showRail = !immersive && !isMobile;
            final showBottomNav = !immersive && isMobile;
            return Stack(
              children: [
                // 内容层：左/下留位随断点即时切换，不参与动画。若这里也用
                // AnimatedPositioned，跨断点过程中内容会被逐帧压窄，
                // 中途必然触发一次 RenderFlex 溢出（实测）。
                Positioned(
                  left: showRail ? railWidth + 1 : 0,
                  top: 0,
                  right: 0,
                  bottom: showBottomNav ? _kBottomNavH : 0,
                  child: Column(
                    children: [
                      // 仅视效沉浸档：折叠顶部状态栏
                      if (!immersive) ...[
                        _TopBar(
                          model: m,
                          onCycleTheme: _cycleTheme,
                          onOpenSettings: _openSettings,
                        ),
                        Container(height: 1, color: p.hairline),
                      ],
                      Expanded(
                        // P0-1（2026-10-23）：AnimatedSwitcher → IndexedStack。
                        // 原实现切页销毁非当前页（initState 重跑、定时器重启、
                        // settings 全量重建）；保活后切页零重建、滚动/展开态保留。
                        // 配套：离屏页仍在树上——1s 心跳改走 hbTick 级联（P0-2），
                        // 页面定时器按 model.visiblePage 门控，TickerMode 停离屏动画。
                        child: IndexedStack(
                          index: _index,
                          children: [
                            for (var i = 0; i < _pages.length; i++)
                              TickerMode(
                                enabled: i == _index,
                                // 页面切换过渡动效：保持 IndexedStack 零重建保活优势，
                                // 叠加 220ms 丝滑渐变与微上浮过渡，彻底消除突变生硬感。
                                child: _PageTransitionChild(
                                  active: i == _index,
                                  child: i == _index || _pages[i] != null
                                      ? _pageAt(i)
                                      : const SizedBox.shrink(),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 左栏：≥600 显示；<600 由底栏接管。隐藏时移出视口而非
                // 移出树，保证动画可逆且不丢导航状态。
                AnimatedPositioned(
                  duration: AuraDur.base,
                  curve: AuraCurve.emphasized,
                  left: showRail ? 0 : -(railWidth + 1),
                  top: 0,
                  bottom: 0,
                  width: railWidth + 1,
                  child: ExcludeSemantics(
                    excluding: !showRail,
                    child: IgnorePointer(
                      ignoring: !showRail,
                      child: Row(
                        children: [
                          _Rail(
                            key: const ValueKey<String>('shell.rail'),
                            labels: labels,
                            destinations: _destinations,
                            index: _index,
                            onSelect: (i) => setState(() {
                              _index = i;
                              m.visiblePage.value = AppPage
                                  .values[i]; // P0-1：定时器可见性门控 + R2 高频消费点门控
                            }),
                            model: m,
                            collapsed: _railCollapsed,
                            onToggle: () => setState(
                              () => _railCollapsed = !_railCollapsed,
                            ),
                            onOpenSettings: _openSettings,
                          ),
                          Container(width: 1, color: p.hairline),
                        ],
                      ),
                    ),
                  ),
                ),
                // 底栏：仅 <600，滑入/滑出。6 项等分，360px 下每项 60px。
                AnimatedPositioned(
                  duration: AuraDur.base,
                  curve: AuraCurve.emphasized,
                  left: 0,
                  right: 0,
                  bottom: showBottomNav ? 0 : -_kBottomNavH,
                  height: _kBottomNavH,
                  child: ExcludeSemantics(
                    excluding: !showBottomNav,
                    child: IgnorePointer(
                      ignoring: !showBottomNav,
                      child: _BottomNav(
                        key: const ValueKey<String>('shell.bottomNav'),
                        labels: labels,
                        destinations: _destinations,
                        index: _index,
                        onSelect: (i) => setState(() {
                          _index = i;
                          m.visiblePage.value = AppPage.values[i];
                        }),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      // 遮罩固定黑色半透明（与主题无关）：barrierColor 在 open 时求值一次，
      // 若跟主题走，切换主题后遮罩过期。面板底色/边框在 builder 内按当前
      // 主题取，随主题重建（此前在外层抓取 palette 导致底板保持旧主题）。
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (ctx) {
        final p = paletteOf(ctx);
        return Dialog(
          // 面板自身提供底色（此前 transparent 导致"无背景"）
          backgroundColor: p.panel,
          surfaceTintColor: Colors.transparent,
          insetPadding: ctx.isMobile
              ? const EdgeInsets.all(AuraSpace.md)
              : const EdgeInsets.all(AuraSpace.xl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.lg),
            side: BorderSide(color: p.hairline),
          ),
          child: AuraDialogConstraints(
            maxWidth: 720,
            maxHeight: 640,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AuraRadius.lg),
              child: SettingsPage(model: widget.model),
            ),
          ),
        );
      },
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
  final VoidCallback onOpenSettings;

  const _Rail({
    super.key,
    required this.labels,
    required this.destinations,
    required this.index,
    required this.onSelect,
    required this.model,
    required this.collapsed,
    required this.onToggle,
    required this.onOpenSettings,
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
            padding: EdgeInsets.fromLTRB(
              collapsed ? AuraSpace.sm : AuraSpace.lg,
              AuraSpace.xl + AuraSpace.xs,
              collapsed ? AuraSpace.sm : AuraSpace.lg,
              0,
            ),
            child: collapsed
                // 收起态：品牌标记即展开入口（去掉独立按钮，避免与导航项挤在一起）
                ? _BrandTapTarget(
                    onTap: onToggle,
                    tip: l10nOf(context).railExpandTip,
                    child: _BrandMark(p: p),
                  )
                : Row(
                    children: [
                      _BrandMark(p: p),
                      const SizedBox(width: AuraSpace.sm + 2),
                      // Expanded + 省略号：字号放大/回退字体偏宽时不再顶出
                      // 固定宽的导航栏（此前在测试字体下溢出 6.6px）。
                      Expanded(
                        child: Text(
                          'AuraDSP',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'AuraDisplay',
                            fontFamilyFallback: kDisplayCjkFallback,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                            color: p.text,
                          ),
                        ),
                      ),
                      _RailToggle(collapsed: false, onTap: onToggle),
                    ],
                  ),
          ),
          const SizedBox(height: AuraSpace.xl),
          // 导航
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? AuraSpace.sm : AuraSpace.lg,
            ),
            child: Column(
              children: [
                for (var i = 0; i < destinations.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == destinations.length - 1 ? 0 : AuraSpace.xs,
                    ),
                    child: _NavItem(
                      key: ValueKey<String>('shell.railNav.$i'),
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
          // 底部装置信息（收起时隐藏）；设置入口已移至顶栏右上角齿轮
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AuraSpace.lg,
                0,
                AuraSpace.lg,
                AuraSpace.xl,
              ),
              child: ListenableBuilder(
                listenable: model,
                builder: (_, _) {
                  final info = model.info;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(height: 1, color: p.hairline),
                      const SizedBox(height: AuraSpace.md),
                      Text(
                        info == null
                            ? l.engineForm
                            : 'ABI v${info.abi} · ${PlatformProfile.formLabel}',
                        style: monoOf(
                          p,
                          size: 10,
                          color: p.textDim.withValues(alpha: 0.75),
                        ),
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

/// <600 的底部导航：6 页等分，选中态用强调色药丸 + 图标切换。
/// 触控目标高度 60（≥48dp），标签单行省略，避免窄屏横向溢出。
class _BottomNav extends StatelessWidget {
  final List<String> labels;
  final List<({IconData icon, IconData active})> destinations;
  final int index;
  final ValueChanged<int> onSelect;

  const _BottomNav({
    super.key,
    required this.labels,
    required this.destinations,
    required this.index,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < destinations.length; i++)
            Expanded(
              child: _BottomNavItem(
                key: ValueKey<String>('shell.nav.$i'),
                icon: destinations[i].icon,
                activeIcon: destinations[i].active,
                label: labels[i],
                selected: i == index,
                onTap: () => onSelect(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BottomNavItem({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final fg = selected ? p.accent : p.textDim;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: _kBottomNavH,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: AuraDur.fast,
                curve: AuraCurve.standard,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? p.accent.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                ),
                child: Icon(selected ? activeIcon : icon, size: 20, color: fg),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'AuraDisplay',
                    fontFamilyFallback: kBodyCjkFallback,
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
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

/// 同心方块几何标记（呼应 "aura" 的环）
/// 收起态的品牌标记：可点击展开（hover 有反馈）
class _BrandTapTarget extends StatefulWidget {
  final VoidCallback onTap;
  final String tip;
  final Widget child;
  const _BrandTapTarget({
    required this.onTap,
    required this.tip,
    required this.child,
  });

  @override
  State<_BrandTapTarget> createState() => _BrandTapTargetState();
}

class _BrandTapTargetState extends State<_BrandTapTarget> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: Tooltip(
        message: widget.tip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: AuraDur.fast,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _hover ? hoverOn(p, alpha: 0.08) : Colors.transparent,
                borderRadius: BorderRadius.circular(AuraRadius.sm),
                border: Border.all(
                  color: _hover
                      ? p.accent.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
              ),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

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
      message: widget.collapsed
          ? l10nOf(context).railExpandTip
          : l10nOf(context).railCollapseTip,
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
          onTap: () {
            DebugTrace.instance.tap(
              'rail',
              widget.collapsed ? 'expand' : 'collapse',
            );
            widget.onTap();
          },
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
    super.key,
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
        onTap: () {
          DebugTrace.instance.tap('nav', widget.label);
          widget.onTap();
        },
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
                    color: fg,
                  ),
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
                    Icon(
                      widget.selected ? widget.activeIcon : widget.icon,
                      size: AuraSize.navIcon,
                      color: fg,
                    ),
                    const SizedBox(width: AuraSpace.md - 2),
                    Expanded(
                      child: AnimatedDefaultTextStyle(
                        duration: AuraDur.fast,
                        // 字体族必须显式带（DefaultTextStyle 是替换而非合并：
                        // 漏掉 fontFamily 会让中文回退到系统字体，与全站不一致）
                        style: TextStyle(
                          fontFamily: 'AuraDisplay',
                          fontFamilyFallback: kBodyCjkFallback,
                          fontSize: 13,
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: fg,
                        ),
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
  final AppModel model;
  final VoidCallback onCycleTheme;
  final VoidCallback onOpenSettings;
  const _TopBar({
    required this.model,
    required this.onCycleTheme,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    // 窄屏顶栏只保留紧凑状态徽标；完整 MasterStatusConsole 在 360px
    // 会与主题/设置按钮挤爆（2026-11-20 P1 实测溢出 15px）。
    final compact = context.isMobile;
    return SizedBox(
      height: AuraSize.topBarH,
      child: Center(
        heightFactor: 1.0,
        child: Padding(
          // 顶栏贴边：不用内容区的 pageX/contentMaxW（超宽屏下两边会空出一大截），
          // 组件右对齐，左右只留 rowGap。
          padding: const EdgeInsets.symmetric(horizontal: AuraSpace.rowGap),
          child: Row(
            children: [
              const Spacer(),
              // 徽标 / 延迟 / 主题 / 设置（右对齐）。
              ListenableBuilder(
                listenable: model,
                builder: (_, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (compact)
                      StateBadge(
                        engineState: model.engineState,
                        bypass: model.bypass,
                        live: model.liveSpectrum,
                      )
                    else
                      MasterStatusConsole(
                        engineState: model.engineState,
                        bypass: model.bypass,
                        live: model.liveSpectrum,
                        latencyMs: model.latencyMs,
                        onToggleBypass: () => model.toggleBypass(),
                        onRefreshLatency: () =>
                            model.refreshAllComponentLatencies(),
                      ),
                    const SizedBox(width: AuraSpace.sm),
                    _IconAction(
                      key: const ValueKey<String>('shell.topAction.theme'),
                      icon: Icons.palette_outlined,
                      tooltip: l.themeSwitchTip,
                      onTap: onCycleTheme,
                    ),
                    const SizedBox(width: AuraSpace.sm),
                    _IconAction(
                      key: const ValueKey<String>('shell.topAction.settings'),
                      icon: Icons.settings_outlined,
                      tooltip: l.navSettings,
                      onTap: onOpenSettings,
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

/// 图标动作按钮：视觉药丸 32×32；触屏命中区 48×48（R7）
class _IconAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconAction({
    super.key,
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
    // R7：触屏命中区 48（视觉药丸仍 32）；指针保持 32 紧凑排布。
    final hit = context.usesTouchInput ? 48.0 : 32.0;
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
          // opaque：整块命中区可点——透明底色（未 hover）时也必须能点
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: () {
            DebugTrace.instance.tap('icon', widget.tooltip);
            widget.onTap();
          },
          child: SizedBox(
            width: hit,
            height: hit,
            child: Center(
              child: AnimatedScale(
                duration: AuraDur.instant,
                scale: _down ? 0.92 : 1.0,
                child: AnimatedContainer(
                  duration: AuraDur.fast,
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _hover
                        ? hoverOn(p, alpha: 0.07)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                  ),
                  child: Icon(
                    widget.icon,
                    size: 18,
                    color: _hover ? p.text : p.textDim,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
