// ui_helpers_test.dart — P0 基础设施回归：断点 / InfoBadge / AuraChoiceChip
import 'dart:ui' show PointerDeviceKind;

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
    testWidgets('渲染问号徽标（默认不弹气泡）', (tester) async {
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      expect(find.byIcon(Icons.question_mark_rounded), findsOneWidget);
      expect(find.text('混响说明'), findsNothing);
    });

    testWidgets('桌面 hover 300ms 弹出、移出关闭', (tester) async {
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      final center = tester.getCenter(find.byType(InfoBadge));
      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('混响说明'), findsOneWidget);
      await gesture.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('混响说明'), findsNothing);
      await gesture.removePointer();
    });

    testWidgets('长按弹出、点徽标关闭', (tester) async {
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      await tester.longPress(find.byType(InfoBadge));
      await tester.pump();
      expect(find.text('混响说明'), findsOneWidget);
      await tester.tap(find.byType(InfoBadge));
      await tester.pump();
      expect(find.text('混响说明'), findsNothing);
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
