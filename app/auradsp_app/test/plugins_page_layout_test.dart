/*
 * plugins_page_layout_test.dart — 插件页窄宽度布局回归（2026-10-28）。
 *
 * 用户实测：窗口横向拉很窄时，顶部四个插槽的文字溢出插槽边界。
 * 现行为：槽宽 < 150 时退化为「大圈号居中」（不再渲染文字列）。
 * 本测试在窄视口下渲染整页，断言无布局溢出异常。
 */
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/plugins_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: PluginsPage(model: model)),
    );

void main() {
  testWidgets('窄视口（560px）插槽条紧凑化且无溢出', (tester) async {
    tester.view.physicalSize = const Size(560, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final model = AppModel(testing: true);
    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '窄宽度不应出现布局溢出');
  });

  testWidgets('宽视口（1280px）保留完整插槽标签', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final model = AppModel(testing: true);
    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 宽屏仍显示文字标签（Slot 1..4）
    expect(find.textContaining('Slot 1'), findsWidgets);
  });
}
