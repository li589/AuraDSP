// responsive_layout_test.dart — P2 响应式回归：三档宽度下无横向溢出
//
// 覆盖：PageScaffold（默认响应式边距/最大宽）+ SectionCard +
// ValueSlider（含 InfoBadge）+ AuraChoiceChip/AuraChip 混排。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/ui_helpers.dart';
import 'package:auradsp_app/features/chrome.dart';
import 'package:auradsp_app/features/effects_page.dart';
import 'package:auradsp_app/features/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: child),
    );

Widget _samplePage() => PageScaffold(
      title: '效果',
      children: [
        SectionCard(
          index: '01',
          title: '立体声展宽',
          trailing: const AuraSwitch(value: true, onChanged: null),
          child: ValueSlider(
            label: '立体声展宽',
            infoMessage: '展宽说明',
            value: 0.5,
            defaultValue: 0.0,
            min: 0,
            max: 1,
            unit: '%',
            onChanged: (_) {},
          ),
        ),
        SectionCard(
          title: '模式',
          child: Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.sm,
            children: const [
              AuraChoiceChip(label: '动态', selected: true, onTap: null),
              AuraChoiceChip(label: '搁架', selected: false, onTap: null),
              AuraChip('预设一', selected: false),
              AuraChip('预设二', selected: true),
            ],
          ),
        ),
      ],
    );

Future<void> _pumpAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(_samplePage()));
  await tester.pumpAndSettle();
}

void main() {
  group('Responsive layout (no horizontal overflow)', () {
    for (final w in const [400.0, 700.0, 1200.0]) {
      testWidgets('宽度 $w 无溢出异常', (tester) async {
        await _pumpAt(tester, w);
        expect(tester.takeException(), isNull);
        expect(find.text('效果'), findsOneWidget);
        expect(find.byType(InfoBadge), findsOneWidget);
      });
    }

    testWidgets('mobile 下 PageScaffold 用 16 边距', (tester) async {
      await _pumpAt(tester, 400);
      final ctx = tester.element(find.text('效果'));
      expect(ctx.responsivePageX, AuraSpace.lg);
      expect(ctx.responsiveMaxW, 480.0);
    });
  });
}
