// wheel_scroll.dart —— 列表滚轮门控（2026-10-28，修正版）。
//
// 需求：脚本 / 插件 / 处理链页面里，鼠标在「可滚动列表」内滚动时只滚列表、
// 不带动整页；列表不可滚动（内容未超高度）时滚轮放行给页面；列表外滚页面。
//
// 为什么用自定义 ScrollPhysics 而不是手动 Listener：
// Flutter 的 Scrollable 只在 `physics.shouldAcceptUserOffset(position)` 为真
// 时才注册滚轮信号（scrollable.dart `_receivedPointerSignal`）。默认 physics
// 会对「不可滚动的短列表」也返回 true，把滚轮吃掉（短列表挡住页面）；而
// NeverScrollableScrollPhysics 又会让滚动条拖拽失效（拖拽走 applyUserOffset，
// 但列表被物理禁止）。这里按「是否存在滚动区间」精确表态：
//   - maxScrollExtent > minScrollExtent → true：滚轮滚列表（到顶到底也不带动
//     页面，符合用户口径），Scrollbar 拖拽正常；
//   - 否则 false：滚轮穿透给页面。
import 'package:flutter/widgets.dart';

class AuraListScrollPhysics extends ScrollPhysics {
  const AuraListScrollPhysics({super.parent});

  @override
  AuraListScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AuraListScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      position.maxScrollExtent > position.minScrollExtent;
}
