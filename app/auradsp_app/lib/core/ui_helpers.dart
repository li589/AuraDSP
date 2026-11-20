/*
 * ui_helpers.dart — P0 基础设施：响应式断点 + 输入能力 + 问号帮助徽标
 *
 * - AuraBreakpoint：mobile(<600) / tablet(600-899) / desktop(>=900)，
 *   由 MediaQuery 宽度推导；只负责布局形态，不负责输入能力。
 * - AuraInputMode / AuraInputScope：指针 vs 触屏由真实 PointerDown 判定，
 *   与窗口宽度解耦（窄桌面窗口仍是鼠标，宽触屏平板仍是触屏）。
 * - InfoBadge：问号圆圈徽标 + 定制箭头气泡（OverlayEntry + LayerLink 跟随）。
 *   指针环境 hover 300ms 弹出、离即消；触屏长按/点击弹出、3.5s 自动收起。
 *   空间不足自动翻转。
 */
import 'dart:async' show Timer;
import 'dart:ui' show PointerDeviceKind;

import 'package:auradsp_app/l10n/gen/app_localizations.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/platform_profile.dart';
import 'design.dart';
import 'theme.dart';

/* ---------- 响应式断点 ---------- */

/// 断点常量集中在此，避免页面各自写魔法数。
/// 注意：这些值只决定**布局形态**；输入能力见 [AuraInputMode]。
class AuraBreakpoints {
  const AuraBreakpoints._();

  /// 承诺支持的最小视口宽度（Q2 owner 裁定 2026-11-20）。
  static const minSupported = 360.0;

  /// 超窄档：单列、全屏浮层。
  static const compact = 480.0;

  /// mobile / tablet 分界。
  static const tablet = 600.0;

  /// tablet / desktop 分界。
  static const desktop = 900.0;
}

enum AuraBreakpoint { mobile, tablet, desktop }

extension AuraBreakpointX on BuildContext {
  AuraBreakpoint get auraBreakpoint {
    final w = MediaQuery.sizeOf(this).width;
    if (w < AuraBreakpoints.tablet) return AuraBreakpoint.mobile;
    if (w < AuraBreakpoints.desktop) return AuraBreakpoint.tablet;
    return AuraBreakpoint.desktop;
  }

  bool get isMobile => auraBreakpoint == AuraBreakpoint.mobile;
  bool get isTablet => auraBreakpoint == AuraBreakpoint.tablet;
  bool get isDesktop => auraBreakpoint == AuraBreakpoint.desktop;

  /// <480 的超窄子档；不新增 enum，避免破坏既有三档语义与测试。
  bool get isCompactWidth =>
      MediaQuery.sizeOf(this).width < AuraBreakpoints.compact;

  /// 页面左右留白：mobile 16 / tablet 24 / desktop 32（= AuraSpace.pageX）
  double get responsivePageX => switch (auraBreakpoint) {
    AuraBreakpoint.mobile => AuraSpace.lg,
    AuraBreakpoint.tablet => AuraSpace.xl,
    AuraBreakpoint.desktop => AuraSpace.pageX,
  };

  /// 卡片内边距：mobile 16 / tablet 18 / desktop 20（= AuraSpace.cardPad）
  double get responsiveCardPad => switch (auraBreakpoint) {
    AuraBreakpoint.mobile => AuraSpace.lg,
    AuraBreakpoint.tablet => 18.0,
    AuraBreakpoint.desktop => AuraSpace.cardPad,
  };

  /// 内容区最大宽度：mobile 480 / tablet 720 / desktop 1080
  double get responsiveMaxW => switch (auraBreakpoint) {
    AuraBreakpoint.mobile => 480.0,
    AuraBreakpoint.tablet => 720.0,
    AuraBreakpoint.desktop => AuraSpace.contentMaxW,
  };
}

/* ---------- 输入能力（与宽度解耦） ---------- */

/// 输入能力：指针（鼠标/触控板）或触屏。
/// Q3 owner 裁定（2026-11-20）：宽度只决定布局，输入能力独立判定。
enum AuraInputMode { pointer, touch }

/// 在应用外壳根部安装一次，监听真实 PointerDown 事件。
/// 子树通过 `context.usesTouchInput` / `context.auraInputMode` 读取。
class AuraInputScope extends StatefulWidget {
  final Widget child;

  const AuraInputScope({super.key, required this.child});

  /// 无 Scope 时返回 null，调用方自行回退（测试单独 pump 组件时常见）。
  static AuraInputMode? maybeModeOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_AuraInputInherited>();
    return scope?.notifier?.value;
  }

  @override
  State<AuraInputScope> createState() => _AuraInputScopeState();
}

class _AuraInputScopeState extends State<AuraInputScope> {
  late final ValueNotifier<AuraInputMode> _mode;

  @override
  void initState() {
    super.initState();
    // 首帧先按平台给一个合理默认；首个 PointerDown 会立即校正。
    // 平台默认输入能力经 PlatformProfile 取（M4 铁律：平台判定只许落在
    // lib/platform/platform_profile.dart，业务层不得直读 defaultTargetPlatform）。
    _mode = ValueNotifier(
      PlatformProfile.prefersTouchInput
          ? AuraInputMode.touch
          : AuraInputMode.pointer,
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    final next = switch (event.kind) {
      PointerDeviceKind.touch ||
      PointerDeviceKind.stylus ||
      PointerDeviceKind.invertedStylus => AuraInputMode.touch,
      _ => AuraInputMode.pointer,
    };
    if (_mode.value != next) _mode.value = next;
  }

  @override
  void dispose() {
    _mode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AuraInputInherited(
      notifier: _mode,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        child: widget.child,
      ),
    );
  }
}

class _AuraInputInherited
    extends InheritedNotifier<ValueNotifier<AuraInputMode>> {
  const _AuraInputInherited({required super.notifier, required super.child});
}

extension AuraInputModeX on BuildContext {
  /// 有 Scope 时以真实指针事件为准；独立组件（无 Scope）回退到宽度语义，
  /// 保证既有测试与局部预览不崩。
  AuraInputMode get auraInputMode =>
      AuraInputScope.maybeModeOf(this) ??
      (isMobile ? AuraInputMode.touch : AuraInputMode.pointer);

  bool get usesTouchInput => auraInputMode == AuraInputMode.touch;
}

/* ---------- 问号帮助徽标 ---------- */

// 气泡内边距：_show() 的尺寸估算与 infoBubble 的实际渲染共用同一份常量。
// 两者一旦不一致，估算高度就会偏离渲染高度，翻转到上方时会把气泡压到徽标上。
const _bubblePadH = 10.0;
const _bubblePadV = 7.0;
const _bubbleBorder = 1.0;
// 气泡宽相对文字自然宽度的余量。取 0 时约束恰好卡在文字宽度上，
// TextPainter 与 Text 在该临界点可能给出不同换行结果（实测一行 vs 两行），
// 估算高度随即与渲染高度不符。
const _bubbleSlack = 2.0;

/// 问号徽标：放在标题/标签右侧，承载次要说明（替代冗余 hint）。
///
/// ```dart
/// Row(children: [
///   Text(l.stereoWiden, style: sectionOf(p)),
///   const SizedBox(width: AuraSpace.xs),
///   InfoBadge(message: l.stereoWidenHint),
/// ])
/// ```
///
/// 全局/页面级帮助徽标（问号）可见性控制器
/// - 桌面端：持续常驻显示（鼠标环境空间充裕，便于随时查看）
/// - 移动端：滑动页面时唤醒显示，停止滑动后延迟一段时间（2.6s）自动平滑淡出隐藏，保持极简界面
class HelpVisibilityController extends ChangeNotifier {
  bool _isScrollingOrRecent = false;
  Timer? _hideTimer;
  static const Duration hideDelay = Duration(milliseconds: 2600);

  bool get isScrollingOrRecent => _isScrollingOrRecent;

  void recordScroll() {
    _hideTimer?.cancel();
    if (!_isScrollingOrRecent) {
      _isScrollingOrRecent = true;
      notifyListeners();
    }
    _hideTimer = Timer(hideDelay, () {
      _isScrollingOrRecent = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }
}

/// 帮助徽标可见性 Scope（通过 InheritedNotifier 提供给下层组件）
class HelpVisibilityScope extends InheritedNotifier<HelpVisibilityController> {
  const HelpVisibilityScope({
    super.key,
    required HelpVisibilityController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 查询当前上下文中的问号是否应该可见
  /// - 指针环境：恒返回 true，保持常驻（窄桌面窗口也走这条）
  /// - 触屏环境：仅在滑动中或滑动后延迟时间内返回 true
  static bool isVisibleOf(BuildContext context) {
    if (!context.usesTouchInput) {
      return true;
    }
    final scope = context
        .dependOnInheritedWidgetOfExactType<HelpVisibilityScope>();
    return scope?.notifier?.isScrollingOrRecent ?? false;
  }
}

/// 统一帮助徽标（带指向箭头的提示气泡）
/// 触发：
/// - 电脑端：持续常驻显示；悬停 300ms 弹出、移开即隐；点击可切换显示/关闭。
/// - 移动端：滑动页面时唤醒显示、停止滑动后延迟 2.6s 平滑淡出隐藏；支持触屏直接点击展开/收起气泡（3.5s 自动淡出防遮挡）。
class InfoBadge extends StatefulWidget {
  /// 气泡内容（支持换行；请传 l10n 文案，勿硬编码）
  final String message;

  /// 徽标直径（默认 15.0；命中区另有 4px 透明外衬）
  final double size;

  /// 气泡优先显示在徽标下方（默认 true；空间不足自动翻转）
  final bool preferBelow;

  /// 气泡最大宽度（默认 380）
  final double maxWidth;

  const InfoBadge({
    super.key,
    required this.message,
    this.size = 15.0,
    this.preferBelow = true,
    this.maxWidth = 380,
  });

  @override
  State<InfoBadge> createState() => _InfoBadgeState();
}

class _InfoBadgeState extends State<InfoBadge> {
  final LayerLink _link = LayerLink();
  final GlobalKey _bubbleKey = GlobalKey();
  OverlayEntry? _entry;
  Timer? _showTimer;
  Timer? _hideTimer;
  bool _hover = false;

  // 定位中间量：首帧用估算值，插入后按真实渲染尺寸回正。
  late Offset _origin;
  late double _badgeH;
  late double _centerX;
  late Size _screen;
  late double _maxW;
  double _bubbleW = 0;
  double _placedH = 0;
  double _left = 0;
  double _top = 0;
  double _arrowX = 0;
  double _colW = 0;
  bool _below = true;

  static const _hoverDelay = Duration(milliseconds: 300);
  static const _touchVisible = Duration(milliseconds: 3500);
  static const _arrowW = 12.0;
  static const _arrowH = 7.0;
  // 徽标边缘到箭头尖端的距离。翻上/翻下必须取同一值，
  // 否则同一气泡在两个方向上与徽标的间距不一致。
  static const _gap = 11.0;
  static const _margin = 16.0;
  static const _padH = _bubblePadH;
  static const _padV = _bubblePadV;

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _removeEntry();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _hide() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _removeEntry();
  }

  void _show() {
    if (_entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    if (Overlay.maybeOf(context) == null) return;
    final p = paletteOf(context);
    _origin = box.localToGlobal(Offset.zero);
    _badgeH = box.size.height;
    _centerX = _origin.dx + box.size.width / 2;
    _screen = MediaQuery.sizeOf(context);
    _maxW = math.min(widget.maxWidth, _screen.width - _margin * 2).toDouble();

    // 估算气泡宽高（首帧定位用），随后一律以真实渲染尺寸回正。
    final span = TextSpan(
      text: widget.message,
      style: captionOf(p, color: p.text),
    );
    final dir = Directionality.of(context);
    double avail(double bubbleW) =>
        math.max(40.0, bubbleW - _padH * 2 - _bubbleBorder * 2).toDouble();
    var probe = TextPainter(text: span, textDirection: dir)
      ..layout(maxWidth: avail(_maxW));
    _bubbleW = math
        .min(_maxW, probe.width + _padH * 2 + _bubbleBorder * 2 + _bubbleSlack)
        .toDouble();
    probe = TextPainter(text: span, textDirection: dir)
      ..layout(maxWidth: avail(_bubbleW));
    _place(probe.height + _padV * 2 + _bubbleBorder * 2);

    _entry = OverlayEntry(builder: (_) => _overlayChild(p));
    Overlay.of(context).insert(_entry!);
    // TextPainter 复刻不出真实布局（字体度量/换行/边框任一环节对不上就偏），
    // 首帧后按真实渲染尺寸回正一次；高度不影响宽度，故一次即收敛。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncToActual());
  }

  /// 按给定气泡高度计算朝向与坐标（换算到 follower 坐标系：原点=徽标左上角）。
  void _place(double bubbleH) {
    _placedH = bubbleH;
    final bottomEdge = _origin.dy + _badgeH;
    final fitsBelow =
        bottomEdge + _gap + _arrowH + bubbleH + 8 <= _screen.height;
    final fitsAbove = _origin.dy - _gap - _arrowH - bubbleH - 8 >= 0;
    _below = widget.preferBelow ? (fitsBelow || !fitsAbove) : !fitsAbove;
    _left =
        (_centerX - _bubbleW / 2)
            .clamp(
              _margin,
              math.max(_margin, _screen.width - _margin - _bubbleW),
            )
            .toDouble() -
        _origin.dx;
    _top =
        (_below ? bottomEdge + _gap : _origin.dy - _gap - _arrowH - bubbleH) -
        _origin.dy;
    _arrowX = (_centerX - _origin.dx - _left)
        .clamp(_arrowW, math.max(_arrowW, _bubbleW - _arrowW))
        .toDouble();
    // 列宽取 max：短文案时箭头行不把列撑开、气泡不错位。
    _colW = math.max(_bubbleW, _arrowX + _arrowW / 2 + _padH).toDouble();
  }

  /// 读取气泡的真实渲染尺寸并回正位置（估算偏低会让翻上的气泡压住徽标）。
  /// _bubbleKey 挂在含箭头行的 Column 上，故减去恒定存在的箭头高度。
  void _syncToActual() {
    if (!mounted || _entry == null) return;
    final rb = _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null || !rb.attached) return;
    final actualH = rb.size.height - _arrowH;
    if ((actualH - _placedH).abs() < 0.5) return;
    _place(actualH);
    _entry!.markNeedsBuild();
  }

  Widget _overlayChild(AuraPalette p) {
    return IgnorePointer(
      // 气泡只读，绝不可拦截指针：OverlayEntry 里的 Material + 全屏 SizedBox
      // 覆盖在徽标之上，插入那一帧会抢走徽标的命中 → onExit → _hide，
      // 指针回到徽标 → onEnter → 300ms 后再弹出，形成"闪动"。
      child: Material(
        type: MaterialType.transparency,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.topLeft,
          child: SizedBox(
            width: _screen.width,
            height: _screen.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: _left,
                  top: _top,
                  child: SizedBox(
                    key: _bubbleKey,
                    width: _colW,
                    child: infoBubble(
                      p: p,
                      message: widget.message,
                      below: _below,
                      arrowX: _arrowX,
                      width: _bubbleW,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isVisible = HelpVisibilityScope.isVisibleOf(context);
    // R7：触屏按 Material 最小触控目标 48；指针沿用 15+4×2=23 的紧凑外衬。
    final hit = context.usesTouchInput ? 48.0 : widget.size + AuraSpace.xs * 2;

    // 移动端淡出隐藏时若浮层仍在，安全关闭浮层
    if (!isVisible && _entry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !HelpVisibilityScope.isVisibleOf(context)) {
          _hide();
        }
      });
    }

    return AnimatedOpacity(
      opacity: isVisible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInOut,
      child: IgnorePointer(
        ignoring: !isVisible,
        child: Semantics(
          label: widget.message,
          button: true,
          child: CompositedTransformTarget(
            link: _link,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) {
                if (!mounted) return;
                setState(() => _hover = true);
                _showTimer?.cancel();
                _showTimer = Timer(_hoverDelay, () {
                  if (mounted) _show();
                });
              },
              onExit: (_) {
                if (!mounted) return;
                setState(() => _hover = false);
                _hide();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (_) {
                  _showTimer?.cancel();
                  _show();
                  _hideTimer?.cancel();
                  _hideTimer = Timer(_touchVisible, () {
                    if (mounted) _hide();
                  });
                },
                onTap: () {
                  // 点击切换气泡显示/隐藏
                  if (_entry != null) {
                    _hide();
                  } else {
                    _show();
                    // 移动端点击打开时，启动 3.5s 自动淡出防遮挡（再次点击可立即收起）
                    _hideTimer?.cancel();
                    _hideTimer = Timer(_touchVisible, () {
                      if (mounted) _hide();
                    });
                  }
                },
                // 命中区：指针 23（15 视觉 + 4×2 透明外衬）；触屏 48（R7 触控目标）。
                // 触屏必须让布局盒本身达到 48——RenderBox 只在自己尺寸内命中，
                // 溢出绘制出去的部分收不到点击，无法"只看不占位"。
                child: SizedBox(
                  width: hit,
                  height: hit,
                  child: Center(
                    child: Container(
                      width: widget.size,
                      height: widget.size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _hover
                              ? p.accent
                              : p.textDim.withValues(alpha: 0.55),
                          width: 1.2,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.question_mark_rounded,
                          size: widget.size * 0.65,
                          color: _hover ? p.accent : p.textDim,
                        ),
                      ),
                    ),
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

/// 气泡内容体（Overlay 与送审渲染共用同一套，保持一致）。
/// below=true：箭头在上、气泡在下；反之镜像。
/// width 由调用方按「测量宽度 == 渲染宽度」算好传入，避免换行数与估算不一致。
Widget infoBubble({
  required AuraPalette p,
  required String message,
  required bool below,
  required double arrowX,
  required double width,
}) {
  final bubble = Container(
    width: width,
    decoration: BoxDecoration(
      color: p.panelRaised,
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      border: Border.all(color: p.hairline, width: 1),
    ),
    padding: const EdgeInsets.symmetric(
      horizontal: _bubblePadH,
      vertical: _bubblePadV,
    ),
    child: Text(message, style: captionOf(p, color: p.text)),
  );
  final arrow = _ArrowRow(arrowX: arrowX, pointUp: below, palette: p);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: below ? [arrow, bubble] : [bubble, arrow],
  );
}

/// 气泡箭头行：三角指向徽标。
class _ArrowRow extends StatelessWidget {
  final double arrowX;
  final bool pointUp;
  final AuraPalette palette;
  const _ArrowRow({
    required this.arrowX,
    required this.pointUp,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: math.max(0.0, arrowX - 12.0 / 2).toDouble()),
        CustomPaint(
          size: const Size(12.0, 7.0),
          painter: _ArrowPainter(
            color: palette.panelRaised,
            border: palette.hairline,
            pointUp: pointUp,
          ),
        ),
      ],
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  final Color border;
  final bool pointUp;
  const _ArrowPainter({
    required this.color,
    required this.border,
    required this.pointUp,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(0, pointUp ? h : 0)
      ..lineTo(w / 2, pointUp ? 0 : h)
      ..lineTo(w, pointUp ? h : 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    // 只描两条斜边：底边与气泡边框重合，不重复描。
    final base = pointUp ? h : 0.0;
    final apex = pointUp ? 0.0 : h;
    final pen = Paint()
      ..color = border
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0.5, base), Offset(w / 2, apex), pen);
    canvas.drawLine(Offset(w / 2, apex), Offset(w - 0.5, base), pen);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.color != color || old.border != border || old.pointUp != pointUp;
}

/// l10n 取用便捷通道（P1 后从 ui/widgets.dart 上移到 core，供 ui/ 与 features/ 共用）。
AppLocalizations l10nOf(BuildContext context) => AppLocalizations.of(context)!;
