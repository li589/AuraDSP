// perf_widgets_test.dart — 降载部件存活回归（2026-11-12）。
//
// 钉死：步进式部件在时间推进下不崩、卸载时定时器干净取消、
// 极光冻结开关启停不抛错。视觉数值本身不在此断言（人工目检
// 口径），这里只保证新定时器接线不会把向导带崩。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_setup/src/aurora_background.dart';

void main() {
  testWidgets('步进部件随时间推进存活且卸载干净', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Column(children: [
        SteppedSpinner(),
        SteppedProgressBar(value: null),
        SteppedProgressBar(value: 0.4),
      ]),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(SteppedSpinner), findsOneWidget);
    // 确定态与不确定态切换不留悬挂定时器
    await tester.pumpWidget(const MaterialApp(
      home: SteppedProgressBar(value: 0.9),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('极光冻结/解冻与生命周期切换不抛错', (tester) async {
    auroraFrozen.value = false;
    await tester.pumpWidget(const MaterialApp(
      home: AuroraBackground(child: SizedBox.expand()),
    ));
    await tester.pump(const Duration(seconds: 2));
    auroraFrozen.value = true;
    await tester.pump(const Duration(seconds: 2));
    auroraFrozen.value = false;
    await tester.pump(const Duration(milliseconds: 950));
    await tester.pumpWidget(const SizedBox.shrink());
    auroraFrozen.value = false;
  });
}
