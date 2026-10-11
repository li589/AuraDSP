/*
 * ui_helpers.dart — P0 基础设施：响应式断点 + 问号帮助徽标
 *
 * - AuraBreakpoint：mobile(<600) / tablet(600-900) / desktop(>900)，
 *   由 MediaQuery 宽度推导；PageScaffold 在 P2 阶段接入。
 * - InfoBadge：问号圆圈徽标 + 定制箭头气泡（OverlayEntry + LayerLink 跟随）。
 *   桌面 hover 300ms 弹出、离即消；触屏长按弹出、2.5s 后自动收起、
 *   再点徽标也可关闭。空间不足自动翻转。R2 取代 P0 的 Tooltip 版。
 */
import 'dart:async' show Timer;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design.dart';
import 'theme.dart';

/* ---------- 响应式断点 ---------- */

enum AuraBreakpoint { mobile, tablet, desktop }

extension AuraBreakpointX on BuildContext {
  AuraBreakpoint get auraBreakpoint {
    final w = MediaQuery.sizeOf(this).width;
    if (w < 600) return AuraBreakpoint.mobile;
    if (w < 900) return AuraBreakpoint.tablet;
    return AuraBreakpoint.desktop;
  }

  bool get isMobile => auraBreakpoint == AuraBreakpoint.mobile;
  bool get isTablet => auraBreakpoint == AuraBreakpoint.tablet;
  bool get isDesktop => auraBreakpoint == AuraBreakpoint.desktop;

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

/* ---------- 问号帮助徽标 ---------- */

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
/// 触发：桌面 hover 300ms 弹出、离即消；触屏长按弹出、2.5s 后自动收起、
/// 再点徽标也可关闭。气泡带指向箭头，空间不足自动翻转，并跟随目标滚动。
class InfoBadge extends StatefulWidget {
  /// 气泡内容（支持换行；请传 l10n 文案，勿硬编码）
  final String message;

  /// 徽标直径（默认 16；命中区另有 4px 透明外衬）
  final double size;

  /// 气泡优先显示在徽标下方（默认 true；空间不足自动翻转）
  final bool preferBelow;

  /// 气泡最大宽度（默认 380）
  final double maxWidth;

  const InfoBadge({
    super.key,
    required this.message,
    this.size = 16,
    this.preferBelow = true,
    this.maxWidth = 380,
  });

  @override
  State<InfoBadge> createState() => _InfoBadgeState();
}

class _InfoBadgeState extends State<InfoBadge> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  Timer? _showTimer;
  Timer? _hideTimer;
  bool _hover = false;

  static const _hoverDelay = Duration(milliseconds: 300);
  static const _touchVisible = Duration(milliseconds: 3500);
  static const _arrowW = 12.0;
  static const _arrowH = 7.0;
  static const _gap = 4.0;
  static const _margin = 16.0;
  static const _padH = 12.0;
  static const _padV = 8.0;

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
    final screen = MediaQuery.sizeOf(context);
    final p = paletteOf(context);
    final origin = box.localToGlobal(Offset.zero);
    final centerX = origin.dx + box.size.width / 2;

    // 先量气泡尺寸（与实际渲染同一样式、同宽约束）。
    final maxW = math.min(widget.maxWidth, screen.width - _margin * 2).toDouble();
    final tp = TextPainter(
      text: TextSpan(
          text: widget.message, style: captionOf(p, color: p.text)),
      textDirection: Directionality.of(context),
    )..layout(maxWidth: math.max(40.0, maxW - _padH * 2).toDouble());
    final bubbleW = tp.width + _padH * 2;
    final bubbleH = tp.height + _padV * 2;

    final bottomEdge = origin.dy + box.size.height;
    final fitsBelow =
        bottomEdge + _gap + _arrowH + bubbleH + 8 <= screen.height;
    final fitsAbove = origin.dy - _gap - _arrowH - bubbleH - 8 >= 0;
    final below =
        widget.preferBelow ? (fitsBelow || !fitsAbove) : !fitsAbove;

    final bubbleLeft = (centerX - bubbleW / 2)
        .clamp(_margin, math.max(_margin, screen.width - _margin - bubbleW))
        .toDouble();
    final bubbleTop = below
        ? bottomEdge + _gap + _arrowH
        : origin.dy - _gap - _arrowH - bubbleH;
    final arrowX = (centerX - bubbleLeft)
        .clamp(_arrowW, math.max(_arrowW, bubbleW - _arrowW))
        .toDouble();
    // 列宽取 max：短文案时箭头行不把列撑开、气泡不错位。
    final colW = math.max(bubbleW, arrowX + _arrowW / 2 + _padH).toDouble();

    _entry = OverlayEntry(
      builder: (_) => Material(
        type: MaterialType.transparency,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.topLeft,
          child: SizedBox(
            width: screen.width,
            height: screen.height,
            child: Stack(
              children: [
                Positioned(
                  left: bubbleLeft,
                  top: bubbleTop,
                  child: SizedBox(
                    width: colW,
                    child: infoBubble(
                      p: p,
                      message: widget.message,
                      below: below,
                      arrowX: arrowX,
                      maxWidth: maxW,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Semantics(
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
              }
            },
            // 4px 透明外衬：视觉仍是 16，触屏命中到 24
            child: Padding(
              padding: const EdgeInsets.all(AuraSpace.xs),
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        _hover ? p.accent : p.textDim.withValues(alpha: 0.55),
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
    );
  }
}

/// 气泡内容体（Overlay 与送审渲染共用同一套，保持一致）。
/// below=true：箭头在上、气泡在下；反之镜像。
Widget infoBubble({
  required AuraPalette p,
  required String message,
  required bool below,
  required double arrowX,
  double maxWidth = 380,
}) {
  final bubble = Container(
    width: double.infinity,
    constraints: BoxConstraints(maxWidth: maxWidth),
    decoration: BoxDecoration(
      color: p.panelRaised,
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      border: Border.all(color: p.hairline, width: 1),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
  const _ArrowRow(
      {required this.arrowX, required this.pointUp, required this.palette});

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
              pointUp: pointUp),
        ),
      ],
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  final Color border;
  final bool pointUp;
  const _ArrowPainter(
      {required this.color, required this.border, required this.pointUp});

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
