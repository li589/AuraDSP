/*
 * aura_dialog.dart — 浮层统一约束（2026-11-20 窄屏 P2）
 *
 * 目标：所有 Dialog/AlertDialog 的内容区在窄屏不超出视口；桌面保持原尺寸。
 * - auraDialogInset：<600 用 12px 边距，桌面沿用 Material 默认 40/24；
 * - AuraDialogConstraints：把内容最大宽高收敛到「设计上限 ∩ 视口可用空间」，
 *   并把键盘 viewInsets 计入高度，避免输入框顶起后按钮不可达。
 */
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/ui_helpers.dart';

/// 浮层外边距：窄屏收紧到 12，桌面与 Material 默认一致（40/24）。
EdgeInsets auraDialogInset(BuildContext context) {
  final compact = MediaQuery.sizeOf(context).width < AuraBreakpoints.tablet;
  return compact
      ? const EdgeInsets.all(12)
      : const EdgeInsets.symmetric(horizontal: 40, vertical: 24);
}

/// 浮层内容约束：设计上限 + 视口可用空间取小。
///
/// 用法：包住原先写死的 `SizedBox(width:, height:)`，内部再用
/// `SizedBox(width: double.infinity, height: double.infinity)` 填满，
/// 即可在桌面保持原尺寸、窄屏收缩。
class AuraDialogConstraints extends StatelessWidget {
  final double maxWidth;
  final double maxHeight;
  final Widget child;

  const AuraDialogConstraints({
    super.key,
    required this.maxWidth,
    required this.maxHeight,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final inset = auraDialogInset(context);

    final availableW = math.max(0.0, screen.width - inset.horizontal);
    final availableH = math.max(
      0.0,
      screen.height -
          padding.top -
          padding.bottom -
          viewInsets.bottom -
          inset.vertical,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: math.min(maxWidth, availableW),
        maxHeight: math.min(maxHeight, availableH),
      ),
      child: child,
    );
  }
}
