// effects_category_test.dart — 效果页分类过滤回归：
// 默认 'all' 展开全部 16 卡 + 空间卡内 5 搬入子卡 + 预设卡（22 SectionCard）；
// 切到 'spatial' 只剩空间卡 + 5 子卡 + 预设卡（7）；切到 'eq' 为 3 卡 + 预设卡（4）。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/effects_page.dart';
import 'package:auradsp_app/features/widgets.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: EffectsPage(model: model)),
    );

Future<void> _pumpPage(WidgetTester tester, AppModel model) async {
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(model));
  await tester.pumpAndSettle();
}

int _sectionCards(WidgetTester tester) =>
    tester.widgetList(find.byType(SectionCard)).length;

void main() {
  testWidgets('all shows every card, categories filter correctly',
      (tester) async {
    final model = AppModel(testing: true);
    await _pumpPage(tester, model);
    // 16 页卡 + 空间卡内 5 子卡 + 预设卡
    expect(_sectionCards(tester), 22);

    model.setEffectsCategory('spatial');
    await tester.pumpAndSettle();
    // 空间卡 + 5 子卡 + 预设卡；搬入的混响子卡可见；空间卡去编号（无 09 徽标）
    expect(_sectionCards(tester), 7);
    expect(find.text('Spatial Reverb'), findsOneWidget);

    model.setEffectsCategory('eq');
    await tester.pumpAndSettle();
    // eq/arbmag/ddc + 预设卡
    expect(_sectionCards(tester), 4);

    model.setEffectsCategory('all');
    await tester.pumpAndSettle();
    expect(_sectionCards(tester), 22);
  });
}
