/*
 * wheel_scroll_test.dart — 内层列表独占滚轮（2026-10-28 用户定案）回归。
 *
 * 语义：
 *   1. 列表可滚动 → 滚轮只滚列表，页面不动；
 *   2. 列表不可滚动（内容未超高度）→ 滚轮滚页面；
 *   3. 滚轮在列表外 → 滚页面。
 */
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/ui/wheel_scroll.dart';

Widget _host({
  required ScrollController pageCtrl,
  required ScrollController listCtrl,
  required int items,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        controller: pageCtrl,
        child: Column(
          children: [
            const SizedBox(height: 120, child: Text('header')),
            SizedBox(
              height: 200,
              child: Scrollbar(
                controller: listCtrl,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: listCtrl,
                  physics: const AuraListScrollPhysics(),
                  itemCount: items,
                  itemBuilder: (_, i) => SizedBox(
                    height: 40,
                    child: Text('item $i'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 800, child: Text('footer')),
          ],
        ),
      ),
    ),
  );
}

Future<void> _wheel(WidgetTester tester, Offset pos, double dy) async {
  final event = PointerScrollEvent(
    position: pos,
    scrollDelta: Offset(0, dy),
  );
  tester.binding.handlePointerEvent(event);
  await tester.pumpAndSettle();
}


void main() {
  testWidgets('列表可滚：滚轮只滚列表，页面不跟随', (tester) async {
    final pageCtrl = ScrollController();
    final listCtrl = ScrollController();
    addTearDown(pageCtrl.dispose);
    addTearDown(listCtrl.dispose);

    await tester.pumpWidget(
      _host(pageCtrl: pageCtrl, listCtrl: listCtrl, items: 100),
    );
    await tester.pumpAndSettle();

    // 列表区域中心（header 120 + 列表 200 → 中心约 y=220）。
    await _wheel(tester, const Offset(200, 220), 100);

    expect(listCtrl.offset, greaterThan(0), reason: '列表应当滚动');
    expect(pageCtrl.offset, 0, reason: '页面不应跟随滚动');

    // 同一门控也是 Scrollbar 拖拽的前提（SDK handleThumbPressUpdate 检查
    // physics.shouldAcceptUserOffset）：可滚列表必须返回 true。
    final pos = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position;
    expect(pos.physics.shouldAcceptUserOffset(pos), isTrue);
  });

  testWidgets('列表不可滚：滚轮放行给页面', (tester) async {
    final pageCtrl = ScrollController();
    final listCtrl = ScrollController();
    addTearDown(pageCtrl.dispose);
    addTearDown(listCtrl.dispose);

    // 仅 2 项 → 列表内容不足 200px，无滚动区间。
    await tester.pumpWidget(
      _host(pageCtrl: pageCtrl, listCtrl: listCtrl, items: 2),
    );
    await tester.pumpAndSettle();

    await _wheel(tester, const Offset(200, 220), 100);

    expect(listCtrl.offset, 0, reason: '列表无区间，不应滚动');
    expect(pageCtrl.offset, greaterThan(0), reason: '页面应当滚动');
    final pos = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position;
    expect(pos.physics.shouldAcceptUserOffset(pos), isFalse,
        reason: '无滚动区间时必须放行滚轮/不拦页面');
  });

  testWidgets('列表外滚轮：页面正常滚动', (tester) async {
    final pageCtrl = ScrollController();
    final listCtrl = ScrollController();
    addTearDown(pageCtrl.dispose);
    addTearDown(listCtrl.dispose);

    await tester.pumpWidget(
      _host(pageCtrl: pageCtrl, listCtrl: listCtrl, items: 100),
    );
    await tester.pumpAndSettle();

    await _wheel(tester, const Offset(200, 60), 100); // header 区域

    expect(pageCtrl.offset, greaterThan(0), reason: '页面应当滚动');
    expect(listCtrl.offset, 0, reason: '列表不应被滚动');
  });

}
