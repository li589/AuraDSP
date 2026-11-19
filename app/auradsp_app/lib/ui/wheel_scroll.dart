// wheel_scroll.dart —— 列表滚轮门控（2026-10-28，修正版；
// 第五十六轮 S2 修正：物理门控失效判读 + ScrollTrap 陷阱机制）。
//
// 需求：脚本 / 插件 / 处理链页面里，鼠标在「可滚动列表」内滚动时只滚列表、
// 不带动整页；列表不可滚动（内容未超高度）时滚轮放行给页面；列表外滚页面。
// 覆盖面：处理链序列表、插件列表、代码大纲、APO 端点列表、
// EEL 手册条目列表。横向滚动区不串纵向页面，不在覆盖内。
//
// 失效判读（第五十六轮，widget 测试实测）：现行 Flutter 的滚轮
// 事件按「内层先消费、余量传祖先」的串联语义分发，
// AuraListScrollPhysics 的 shouldAcceptUserOffset 门控挡不住余量
// 串页（实测：列表上滚轮到底，页面仍位移 100px）。故门控改由
// ScrollTrap 承担：指针悬停于确有滚动区间的内嵌列表时，
// PageScaffold 把整页 physics 冻结为不可滚，余量无处可串；
// 列表无滚动区间时不冻结，滚轮照常滚页面。physics 保留并行
// 使用：其「无区间不接受偏移」仍负责短列表不吃滚轮。
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
import 'package:flutter/foundation.dart' show ValueNotifier;
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

/// 滚轮陷阱计数作用域：PageScaffold 提供，[ScrollTrap] 增减，
/// PageScaffold 监听计数决定整页是否冻结滚动。
class ScrollTrapScope extends InheritedWidget {
  const ScrollTrapScope({
    super.key,
    required this.counter,
    required super.child,
  });

  final ValueNotifier<int> counter;

  static ValueNotifier<int>? of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ScrollTrapScope>()
          ?.counter;

  @override
  bool updateShouldNotify(ScrollTrapScope oldWidget) =>
      counter != oldWidget.counter;
}

/// 滚轮陷阱：包住内嵌纵向列表。指针悬停且列表确有滚动区间时
/// 向作用域计数 +1（PageScaffold 据此冻结整页滚动）；离开、
/// 列表变为无滚动区间、或组件销毁时回落。无 PageScaffold
/// 祖先（对话框等模态面）时自动失效、无副作用。
class ScrollTrap extends StatefulWidget {
  const ScrollTrap({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollTrap> createState() => _ScrollTrapState();
}

class _ScrollTrapState extends State<ScrollTrap> {
  ValueNotifier<int>? _counter;
  bool _hovering = false;
  bool _hasOverflow = false;
  bool _engaged = false;

  void _sync() {
    final want = _hovering && _hasOverflow;
    if (want == _engaged) return;
    _engaged = want;
    final c = _counter;
    if (c != null) c.value += want ? 1 : -1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = ScrollTrapScope.of(context);
    if (c != _counter) {
      if (_engaged && _counter != null) _counter!.value -= 1;
      _counter = c;
      if (_engaged && _counter != null) _counter!.value += 1;
    }
  }

  @override
  void dispose() {
    if (_engaged && _counter != null) _counter!.value -= 1;
    _engaged = false;
    super.dispose();
  }

  bool _onNotification(ScrollNotification n) {
    final overflow = n.metrics.maxScrollExtent > n.metrics.minScrollExtent;
    if (overflow != _hasOverflow) {
      _hasOverflow = overflow;
      _sync();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        _hovering = true;
        _sync();
      },
      onExit: (_) {
        _hovering = false;
        _sync();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onNotification,
        child: widget.child,
      ),
    );
  }
}
