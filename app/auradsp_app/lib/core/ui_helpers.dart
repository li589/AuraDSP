/*
 * ui_helpers.dart — P0 基础设施：响应式断点 + 问号帮助徽标
 *
 * - AuraBreakpoint：mobile(<600) / tablet(600-900) / desktop(>900)，
 *   由 MediaQuery 宽度推导；PageScaffold 在 P2 阶段接入。
 * - InfoBadge：问号圆圈徽标。触发走 Flutter Tooltip 原生行为——
 *   桌面端 hover 300ms 弹出，Android/iOS 长按弹出、抬指后保留
 *   showDuration（滚动后暂留的近似）；Web 降级为同一 Tooltip。
 *   注：气泡无指向箭头（Tooltip 不支持）；如评审坚持要箭头，
 *   P2 再做 OverlayEntry 自定义气泡（需真机视觉验证）。
 */
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
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
class InfoBadge extends StatefulWidget {
  /// 气泡内容（支持换行；请传 l10n 文案，勿硬编码）
  final String message;

  /// 徽标直径（默认 16；命中区另有 4px 透明外衬）
  final double size;

  /// 气泡优先显示在徽标下方（默认 true；空间不足时 Tooltip 自动翻转）
  final bool preferBelow;

  const InfoBadge({
    super.key,
    required this.message,
    this.size = 16,
    this.preferBelow = true,
  });

  @override
  State<InfoBadge> createState() => _InfoBadgeState();
}

class _InfoBadgeState extends State<InfoBadge> {
  bool _hover = false;

  static bool get _touchFirst =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Tooltip(
      message: widget.message,
      // 桌面 hover 300ms 弹出（方案A）；触屏走长按，waitDuration 不适用
      waitDuration: const Duration(milliseconds: 300),
      // 触屏抬指后气泡保留 2.5s（滚动后暂留的近似）；桌面离即消
      showDuration:
          _touchFirst ? const Duration(milliseconds: 2500) : null,
      preferBelow: widget.preferBelow,
      verticalOffset: 10,
      padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.sm, vertical: AuraSpace.xs),
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline, width: 1),
      ),
      textStyle: captionOf(p, color: p.text),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        // 4px 透明外衬：视觉仍是 16，触屏命中到 24
        child: Padding(
          padding: const EdgeInsets.all(AuraSpace.xs),
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: _hover ? p.accent : p.textDim.withValues(alpha: 0.55),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Icon(
                Icons.help_outline_rounded,
                size: widget.size * 0.7,
                color: _hover ? p.accent : p.textDim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
