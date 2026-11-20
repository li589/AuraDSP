// shell_layout_test.dart — 响应式外壳回归（2026-11-20 窄屏立项 P1）
//
// 覆盖：
// - 360px（Q2 最小支持宽度）显示底部六项导航，切页无布局异常；
// - ≥900 保持左栏，底栏移出视口；
// - 1200 → 360 跨断点缩放不抛异常，底栏滑入。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/nav.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  theme: withAuraExtension(ThemeData.dark(), auraDark),
  home: AppShell(model: model),
);

Future<AppModel> _pumpAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = AppModel(testing: true);
  await tester.pumpWidget(_app(model));
  // 不用 pumpAndSettle：视效页含持续动画，settle 可能永不返回。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return model;
}

void main() {
  group('AppShell responsive navigation', () {
    testWidgets('360px 显示底栏，六项等分且选中态生效', (tester) async {
      final model = await _pumpAt(tester, 360);
      expect(tester.takeException(), isNull);

      for (var i = 0; i < 6; i++) {
        expect(
          find.byKey(ValueKey<String>('shell.nav.$i')),
          findsOneWidget,
          reason: '底栏第 $i 项缺失',
        );
      }
      final navRect = tester.getRect(
        find.byKey(const ValueKey<String>('shell.bottomNav')),
      );
      expect(navRect.top, closeTo(740, 1), reason: '底栏应贴在 800 高视口底部');

      await tester.tap(find.byKey(const ValueKey<String>('shell.nav.0')));
      await tester.pump();
      expect(model.visiblePage.value, AppPage.home);
    });

    testWidgets('1200px 保持左栏，底栏移出视口', (tester) async {
      await _pumpAt(tester, 1200);
      expect(tester.takeException(), isNull);

      final railRect = tester.getRect(
        find.byKey(const ValueKey<String>('shell.rail')),
      );
      expect(railRect.left, 0, reason: '桌面左栏应贴左');
      expect(railRect.width, greaterThan(200), reason: '桌面左栏应保持展开态');

      final navRect = tester.getRect(
        find.byKey(const ValueKey<String>('shell.bottomNav')),
      );
      expect(navRect.top, greaterThanOrEqualTo(800), reason: '桌面底栏应在视口外');
    });

    testWidgets('1200 → 360 跨断点缩放，底栏滑入且不抛异常', (tester) async {
      await _pumpAt(tester, 1200);
      tester.view.physicalSize = const Size(360, 800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      final navRect = tester.getRect(
        find.byKey(const ValueKey<String>('shell.bottomNav')),
      );
      expect(navRect.top, closeTo(740, 1), reason: '跨断点后底栏应滑入');
    });
  });
}
