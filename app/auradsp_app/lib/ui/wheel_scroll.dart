// wheel_scroll.dart —— 内层列表独占鼠标滚轮（2026-10-28 用户定案）。
//
// 需求：脚本 / 插件 / 处理链三个核心页面里，鼠标在「已达到最大显示高度、
// 滚动条可触发」的列表内滚动时，只滚列表、不带动整页；鼠标在列表外滚动
// 时整页正常滚动。
//
// 实现要点：
// - 列表本身 physics 必须设为 NeverScrollableScrollPhysics：否则它的
//   Scrollable 会先注册 PointerSignalResolver，把它自己也滚不动的滚轮
//   事件「吃掉」（表现为悬停短列表也挡住页面滚动）。
// - 本组件用 Listener 接收滚轮信号，仅当列表**确实可滚动**
//   （maxScrollExtent > minScrollExtent）时向 PointerSignalResolver
//   注册并手动 jumpTo；不可滚动时不注册 → 事件穿透给页面 Scrollable。
// - 滚动条请用 Scrollbar(controller: 同一 controller, thumbVisibility: true)；
//   Scrollbar 拖拽走 position.jumpTo，不受 physics 限制。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class AuraWheelScrollScope extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  const AuraWheelScrollScope({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        if (!controller.hasClients) return;
        final pos = controller.position;
        if (!pos.hasContentDimensions ||
            pos.maxScrollExtent <= pos.minScrollExtent) {
          return; // 列表不可滚：放行，滚轮滚页面。
        }
        GestureBinding.instance.pointerSignalResolver.register(event, (e) {
          final delta = (e as PointerScrollEvent).scrollDelta.dy;
          final target = (pos.pixels + delta)
              .clamp(pos.minScrollExtent, pos.maxScrollExtent);
          if ((target - pos.pixels).abs() > 0.01) {
            controller.jumpTo(target);
          }
        });
      },
      child: child,
    );
  }
}
