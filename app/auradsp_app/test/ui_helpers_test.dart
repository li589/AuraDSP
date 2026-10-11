// ui_helpers_test.dart — P0 基础设施回归：断点 / InfoBadge / AuraChoiceChip
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/ui_helpers.dart';
import 'package:auradsp_app/features/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: Center(child: child)),
    );

Future<AuraBreakpoint> _breakpointOf(
    WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late AuraBreakpoint got;
  await tester.pumpWidget(_app(Builder(builder: (ctx) {
    got = ctx.auraBreakpoint;
    return const SizedBox();
  })));
  return got;
}

void main() {
  group('AuraBreakpoint', () {
    testWidgets('500 -> mobile / 700 -> tablet / 1200 -> desktop',
        (tester) async {
      expect(await _breakpointOf(tester, 500), AuraBreakpoint.mobile);
      expect(await _breakpointOf(tester, 700), AuraBreakpoint.tablet);
      expect(await _breakpointOf(tester, 1200), AuraBreakpoint.desktop);
    });

    testWidgets('pageX 按档位 16 / 24 / 32', (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late double px;
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        px = ctx.responsivePageX;
        return const SizedBox();
      })));
      expect(px, AuraSpace.lg);
    });
  });

  group('InfoBadge', () {
    testWidgets('渲染问号徽标 + Tooltip 携带说明文案', (tester) async {
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);
      final tip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tip.message, '混响说明');
      expect(tip.waitDuration, const Duration(milliseconds: 300));
    });
  });

  group('AuraChoiceChip', () {
    testWidgets('点击触发 onTap，文案可见', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_app(AuraChoiceChip(
        label: '动态',
        selected: false,
        onTap: () => tapped++,
      )));
      expect(find.text('动态'), findsOneWidget);
      await tester.tap(find.text('动态'));
      expect(tapped, 1);
    });

    testWidgets('onTap 为空不断言、不崩', (tester) async {
      await tester.pumpWidget(_app(const AuraChoiceChip(
        label: '静态',
        selected: true,
        onTap: null,
      )));
      expect(find.text('静态'), findsOneWidget);
      await tester.tap(find.text('静态'));
      await tester.pump();
    });
  });
}
