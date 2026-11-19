// wheel_gate_test.dart —— S2 滚轮门控判别（第五十六轮）。
//
// 背景实测：现行 Flutter 滚轮按「内层先消费、余量传祖先」串联，
// AuraListScrollPhysics 的 shouldAcceptUserOffset 门控挡不住余量
// 串页（物理门控单独使用时页面位移 100px，已实测）。门控正解是
// ScrollTrap：悬停于确有滚动区间的内嵌列表时冻结整页 physics。
// 本测试按 PageScaffold 的真实接线（ScrollTrapScope +
// ValueListenableBuilder 切 physics）组装同构嵌套，断言：
//   1. 列表可滚时：滚轮滚列表到底，页面 offset 恒 0；
//   2. 列表无滚动区间时：不冻结，滚轮照常滚页面。
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/ui/wheel_scroll.dart';

Widget _wiring({
  required ScrollController pageCtrl,
  required ScrollController listCtrl,
  required int itemCount,
}) {
  final counter = ValueNotifier<int>(0);
  return MaterialApp(
    home: Scaffold(
      body: ScrollTrapScope(
        counter: counter,
        child: ValueListenableBuilder<int>(
          valueListenable: counter,
          builder: (_, trapCount, scrollChild) => SingleChildScrollView(
            controller: pageCtrl,
            physics: trapCount > 0
                ? const NeverScrollableScrollPhysics()
                : null,
            child: scrollChild,
          ),
          child: Column(
            children: [
              SizedBox(
                height: 100,
                child: ScrollTrap(
                  child: ListView.builder(
                    controller: listCtrl,
                    physics: const AuraListScrollPhysics(),
                    itemCount: itemCount,
                    itemBuilder: (_, i) =>
                        SizedBox(height: 20, child: Text('item$i')),
                  ),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _wheel(WidgetTester tester, int n) async {
  final center = tester.getCenter(find.text('item2'));
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.pump();
  for (var i = 0; i < n; i++) {
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('可滚列表：滚到底不串页', (tester) async {
    final pageCtrl = ScrollController();
    final listCtrl = ScrollController();
    await tester.pumpWidget(
      _wiring(pageCtrl: pageCtrl, listCtrl: listCtrl, itemCount: 50),
    );
    await tester.pumpAndSettle();
    await _wheel(tester, 10);
    expect(listCtrl.offset, greaterThan(0));
    expect(pageCtrl.offset, 0.0);
  });

  testWidgets('无滚动区间列表：滚轮放行页面', (tester) async {
    final pageCtrl = ScrollController();
    final listCtrl = ScrollController();
    await tester.pumpWidget(
      _wiring(pageCtrl: pageCtrl, listCtrl: listCtrl, itemCount: 3),
    );
    await tester.pumpAndSettle();
    await _wheel(tester, 3);
    expect(pageCtrl.offset, greaterThan(0));
  });
}
