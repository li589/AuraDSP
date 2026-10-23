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

import '../core/design.dart';
import '../core/engine_error_map.dart';
import '../core/nav.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chain_page.dart';
import 'effects_page.dart';
import 'home_page.dart';
import 'liveprog_page.dart';
import 'plugins_page.dart';
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

  // 页面实例缓存（P0-1）：IndexedStack 保活——切页复用既有 State
  // （保滚动/折叠态、避免 initState 重跑），也避免 build 每帧构造页面对象。
  late final List<Widget> _pages;

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
      HomePage(model: m),
      EffectsPage(model: m),
      LiveprogPage(model: m),
      PluginsPage(model: m),
      ChainPage(model: m),
      VisualizerPage(model: m),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final m = widget.model;
    final l = l10nOf(context);
    final labels = [l.navHome, l.navEffects, l.navLiveprog, l.navPlugins, l.navChain, l.navVisualizer];

    return Scaffold(
      body: Row(
        children: [
          _Rail(
            labels: labels,
            destinations: _destinations,
            index: _index,
            onSelect: (i) => setState(() {
              _index = i;
              m.visiblePage = AppPage.values[i]; // P0-1：定时器可见性门控
            }),
            model: m,
            collapsed: _railCollapsed,
            onToggle: () => setState(() => _railCollapsed = !_railCollapsed),
            onOpenSettings: _openSettings,
          ),
          Container(width: 1, color: p.hairline),
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  model: m,
                  onCycleTheme: _cycleTheme,
                  onOpenSettings: _openSettings,
                ),
                Container(height: 1, color: p.hairline),
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
                        TickerMode(enabled: i == _index, child: _pages[i]),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
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
          insetPadding: const EdgeInsets.all(AuraSpace.xl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.lg),
            side: BorderSide(color: p.hairline),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
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
            padding: EdgeInsets.fromLTRB(collapsed ? AuraSpace.sm : AuraSpace.lg,
                AuraSpace.xl + AuraSpace.xs, collapsed ? AuraSpace.sm : AuraSpace.lg, 0),
            child: collapsed
                // 收起态：品牌标记即展开入口（去掉独立按钮，避免与导航项挤在一起）
                ? _BrandTapTarget(onTap: onToggle, tip: l10nOf(context).railExpandTip,
                    child: _BrandMark(p: p))
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
          // 底部装置信息（收起时隐藏）；设置入口已移至顶栏右上角齿轮
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
/// 收起态的品牌标记：可点击展开（hover 有反馈）
class _BrandTapTarget extends StatefulWidget {
  final VoidCallback onTap;
  final String tip;
  final Widget child;
  const _BrandTapTarget({required this.onTap, required this.tip, required this.child});

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
                  color: _hover ? p.accent.withValues(alpha: 0.5) : Colors.transparent,
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
                        // 字体族必须显式带（DefaultTextStyle 是替换而非合并：
                        // 漏掉 fontFamily 会让中文回退到系统字体，与全站不一致）
                        style: TextStyle(
                          fontFamily: 'AuraDisplay',
                          fontFamilyFallback: kBodyCjkFallback,
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
    return SizedBox(
      height: AuraSize.topBarH,
      child: Center(
        heightFactor: 1.0,
        child: Padding(
          // 顶栏贴边：不用内容区的 pageX/contentMaxW（超宽屏下两边会空出一大截），
          // 组件右对齐，左右只留 rowGap。
          padding:
              const EdgeInsets.symmetric(horizontal: AuraSpace.rowGap),
          child: Row(
            children: [
              const Spacer(),
              // 徽标 / 延迟 / 主题 / 设置（右对齐）。
              ListenableBuilder(
                  listenable: model,
                  builder: (_, _) => Row(
                    children: [
                      StateBadge(
                          engineState: model.engineState,
                          bypass: model.bypass,
                          live: model.liveSpectrum),
                      const SizedBox(width: AuraSpace.sm),
                      LatencyBadge(ms: model.latencyMs),
                      const SizedBox(width: AuraSpace.sm),
                      _IconAction(
                        icon: Icons.palette_outlined,
                        tooltip: l.themeSwitchTip,
                        onTap: onCycleTheme,
                      ),
                      const SizedBox(width: AuraSpace.sm),
                      _IconAction(
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

/// 引擎事件 → SnackBar（guard 拒绝 / 运行时错误）。
///
/// 2026-10-18 UI 排查重写：旧实现把 `addPostFrameCallback` 放在
/// ValueListenableBuilder 的 build 里——首次事件后 `eventSeq` 永不为 0，
/// 于是父级每次重建（切页 / 主题切换 / 任意 notifyListeners）都会再注册
/// 一次回调整并重跑消费逻辑；帧间连发两个事件时，前一个还会被后一个
/// 覆盖吞掉。现改为 listener 驱动：每次 `eventSeq` 自增恰好触发一次，
/// 与重建彻底解钩；同因抑制由 AppModel._admitEngineEvent 负责。
class EventBanner extends StatefulWidget {
  final AppModel model;
  const EventBanner({super.key, required this.model});

  @override
  State<EventBanner> createState() => _EventBannerState();
}

class _EventBannerState extends State<EventBanner> {
  @override
  void initState() {
    super.initState();
    widget.model.eventSeq.addListener(_onEvent);
  }

  @override
  void dispose() {
    widget.model.eventSeq.removeListener(_onEvent);
    super.dispose();
  }

  void _onEvent() {
    if (widget.model.eventSeq.value == 0) return;
    // 一次性事件字段由 isolate 消息线程先写入；post-frame 读取并消费，
    // 保证同一帧内连发多个事件时按序各弹一次（先到先消费）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      final p = paletteOf(context);
      final guard = widget.model.lastGuard;
      final err = widget.model.lastEngineError;
      final info = widget.model.lastInfo;
      // 一旦读取消费，立即清空一次性事件状态，杜绝任何后续操作重复唤起
      widget.model.clearLastGuard();
      widget.model.clearLastEngineError();
      widget.model.clearLastInfo();
      final rawText = guard != null
          ? guard.message
          : (err ?? info ?? '');
      // B-2（D2）：引擎错误展示层本地化 + 脱敏（guard/error 来自引擎；
      // info 为 Dart 侧已本地化文案，原样透传）。detail（如 gate.maxFileMb）
      // 在此丢弃；原始串已由 state.dart 消费点 dbgLog 保留。
      final text = (guard != null || err != null)
          ? localizeEngineError(rawText, l10nOf(context))
          : rawText;
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
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
